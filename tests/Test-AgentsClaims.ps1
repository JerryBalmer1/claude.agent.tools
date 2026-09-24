#Requires -Version 7.4

<#
.SYNOPSIS
    The compliance runner's seed: one Pester It per claim in AGENTS.md, each measuring the tree.

.DESCRIPTION
    AGENTS.md -> ## Claims is a table whose first column is a claim id. This file holds one It
    per id, named '<id>: <claim>', and each one measures the TRACKED tree (git ls-files), not
    the working directory, so an untracked scratch file can neither fail a claim nor hide a
    breach of one.

    The last It closes the loop in both directions: every id in AGENTS.md must have an It
    here, and every It here must name an id in AGENTS.md. A claim added to the table without
    a measurement goes red, and so does a measurement whose claim was deleted.

    It measures this repository by default and any other through -Path. That is the point of
    the name: a command that happens to be a suite, not a suite that happens to live in tests/.
    Pester's directory discovery skips it because the name is not *.Tests.ps1, which is why
    every runner here gets its file list from Get-SuiteFile in build/Build.Helpers.psm1.

.PARAMETER Path
    Root of the repository to measure. Defaults to the repository this file lives in.

.EXAMPLE
    pwsh -NoProfile -File tests/run.ps1 -Path tests/Test-AgentsClaims.ps1

.EXAMPLE
    $c = New-PesterContainer -Path tests/Test-AgentsClaims.ps1 -Data @{ Path = '..\other-repo' }
    Invoke-Pester -Container $c -Output Detailed
#>
param(
    [string]$Path = (Split-Path -Parent $PSScriptRoot)
)

BeforeAll {
    $script:Root = [System.IO.Path]::GetFullPath($Path)
    $script:Self = $PSCommandPath

    # Tracked files, forward-slash relative paths. core.quotepath=off so a non-ASCII name
    # comes back as itself rather than as an octal-escaped string that matches nothing.
    function script:Get-Tracked {
        param([string[]]$Pathspec = @())
        $out = @(& git -C $script:Root -c core.quotepath=off ls-files -- @Pathspec)
        if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $script:Root" }
        return @($out | Where-Object { $_ })
    }

    function script:Get-TrackedOutsideVendor {
        return @(Get-Tracked | Where-Object { $_ -notmatch '^vendor/' })
    }

    function script:Get-Ast {
        param([Parameter(Mandatory)][string]$Relative)
        $tokens = $null
        $errors = $null
        $full = Join-Path $script:Root $Relative
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "$Relative does not parse: $($errors[0].Message)" }
        return $ast
    }

    function script:Find-Node {
        param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][scriptblock]$Predicate)
        return @($Ast.FindAll($Predicate, $true))
    }

    function script:Get-CommandName {
        param([Parameter(Mandatory)]$Ast)
        return @(Find-Node -Ast $Ast -Predicate { param($n) $n -is [System.Management.Automation.Language.CommandAst] } |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }

    $script:SrcFiles = @(Get-Tracked -Pathspec 'src/')
}

