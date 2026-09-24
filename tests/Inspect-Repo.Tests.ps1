#Requires -Version 7.4

<#
    src/Inspect-Repo.ps1, measured on throwaway repositories built under
    [System.IO.Path]::GetTempPath(). Each fixture is `git init` plus `git add` - the inspector
    reads the index through git ls-files, so no commit (and no committer identity) is needed.

    `gh` is shadowed by a global function for the API rule, so these tests never touch the
    network and give the same answer on a runner with no token.
#>

BeforeAll {
    $script:Inspector = Join-Path (Split-Path $PSScriptRoot -Parent) 'src' 'Inspect-Repo.ps1'
    $script:Boxes = [System.Collections.Generic.List[string]]::new()

    function script:New-Fixture {
        param([hashtable]$Files)
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('inspect-' + [guid]::NewGuid().ToString('n').Substring(0, 12))
        [void](New-Item -ItemType Directory -Path $root -Force)
        $script:Boxes.Add($root)
        & git -C $root init -q
        foreach ($k in $Files.Keys) {
            $full = Join-Path $root $k
            [void](New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force)
            [System.IO.File]::WriteAllText($full, $Files[$k])
        }
        & git -C $root add -A
        return $root
    }

    # Hashtable splat: an array splat hands '-Path' over as a positional VALUE, not a name.
    function script:Invoke-Inspector {
        param([string]$Root, [hashtable]$Extra = @{ Offline = $true })
        $splat = @{ Path = $Root } + $Extra
        return @(& $script:Inspector @splat)
    }
}

AfterAll {
    # Remove-Item -Force, not Directory.Delete: git writes its objects read-only on Windows.
    foreach ($b in $script:Boxes) { if (Test-Path -LiteralPath $b) { Remove-Item -LiteralPath $b -Recurse -Force } }
    Remove-Item -Path Function:\gh -ErrorAction SilentlyContinue
}

