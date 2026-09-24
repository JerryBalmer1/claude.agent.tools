#Requires -Version 7.4

<#
.SYNOPSIS
    Observes a target repository and emits one typed verdict per finding.

.DESCRIPTION
    A command, not a library: run it with pwsh -NoProfile -File, or call it with &. It reads
    the target's TRACKED tree (git ls-files) and, for one rule, the GitHub API. It writes
    nothing and prints nothing. Every finding leaves as a [pscustomobject] with PSTypeName
    claude.agent.tools.Verdict and six fields:

        Id        <rule>:<first 12 hex of sha256(rule|path|line|evidence)>, stable across runs
        Rule      which rule found it
        Path      repo-relative, forward slashes; branch:<name> for the API rule
        Line      1-based line, or 0 where a line means nothing
        Verdict   fail | warn | unknown
        Evidence  the text that was measured, and against what

    Output is sorted by Rule, Path, Line and Evidence, so the same tree gives the same bytes
    when serialised. That is what lets corpus/ hold frozen output and cite it by blob sha.

    RULES

      stale-repo-name      A retired repository name (config/retired-repos.json) appears in
                           the tree. fail in code or config; warn in a comment or in prose,
                           where it is often provenance rather than a live claim.
      dead-vendor-path     vendor/<name> is cited but <name> is not a submodule path in
                           .gitmodules nor a tracked directory. Same fail/warn split.
      cited-file-missing   A repo-relative path, or a bare file name in backticks or a
                           markdown link, names a file that is neither tracked nor on disk
                           nor gitignored. fail, except warn when the citing file is a
                           record (END_GOAL.md, CHANGELOG*, docs/plans/**), which cites
                           history. With -Policy, every path-kind rule the law compiles to is
                           checked the same way.
      directory-name-guard A PowerShell comparison against a literal repository name, the
                           shape `$root -notmatch 'claude\.agent\.images$'`. A guard like that
                           ties a script to one folder name. fail.
      unprotected-branch   GET repos/<slug>/branches/<branch>/protection answers 404 Branch not
                           protected for a branch config/repo.json names. fail. Any other API
                           answer is unknown. This one measures live state, not the tree, so
                           its Evidence carries the date it was measured.

    Not scanned: vendor/ (another repository's tree), .continuity/ (an append-only chain whose
    records are history by construction), corpus/ (frozen inspector output).

    THE TARGET'S SETTINGS

    The target may carry config/inspector.json. It is the target's own statement about its own
    tree, so it is read from the target, never from here. A target without one is inspected
    with every list empty. Two lists, and each entry names a path and a reason:

      test_data            PowerShell files whose STRING LITERALS are fixture text: the
                           defects a test writes down so a rule has something to find. A
                           finding inside a string literal in a listed file is not emitted.
                           Comments and code in the same file are scanned as usual, and so
                           is every file that is not listed.
      optional_files       Paths that are cited as optional and may be absent. An entry
                           excuses cited-file-missing only in the files its cited_in names
                           (and in config/inspector.json itself, where it is declared).
                           A citation of the same path from anywhere else still fails.

.PARAMETER Path
    Root of the target repository's work tree.

.PARAMETER Policy
    A markdown law file, or a directory holding AGENTS.md / docs/do-not.md / CLAUDE.md. It is
    compiled by vendor/claude.agent.core/modules/policy (Get-PolicyRules), not reparsed here.

.PARAMETER Halt
    Exit 1 after emitting every verdict if any verdict is fail.

.PARAMETER Offline
    Do not call the GitHub API. unprotected-branch then emits one unknown per branch instead of
    staying silent, so an offline run cannot pass for a clean one.

.PARAMETER Repo
    owner/name for the API rule. Defaults to config/repo.json -> repo in the target, then to
    the origin remote.

.PARAMETER RetiredList
    JSON list of retired repository names. Defaults to this repository's config/retired-repos.json.

.EXAMPLE
    pwsh -NoProfile -File src/Inspect-Repo.ps1 -Path ..\claude.agent.images

.EXAMPLE
    & ./src/Inspect-Repo.ps1 -Path . -Policy ./AGENTS.md -Offline | Where-Object Verdict -eq 'fail'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter()]
    [string]$Policy,

    [Parameter()]
    [switch]$Halt,

    [Parameter()]
    [switch]$Offline,

    [Parameter()]
    [ValidatePattern('^$|^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')]
    [string]$Repo = '',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RetiredList = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config' 'retired-repos.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$ToolsRoot = Split-Path $PSScriptRoot -Parent
$Root = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath)
if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
    throw "not the root of a git work tree: $Root"
}

# ------------------------------------------------------------------ the one verdict constructor

function New-Verdict {
    param(
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][int]$Line,
        [Parameter(Mandatory)][ValidateSet('fail', 'warn', 'unknown')][string]$Verdict,
        [Parameter(Mandatory)][string]$Evidence
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Rule|$RelPath|$Line|$Evidence")
    $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return [pscustomobject]@{
        PSTypeName = 'claude.agent.tools.Verdict'
        Id         = "${Rule}:$($hash.Substring(0, 12))"
        Rule       = $Rule
        Path       = $RelPath
        Line       = $Line
        Verdict    = $Verdict
        Evidence   = $Evidence
    }
}

# ------------------------------------------------------------------ the tree

$tracked = @(& git -C $Root -c core.quotepath=off ls-files)
$trackedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$tracked, [System.StringComparer]::Ordinal)
$trackedDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($f in $tracked) {
    $parts = $f -split '/'
    for ($i = 1; $i -lt $parts.Count; $i++) { [void]$trackedDirs.Add(($parts[0..($i - 1)] -join '/')) }
}

$retiredListFull = [System.IO.Path]::GetFullPath($RetiredList)
$scanExt = '\.(md|ps1|psm1|psd1|json|yml|yaml|txt)$'
$scanned = @($tracked | Where-Object {
        $_ -match $scanExt -and
        $_ -notmatch '^(vendor|\.continuity|corpus)/' -and
        [System.IO.Path]::GetFullPath((Join-Path $Root $_)) -ne $retiredListFull
    })

function Get-FileModel {
    <#  Text, line starts, and the character spans that are comments, for one tracked file. #>
    param([Parameter(Mandatory)][string]$Rel)
    $text = [System.IO.File]::ReadAllText((Join-Path $Root $Rel))
    $starts = [System.Collections.Generic.List[int]]::new()
    $starts.Add(0)
    for ($i = 0; $i -lt $text.Length; $i++) { if ($text[$i] -eq "`n") { $starts.Add($i + 1) } }

    $kind = if ($Rel -match '\.(ps1|psm1|psd1)$') { 'powershell' }
    elseif ($Rel -match '\.ya?ml$') { 'yaml' }
    elseif ($Rel -match '\.json$') { 'json' }
    else { 'prose' }

    $comments = [System.Collections.Generic.List[int[]]]::new()
    $strings = [System.Collections.Generic.List[int[]]]::new()
    if ($kind -eq 'powershell') {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        foreach ($t in $tokens) {
            if ($t.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) {
                $comments.Add([int[]]@($t.Extent.StartOffset, $t.Extent.EndOffset))
            }
            elseif ($t -is [System.Management.Automation.Language.StringToken]) {
                $strings.Add([int[]]@($t.Extent.StartOffset, $t.Extent.EndOffset))
            }
        }
    }
    return @{ Rel = $Rel; Text = $text; Starts = $starts; Kind = $kind; Comments = $comments; Strings = $strings }
}

function Get-LineOf {
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)][int]$Offset)
    $i = $Model.Starts.BinarySearch($Offset)
    if ($i -lt 0) { $i = (-bnot $i) - 1 }
    return $i + 1
}

function Get-LineText {
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)][int]$Line)
    $start = $Model.Starts[$Line - 1]
    $end = if ($Line -lt $Model.Starts.Count) { $Model.Starts[$Line] } else { $Model.Text.Length }
    $s = $Model.Text.Substring($start, $end - $start).Trim()
    if ($s.Length -gt 200) { $s = $s.Substring(0, 197) + '...' }
    return $s
}

function Get-Context {
    <#  code, comment or prose - what kind of text the character at Offset sits in. #>
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)][int]$Offset)
    switch ($Model.Kind) {
        'prose' { return 'prose' }
        'json' { return 'code' }
        'powershell' {
            foreach ($c in $Model.Comments) { if ($Offset -ge $c[0] -and $Offset -lt $c[1]) { return 'comment' } }
            return 'code'
        }
        'yaml' {
            $line = Get-LineOf -Model $Model -Offset $Offset
            $start = $Model.Starts[$line - 1]
            $before = $Model.Text.Substring($start, $Offset - $start)
            if ($before -match '(^|\s)#') { return 'comment' }
            return 'code'
        }
    }
}

$models = @(foreach ($rel in $scanned) { Get-FileModel -Rel $rel })

# ------------------------------------------------------------------ the target's settings

$settingsRel = 'config/inspector.json'
$settings = $null
$settingsPath = Join-Path $Root $settingsRel
if (Test-Path -LiteralPath $settingsPath) { $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -Depth 10 }

function Get-SettingList {
    <#  One list from the target's settings, every entry checked for the fields it must carry. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Field)
    # Properties[name], not Properties.Name: on an object with no properties at all - a settings
    # file that is just {} - member enumeration of .Name throws under strict mode.
    if ($null -eq $settings -or $null -eq $settings.PSObject.Properties[$Name]) { return @() }
    $list = @($settings.$Name)
    foreach ($e in $list) {
        foreach ($f in $Field) {
            if ($null -eq $e.PSObject.Properties[$f] -or -not $e.$f) {
                throw "${settingsRel}: an entry in $Name has no '$f'. Every entry names what it excuses and why."
            }
        }
    }
    return $list
}

$testData = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($e in @(Get-SettingList -Name 'test_data' -Field 'path', 'reason')) {
    # Only PowerShell has string literals the tokenizer can find. Excusing a whole markdown file
    # would excuse its prose, which is exactly the weakening this list must not allow.
    if ([string]$e.path -notmatch '\.(ps1|psm1|psd1)$') {
        throw "${settingsRel}: test_data entry '$($e.path)' is not a PowerShell file; only string literals can be test data"
    }
    [void]$testData.Add([string]$e.path)
}

$optional = @{}
foreach ($e in @(Get-SettingList -Name 'optional_files' -Field 'path', 'cited_in', 'reason')) {
    $optional[[string]$e.path] = @(@($e.cited_in) + $settingsRel)
}

function Test-TestData {
    <#  $true when Offset sits inside a string literal of a file the target lists as test data. #>
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)][int]$Offset)
    if (-not $testData.Contains($Model.Rel)) { return $false }
    foreach ($s in $Model.Strings) { if ($Offset -ge $s[0] -and $Offset -lt $s[1]) { return $true } }
    return $false
}

# The raw verdict inputs are collected as hashtables and turned into verdicts once, at the end,
# so there is exactly one place an output object is built.
$found = [System.Collections.Generic.List[hashtable]]::new()
function Add-Found {
    param([string]$Rule, [string]$RelPath, [int]$Line, [string]$Verdict, [string]$Evidence)
    $found.Add(@{ Rule = $Rule; RelPath = $RelPath; Line = $Line; Verdict = $Verdict; Evidence = $Evidence })
}

# ------------------------------------------------------------------ stale-repo-name

$retired = @((Get-Content -LiteralPath $RetiredList -Raw | ConvertFrom-Json -Depth 5).retired)
foreach ($m in $models) {
    foreach ($r in $retired) {
        $pattern = '(?<![A-Za-z0-9.-])' + [regex]::Escape([string]$r.name) + '(?![A-Za-z0-9-])'
        foreach ($hit in [regex]::Matches($m.Text, $pattern, 'IgnoreCase')) {
            if (Test-TestData -Model $m -Offset $hit.Index) { continue }
            $context = Get-Context -Model $m -Offset $hit.Index
            $line = Get-LineOf -Model $m -Offset $hit.Index
            $successor = if ($r.successor) { "; successor $($r.successor)" } else { '' }
            Add-Found 'stale-repo-name' $m.Rel $line $(if ($context -eq 'code') { 'fail' } else { 'warn' }) `
                "retired name '$($r.name)'$successor, in $context`: $(Get-LineText -Model $m -Line $line)"
        }
    }
}

# ------------------------------------------------------------------ dead-vendor-path

$vendorLive = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$gitmodules = Join-Path $Root '.gitmodules'
if (Test-Path -LiteralPath $gitmodules) {
    foreach ($l in [System.IO.File]::ReadAllLines($gitmodules)) {
        if ($l -match '^\s*path\s*=\s*vendor/([^/\s]+)\s*$') { [void]$vendorLive.Add($Matches[1]) }
    }
}
foreach ($d in $trackedDirs) { if ($d -match '^vendor/([^/]+)$') { [void]$vendorLive.Add($Matches[1]) } }
foreach ($f in $tracked) { if ($f -match '^vendor/([^/]+)$') { [void]$vendorLive.Add($Matches[1]) } }

foreach ($m in $models) {
    # '\.' is allowed inside the name and unescaped, because a regex literal in a test writes the
    # submodule as vendor/claude\.agent\.core - and that IS the live path.
    foreach ($hit in [regex]::Matches($m.Text, '(?<![A-Za-z0-9_.-])vendor/(?<name>[A-Za-z0-9_-]+(?:\\?\.[A-Za-z0-9_-]+)*)')) {
        $name = $hit.Groups['name'].Value.Replace('\.', '.').TrimEnd('.')
        if (-not $name -or $vendorLive.Contains($name)) { continue }
        if (Test-TestData -Model $m -Offset $hit.Index) { continue }
        $context = Get-Context -Model $m -Offset $hit.Index
        $line = Get-LineOf -Model $m -Offset $hit.Index
        $live = if ($vendorLive.Count) { ($vendorLive | Sort-Object) -join ', ' } else { 'none' }
        Add-Found 'dead-vendor-path' $m.Rel $line $(if ($context -eq 'code') { 'fail' } else { 'warn' }) `
            "vendor/$name is not a vendored path (live: $live), in $context`: $(Get-LineText -Model $m -Line $line)"
    }
}

# ------------------------------------------------------------------ cited-file-missing

$diskLeaves = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in $tracked) { [void]$diskLeaves.Add(($f -split '/')[-1]) }
Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '[\\/]\.git([\\/]|$)' } |
    ForEach-Object { [void]$diskLeaves.Add($_.Name) }

function Test-Cited {
    <#  $true when a cited relative path names something that is there. #>
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][AllowEmptyString()][string]$FromRel)
    $fromDir = [System.IO.Path]::GetDirectoryName($FromRel)
    foreach ($base in @('', $fromDir)) {
        $joined = if ($base) { "$base/$Token" } else { $Token }
        $full = [System.IO.Path]::GetFullPath((Join-Path $Root $joined))
        if (-not $full.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $rel = [System.IO.Path]::GetRelativePath($Root, $full).Replace('\', '/').TrimEnd('/')
        if ($trackedSet.Contains($rel) -or $trackedDirs.Contains($rel)) { return $true }
        if (Test-Path -LiteralPath $full) { return $true }
    }
    return $false
}

$candidates = [System.Collections.Generic.List[hashtable]]::new()
# Not preceded by a path character, '$' (a variable: "repos/$Repo/...") or ':' (a revision spec,
# repo@sha:path, which cites another tree on purpose).
$pathPattern = '(?<![A-Za-z0-9_./\\$:-])(?<p>(?:\.{1,2}/)*\.?[A-Za-z0-9_-][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_.-]+)*\.(?:md|ps1|psm1|psd1|json|jsonl|yml|yaml|txt))(?![A-Za-z0-9_/-])'
foreach ($m in $models) {
    foreach ($hit in [regex]::Matches($m.Text, $pathPattern)) {
        $token = $hit.Groups['p'].Value
        $i = $hit.Index
        $j = $i + $token.Length
        $before = if ($i -gt 0) { $m.Text[$i - 1] } else { '' }
        $after = if ($j -lt $m.Text.Length) { $m.Text[$j] } else { '' }

        if ($token -notmatch '/') {
            # A bare file name counts only where the text marks it as a file: `name` or ](name).
            $quoted = ($before -eq '`' -and $after -eq '`') -or ($before -eq '(' -and $i -gt 1 -and $m.Text[$i - 2] -eq ']')
            if (-not $quoted -or $diskLeaves.Contains($token)) { continue }
        }
        else {
            $first = ($token -split '/')[0]
            # claude.build.ledger/docs/x.md, github.com/... - another tree, not measurable here.
            if ($first -match '^[A-Za-z0-9-]+\.[A-Za-z]' -and -not $trackedDirs.Contains($first) -and
                -not (Test-Path -LiteralPath (Join-Path $Root $first))) { continue }
            if (Test-Cited -Token $token -FromRel $m.Rel) { continue }
        }
        if (Test-TestData -Model $m -Offset $i) { continue }
        $line = Get-LineOf -Model $m -Offset $i
        $candidates.Add(@{ Token = $token; Rel = $m.Rel; Line = $line; Source = "cited: $(Get-LineText -Model $m -Line $line)" })
    }
}

if ($Policy) {
    $policyModule = Join-Path $ToolsRoot 'vendor' 'claude.agent.core' 'modules' 'policy' 'policy.psd1'
    if (-not (Test-Path -LiteralPath $policyModule)) {
        throw "-Policy needs core's policy module and it is not present: $policyModule. Run: git submodule update --init"
    }
    Import-Module $policyModule -Force -ErrorAction Stop
    $policyFull = (Resolve-Path -LiteralPath $Policy).ProviderPath
    foreach ($rule in @(Get-PolicyRules -Path $policyFull | Where-Object Kind -eq 'path')) {
        $token = ([string]$rule.Basis).TrimEnd('/')
        if (Test-Cited -Token $token -FromRel '') { continue }
        $sourceFile, $sourceLine = ([string]$rule.Source) -split ':', 2
        $citing = [System.IO.Path]::GetRelativePath($Root, [System.IO.Path]::GetFullPath((Join-Path (Split-Path $policyFull -Parent) $sourceFile))).Replace('\', '/')
        if ((Get-Item -LiteralPath $policyFull).PSIsContainer) {
            $citing = [System.IO.Path]::GetRelativePath($Root, [System.IO.Path]::GetFullPath((Join-Path $policyFull $sourceFile))).Replace('\', '/')
        }
        $why = "policy rule $($rule.Id) (kind $($rule.Kind), weight $($rule.Weight), $($rule.Source)) protects a path that is not there"
        # The plain scan has usually cited the same token on the same line already. One verdict,
        # carrying the law's reason, beats two for one fact - and a dedupe that silently kept the
        # weaker one would hide that the law is involved at all.
        $same = @($candidates | Where-Object { $_.Rel -eq $citing -and $_.Line -eq [int]$sourceLine -and $_.Token -eq $token })
        if ($same.Count) { foreach ($s in $same) { $s.Source = "$why; $($s.Source)" }; continue }
        $candidates.Add(@{ Token = $token; Rel = $citing; Line = [int]$sourceLine; Source = $why })
    }
}

# Anything gitignored is build output or a local file, not a dead citation.
$ignored = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
# Only tokens that stay inside the root: one '../x' in a chunk makes check-ignore die with
# "outside repository" and answer nothing for every other path in that chunk.
$probe = @($candidates | ForEach-Object { $_.Token } |
        Where-Object { $_ -match '/' -and $_ -notmatch '(^|/)\.\.(/|$)' } | Sort-Object -Culture '' -CaseSensitive -Unique)
# Arguments, not --stdin: PowerShell writes native stdin with the platform newline, so on
# Windows git read 'path\r', found it ignored, and echoed it back quoted - matching nothing here.
for ($k = 0; $k -lt $probe.Count; $k += 50) {
    $chunk = $probe[$k..([Math]::Min($k + 49, $probe.Count - 1))]
    $PSNativeCommandUseErrorActionPreference = $false
    $out = @(& git -C $Root check-ignore --no-index -- @chunk 2>$null)
    $PSNativeCommandUseErrorActionPreference = $true
    foreach ($o in $out) { [void]$ignored.Add(([string]$o).Trim()) }
}

$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($c in $candidates) {
    if ($ignored.Contains($c.Token)) { continue }
    if ($optional.ContainsKey($c.Token) -and $optional[$c.Token] -contains $c.Rel) { continue }
    if (-not $seen.Add("$($c.Rel)|$($c.Line)|$($c.Token)")) { continue }
    $isRecord = $c.Rel -match '^(END_GOAL\.md|CHANGELOG[^/]*|docs/plans/.+)$'
    Add-Found 'cited-file-missing' $c.Rel $c.Line $(if ($isRecord) { 'warn' } else { 'fail' }) `
        "'$($c.Token)' does not exist in the tree; $($c.Source)"
}

# ------------------------------------------------------------------ directory-name-guard

$compare = @('Imatch', 'Inotmatch', 'Cmatch', 'Cnotmatch', 'Ilike', 'Inotlike', 'Clike', 'Cnotlike', 'Ieq', 'Ine', 'Ceq', 'Cne')
foreach ($m in @($models | Where-Object Kind -eq 'powershell')) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($m.Text, [ref]$tokens, [ref]$errors)
    $guards = $ast.FindAll({
            param($n)
            if ($n -isnot [System.Management.Automation.Language.BinaryExpressionAst]) { return $false }
            if ($compare -notcontains $n.Operator.ToString()) { return $false }
            # A repository-name literal is a GUARD when it is anchored as a path suffix ('...$')
            # or compared against something path-shaped. Matching a type name such as
            # 'claude.agent.tools.Verdict' against a property is neither.
            $pairs = @(@($n.Left, $n.Right), @($n.Right, $n.Left))
            foreach ($p in $pairs) {
                $lit = $p[0]
                $other = $p[1]
                if ($lit -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                if ($lit.Value -notmatch '(?i)claude(\\?\.[A-Za-z0-9-]+){2,}') { continue }
                if ($lit.Value.EndsWith('$') -or $other.Extent.Text -match '(?i)root|path|dir|location|toplevel|leaf|pwd') { return $true }
            }
            return $false
        }, $true)
    foreach ($g in $guards) {
        Add-Found 'directory-name-guard' $m.Rel $g.Extent.StartLineNumber 'fail' `
            "comparison against a literal repository name ties this script to one folder name: $(Get-LineText -Model $m -Line $g.Extent.StartLineNumber)"
    }
}

# ------------------------------------------------------------------ unprotected-branch

$config = $null
$configPath = Join-Path $Root 'config' 'repo.json'
if (Test-Path -LiteralPath $configPath) { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 20 }

$slug = $Repo
if (-not $slug -and $config -and $config.PSObject.Properties.Name -contains 'repo') { $slug = [string]$config.repo }
if (-not $slug) {
    $PSNativeCommandUseErrorActionPreference = $false
    $origin = [string](& git -C $Root remote get-url origin 2>$null)
    $PSNativeCommandUseErrorActionPreference = $true
    if ($origin -match 'github\.com[:/](?<s>[A-Za-z0-9._-]+/[A-Za-z0-9._-]+?)(\.git)?$') { $slug = $Matches['s'] }
}

$branches = @('main', 'develop')
if ($config -and $config.PSObject.Properties.Name -contains 'branches') {
    $branches = @([string]$config.branches.main, [string]$config.branches.develop)
}

foreach ($b in $branches) {
    $where = "branch:$b"
    if (-not $slug) {
        Add-Found 'unprotected-branch' $where 0 'unknown' 'no owner/name: pass -Repo, or give the target config/repo.json -> repo or a github origin'
        continue
    }
    if ($Offline) {
        Add-Found 'unprotected-branch' $where 0 'unknown' "not measured: -Offline (repos/$slug/branches/$b/protection)"
        continue
    }
    $PSNativeCommandUseErrorActionPreference = $false
    $answer = (& gh api "repos/$slug/branches/$b/protection" 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    if ($code -eq 0) { continue }
    if ($answer -match 'Branch not protected') {
        Add-Found 'unprotected-branch' $where 0 'fail' "GET repos/$slug/branches/$b/protection -> 404 Branch not protected, measured $today"
    }
    else {
        $first = ($answer -split "`r?`n")[0]
        Add-Found 'unprotected-branch' $where 0 'unknown' "GET repos/$slug/branches/$b/protection -> exit $code '$first', measured $today"
    }
}

# ------------------------------------------------------------------ emit

# Invariant culture and case-sensitive: a sort that follows the machine's locale gives two
# machines two orders, and the corpus is cited by the sha of its bytes.
$verdicts = @(
    $found |
        Sort-Object -Culture '' -CaseSensitive -Property @{ Expression = { $_.Rule } }, @{ Expression = { $_.RelPath } }, @{ Expression = { $_.Line } }, @{ Expression = { $_.Evidence } } |
        ForEach-Object { New-Verdict -Rule $_.Rule -RelPath $_.RelPath -Line $_.Line -Verdict $_.Verdict -Evidence $_.Evidence }
)
$verdicts

if ($Halt -and @($verdicts | Where-Object Verdict -eq 'fail').Count -gt 0) { exit 1 }
exit 0