Describe 'AGENTS.md claims, measured against the tree' {

    It 'commands-not-library: tools ships commands, not a library' {
        $breaches = [System.Collections.Generic.List[string]]::new()
        foreach ($rel in $script:SrcFiles) {
            if ($rel -match '\.(psm1|psd1)$') { $breaches.Add("$rel is a module file"); continue }
            if ($rel -notmatch '\.ps1$') { continue }
            $ast = Get-Ast -Relative $rel
            $binding = $ast.ParamBlock -and @($ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count -gt 0
            if (-not $binding) { $breaches.Add("$rel has no [CmdletBinding()] param block") }
            if ((Get-CommandName -Ast $ast) -contains 'Export-ModuleMember') { $breaches.Add("$rel calls Export-ModuleMember") }
        }
        $breaches | Should -BeNullOrEmpty
    }

    It 'verdicts-not-receipts: tools emits verdicts, not receipts' {
        $breaches = foreach ($rel in $script:SrcFiles) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:Root $rel))
            foreach ($m in [regex]::Matches($text, '(?i)Add-LedgerRecord|ledger\.psd1|forensic\.jsonl')) {
                "$rel names '$($m.Value)'"
            }
        }
        @($breaches) | Should -BeNullOrEmpty
    }

    It 'no-python: no Python' {
        $tracked = Get-TrackedOutsideVendor
        $breaches = [System.Collections.Generic.List[string]]::new()
        foreach ($rel in $tracked) {
            if ($rel -match '\.py$') { $breaches.Add("$rel is a Python file"); continue }
            if ($rel -match '\.(ps1|psm1)$') {
                $names = Get-CommandName -Ast (Get-Ast -Relative $rel)
                foreach ($n in @($names | Where-Object { $_ -match '^(?i)(python3?|py)(\.exe)?$' })) {
                    $breaches.Add("$rel invokes $n")
                }
            }
            elseif ($rel -match '\.ya?ml$') {
                $lines = [System.IO.File]::ReadAllLines((Join-Path $script:Root $rel))
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^(?i)\s*(-\s*)?((run|shell):\s*)?(python3?|py)(\.exe)?(\s|$)') {
                        $breaches.Add("${rel}:$($i + 1) invokes Python")
                    }
                }
            }
        }
        $breaches | Should -BeNullOrEmpty
    }

    It 'no-dockerfile: no Dockerfile' {
        $breaches = @(Get-TrackedOutsideVendor | Where-Object {
                $leaf = ($_ -split '/')[-1]
                $leaf -match '^(?i)(dockerfile.*|.+\.dockerfile|\.dockerignore|(docker-)?compose(\..+)?\.ya?ml)$'
            })
        $breaches | Should -BeNullOrEmpty
    }

    It 'typed-verdicts: every verdict is a typed object with a result field, never a printed line' {
        $breaches = [System.Collections.Generic.List[string]]::new()
        foreach ($rel in @($script:SrcFiles | Where-Object { $_ -match '\.ps1$' })) {
            $ast = Get-Ast -Relative $rel

            foreach ($n in @(Get-CommandName -Ast $ast | Where-Object { $_ -in 'Write-Host', 'Out-Host' -or $_ -like 'Format-*' })) {
                $breaches.Add("$rel calls $n")
            }

            $literals = Find-Node -Ast $ast -Predicate {
                param($n)
                $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                $n.Type.TypeName.Name -ieq 'pscustomobject' -and
                $n.Child -is [System.Management.Automation.Language.HashtableAst]
            }
            foreach ($lit in $literals) {
                $keys = @{}
                foreach ($pair in $lit.Child.KeyValuePairs) {
                    $k = $pair.Item1.Extent.Text.Trim("'", '"')
                    $keys[$k] = $pair.Item2.Extent.Text
                }
                $at = "${rel}:$($lit.Extent.StartLineNumber)"
                if (-not $keys.ContainsKey('PSTypeName')) { $breaches.Add("$at has no PSTypeName"); continue }
                if ($keys['PSTypeName'] -notmatch "^['""]claude\.agent\.tools\.") { $breaches.Add("$at PSTypeName $($keys['PSTypeName']) is not claude.agent.tools.*") }
                if (-not $keys.ContainsKey('Verdict')) { $breaches.Add("$at has no Verdict") }
            }
        }
        $breaches | Should -BeNullOrEmpty
    }

    It 'temp-root: every suite resolves its temp root from GetTempPath' {
        $breaches = [System.Collections.Generic.List[string]]::new()
        foreach ($rel in @(Get-Tracked -Pathspec 'tests/' | Where-Object { $_ -match '\.(ps1|psm1)$' })) {
            $ast = Get-Ast -Relative $rel
            $reads = Find-Node -Ast $ast -Predicate {
                param($n)
                $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $n.VariablePath.UserPath -match '^(?i)env:(TEMP|TMP|TMPDIR)$'
            }
            foreach ($r in $reads) { $breaches.Add("${rel}:$($r.Extent.StartLineNumber) reads $($r.Extent.Text)") }

            $text = [System.IO.File]::ReadAllText((Join-Path $script:Root $rel))
            foreach ($m in [regex]::Matches($text, "GetEnvironmentVariable\(\s*['""](?i:TEMP|TMP|TMPDIR)['""]")) {
                $breaches.Add("$rel calls $($m.Value)")
            }
        }
        $breaches | Should -BeNullOrEmpty
    }

    It 'merge-commits-only: a pull request can land only as a merge commit' {
        # Live repository state, not the tree: the merge button is a setting. GraphQL, not REST,
        # because GET repos/<slug> leaves the allow_*_merge fields out for a token without push
        # access, and the workflow GITHUB_TOKEN is contents: read.
        $configPath = Join-Path $script:Root 'config' 'repo.json'
        $configPath | Should -Exist
        $slug = [string](Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 20).repo
        $slug | Should -Match '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' -Because 'config/repo.json -> repo names the repository to measure'
        $owner, $name = $slug -split '/', 2

        $query = 'query($o:String!,$n:String!){repository(owner:$o,name:$n){mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed}}'
        $PSNativeCommandUseErrorActionPreference = $false
        $answer = (& gh api graphql -f "query=$query" -f "o=$owner" -f "n=$name" 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
        $PSNativeCommandUseErrorActionPreference = $true
        $code | Should -Be 0 -Because "an unmeasured setting is not a green one; gh answered: $answer"

        $repo = ($answer | ConvertFrom-Json -Depth 10).data.repository
        $repo | Should -Not -BeNullOrEmpty -Because "GraphQL returned no repository for ${slug}: $answer"
        $settings = [ordered]@{
            mergeCommitAllowed = $repo.mergeCommitAllowed
            squashMergeAllowed = $repo.squashMergeAllowed
            rebaseMergeAllowed = $repo.rebaseMergeAllowed
        }
        # One assertion over all three, so a red run names every setting that is wrong at once.
        ($settings | ConvertTo-Json -Compress) |
            Should -BeExactly '{"mergeCommitAllowed":true,"squashMergeAllowed":false,"rebaseMergeAllowed":false}' -Because "$slug must offer the merge commit and nothing else"
    }

    It 'self-inspection-clean: src/Inspect-Repo.ps1 finds nothing to fail in this tree' {
        # The inspector that measures is this repository's; the tree it measures is -Path's.
        $inspector = Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'Inspect-Repo.ps1'
        $fails = @(& $inspector -Path $script:Root -Offline | Where-Object Verdict -eq 'fail' |
                ForEach-Object { "$($_.Path):$($_.Line) [$($_.Rule)] $($_.Evidence)" })
        $fails | Should -BeNullOrEmpty
    }

    It 'every claim in AGENTS.md has an It here, and every It here names a claim' {
        $agents = Join-Path $script:Root 'AGENTS.md'
        $agents | Should -Exist

        $claimed = @(
            [System.IO.File]::ReadAllLines($agents) |
                ForEach-Object { if ($_ -match '^\|\s*`([a-z0-9]+(-[a-z0-9]+)*)`\s*\|') { $Matches[1] } }
        )
        $claimed.Count | Should -BeGreaterThan 0 -Because 'AGENTS.md -> ## Claims must hold at least one row'

        $selfAst = [System.Management.Automation.Language.Parser]::ParseFile($script:Self, [ref]$null, [ref]$null)
        $measured = @(
            $selfAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'It' }, $true) |
                ForEach-Object { $_.CommandElements[1].SafeGetValue() } |
                ForEach-Object { if ($_ -match '^([a-z0-9]+(-[a-z0-9]+)*):') { $Matches[1] } }
        )

        @($claimed | Where-Object { $measured -notcontains $_ }) | Should -BeNullOrEmpty -Because 'a claim with no It is prose'
        @($measured | Where-Object { $claimed -notcontains $_ }) | Should -BeNullOrEmpty -Because 'an It whose claim was deleted measures nothing anyone asserted'
    }
}