Describe 'Inspect-Repo: the verdict object' {
    It 'emits typed verdicts with exactly Id, Rule, Path, Line, Verdict, Evidence' {
        $root = New-Fixture @{ 'README.md' = 'See `docs/missing.md`.' }
        $v = Invoke-Inspector -Root $root
        $v.Count | Should -BeGreaterThan 0
        foreach ($o in $v) {
            $o.PSObject.TypeNames[0] | Should -BeExactly 'claude.agent.tools.Verdict'
            @($o.PSObject.Properties.Name) | Should -Be @('Id', 'Rule', 'Path', 'Line', 'Verdict', 'Evidence')
            $o.Verdict | Should -BeIn @('fail', 'warn', 'unknown')
            $o.Id | Should -Match ('^' + [regex]::Escape($o.Rule) + ':[0-9a-f]{12}$')
        }
    }

    It 'is deterministic: two runs serialise to the same bytes' {
        $root = New-Fixture @{
            'README.md'   = 'vendor/gone/x' + "`n" + '`docs/a.md` and `docs/b.md`'
            'x.ps1'       = "if (`$root -notmatch 'claude\.agent\.x$') { throw }"
        }
        $a = (Invoke-Inspector -Root $root | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n"
        $b = (Invoke-Inspector -Root $root | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n"
        $a | Should -Not -BeNullOrEmpty
        $b | Should -BeExactly $a
    }
}

Describe 'Inspect-Repo: rules' {
    It 'stale-repo-name: fail in code, warn in a comment and in prose' {
        $root = New-Fixture @{
            'a.ps1'     = "# was claude.build.ledger`n`$p = 'vendor/claude.build.ledger/x'"
            'README.md' = 'Born from claude.pwsh.image.builder.'
        }
        $v = @(Invoke-Inspector -Root $root | Where-Object Rule -eq 'stale-repo-name')
        @($v | Where-Object { $_.Path -eq 'a.ps1' -and $_.Line -eq 1 }).Verdict | Should -Be 'warn'
        @($v | Where-Object { $_.Path -eq 'a.ps1' -and $_.Line -eq 2 }).Verdict | Should -Be 'fail'
        @($v | Where-Object { $_.Path -eq 'README.md' }).Verdict | Should -Be 'warn'
    }

    It 'dead-vendor-path: a vendor path .gitmodules does not declare, and not one it does' {
        $root = New-Fixture @{
            # vendor/live.mod has a dot in its name, and the regex-escaped spelling on line 3 is the
            # same live path - the shape images' Image.Tests.ps1 uses.
            '.gitmodules' = "[submodule `"vendor/live.mod`"]`n`tpath = vendor/live.mod`n`turl = https://example.invalid/live.git`n"
            'a.ps1'       = "`$x = 'vendor/gone/mod.psd1'`n`$y = 'vendor/live.mod/mod.psd1'`n`$z = 'COPY vendor/live\.mod/x'"
        }
        $v = @(Invoke-Inspector -Root $root | Where-Object Rule -eq 'dead-vendor-path')
        $v.Count | Should -Be 1
        $v[0].Line | Should -Be 1
        $v[0].Verdict | Should -Be 'fail'
    }

    It 'cited-file-missing: a missing path fails, a present one, a gitignored one and a revision spec do not' {
        $root = New-Fixture @{
            '.gitignore'   = "output/`n"
            'docs/here.md' = 'x'
            'README.md'    = '`docs/here.md` `docs/gone.md` output/run.json repo@abc1234:tests/x.ps1 `.MISSING.md` `README.md`'
        }
        $v = @(Invoke-Inspector -Root $root | Where-Object Rule -eq 'cited-file-missing')
        @($v | ForEach-Object { ($_.Evidence -split "'")[1] } | Sort-Object) | Should -Be @('.MISSING.md', 'docs/gone.md')
        @($v.Verdict | Sort-Object -Unique) | Should -Be @('fail')
    }

    It 'cited-file-missing: a record (END_GOAL.md, docs/plans/**) is warn, not fail' {
        $root = New-Fixture @{
            'END_GOAL.md'          = 'cited `docs/gone.md`'
            'docs/plans/p/PLAN.md' = 'cited `docs/gone.md`'
        }
        @(Invoke-Inspector -Root $root | Where-Object Rule -eq 'cited-file-missing').Verdict | Should -Be @('warn', 'warn')
    }

    It 'directory-name-guard: a path compared to a literal repository name, and not a type-name match' {
        $root = New-Fixture @{
            'run.ps1'  = "`$repoRoot = git rev-parse --show-toplevel`nif (`$repoRoot -notmatch 'claude\.agent\.images$') { throw 'NOT HERE' }"
            'type.ps1' = "if (`$o.Type -match '^claude\.agent\.tools\.') { 1 }"
        }
        $v = @(Invoke-Inspector -Root $root | Where-Object Rule -eq 'directory-name-guard')
        $v.Count | Should -Be 1
        $v[0].Path | Should -Be 'run.ps1'
        $v[0].Line | Should -Be 2
    }

    It 'unprotected-branch: -Offline says unknown for each branch rather than nothing' {
        $root = New-Fixture @{ 'config/repo.json' = '{"repo":"o/n","branches":{"main":"main","develop":"develop"}}' }
        $v = @(Invoke-Inspector -Root $root | Where-Object Rule -eq 'unprotected-branch')
        $v.Path | Should -Be @('branch:develop', 'branch:main')
        @($v.Verdict | Sort-Object -Unique) | Should -Be @('unknown')
    }

    It 'unprotected-branch: 404 Branch not protected is fail, a protected branch is silent, other errors are unknown' {
        function global:gh {
            $url = [string]$args[1]
            if ($url -like '*/branches/main/protection') { $global:LASTEXITCODE = 0; return '{"url":"x"}' }
            if ($url -like '*/branches/develop/protection') { $global:LASTEXITCODE = 1; return 'gh: Branch not protected (HTTP 404)' }
            $global:LASTEXITCODE = 1; return 'gh: Bad credentials (HTTP 401)'
        }
        try {
            $root = New-Fixture @{ 'config/repo.json' = '{"repo":"o/n","branches":{"main":"main","develop":"develop"}}' }
            $v = @(Invoke-Inspector -Root $root -Extra @{} | Where-Object Rule -eq 'unprotected-branch')
            $v.Count | Should -Be 1
            $v[0].Path | Should -Be 'branch:develop'
            $v[0].Verdict | Should -Be 'fail'

            $root2 = New-Fixture @{ 'config/repo.json' = '{"repo":"o/n","branches":{"main":"trunk","develop":"develop"}}' }
            $u = @(Invoke-Inspector -Root $root2 -Extra @{} | Where-Object Path -eq 'branch:trunk')
            $u[0].Verdict | Should -Be 'unknown'
        }
        finally { Remove-Item -Path Function:\gh -ErrorAction SilentlyContinue }
    }
}

Describe 'Inspect-Repo: the target''s settings, config/inspector.json' {
    It 'test_data: string literals in a listed file are fixture text; its comments and every unlisted file are not' {
        $defects = "'docs/gone.md vendor/gone/x claude.build.ledger'"
        $root = New-Fixture @{
            'config/inspector.json' = '{"test_data":[{"path":"t.Tests.ps1","reason":"fixture text"}]}'
            't.Tests.ps1'           = "`$fixture = $defects`n# see docs/also-gone.md"
            'other.ps1'             = "`$fixture = $defects"
        }
        $v = @(Invoke-Inspector -Root $root | Where-Object Rule -ne 'unprotected-branch')

        # The listed file keeps exactly one finding: the one in its comment, which is not a literal.
        @($v | Where-Object Path -eq 't.Tests.ps1').Count | Should -Be 1
        @($v | Where-Object Path -eq 't.Tests.ps1')[0].Evidence | Should -Match "^'docs/also-gone\.md'"

        # The same literal in a file nobody listed is still three fails, one per rule.
        @($v | Where-Object { $_.Path -eq 'other.ps1' -and $_.Verdict -eq 'fail' }).Rule | Sort-Object |
            Should -Be @('cited-file-missing', 'dead-vendor-path', 'stale-repo-name')
    }

    It 'test_data: an entry that is not a PowerShell file is refused, not honoured' {
        $root = New-Fixture @{ 'config/inspector.json' = '{"test_data":[{"path":"README.md","reason":"would excuse prose"}]}' }
        { Invoke-Inspector -Root $root } | Should -Throw '*not a PowerShell file*'
    }

    It 'optional_files: excused only where cited_in names the citing file, and where it is declared' {
        $root = New-Fixture @{
            'config/inspector.json' = '{"optional_files":[{"path":"docs/opt.md","cited_in":["a.ps1"],"reason":"an optional input"}]}'
            'a.ps1'                 = '# reads docs/opt.md when it is there'
            'b.ps1'                 = '# reads docs/opt.md when it is there'
        }
        $v = @(Invoke-Inspector -Root $root | Where-Object Rule -eq 'cited-file-missing')
        $v.Path | Should -Be @('b.ps1')
        $v[0].Verdict | Should -Be 'fail'
    }

    It 'optional_files: an entry with no reason is refused' {
        $root = New-Fixture @{ 'config/inspector.json' = '{"optional_files":[{"path":"docs/opt.md","cited_in":["a.ps1"]}]}' }
        { Invoke-Inspector -Root $root } | Should -Throw "*has no 'reason'*"
    }

    It 'a target with no config/inspector.json is inspected with every list empty' {
        $root = New-Fixture @{ 't.Tests.ps1' = "`$fixture = 'docs/gone.md'" }
        @(Invoke-Inspector -Root $root | Where-Object Rule -eq 'cited-file-missing').Verdict | Should -Be @('fail')
    }
}

Describe 'Inspect-Repo: switches' {
    It '-Halt exits 1 when any verdict is fail, and 0 when none is' {
        # Exit 1 is the passing case here, so a non-zero native exit must not throw.
        $PSNativeCommandUseErrorActionPreference = $false
        $pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $bad = New-Fixture @{ 'README.md' = '`docs/gone.md`' }
        $clean = New-Fixture @{ 'README.md' = 'nothing cited' }

        $null = & $pwsh -NoProfile -File $script:Inspector -Path $bad -Offline -Halt
        $LASTEXITCODE | Should -Be 1
        $null = & $pwsh -NoProfile -File $script:Inspector -Path $clean -Offline -Halt
        $LASTEXITCODE | Should -Be 0
    }

    It '-Policy compiles the law through core and checks every path it protects' {
        $root = New-Fixture @{
            'AGENTS.md'       = "# law`n- Do not edit src/ghost.ps1 by hand.`n- Do not touch tests/here.ps1 either."
            'tests/here.ps1' = '1'
        }
        $v = @(Invoke-Inspector -Root $root -Extra @{ Offline = $true; Policy = (Join-Path $root 'AGENTS.md') } |
                Where-Object { $_.Evidence -like '*policy rule*' })
        $v.Count | Should -Be 1
        $v[0].Evidence | Should -Match "^'src/ghost\.ps1'"
        $v[0].Path | Should -Be 'AGENTS.md'
        $v[0].Line | Should -Be 2
    }
}
