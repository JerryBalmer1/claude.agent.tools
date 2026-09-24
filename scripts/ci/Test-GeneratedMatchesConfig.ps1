#Requires -Version 7.4
#
# COPIED, NOT VENDORED.
#   origin repo   : claude.agent.substrate
#   origin file   : scripts/ci/Test-GeneratedMatchesConfig.ps1
#   origin commit : 912c1c9eb48ab0b639d257bc7b10661d7212f985
#   origin sha256 : add2dd1bf604a7a14c18bae027413fb76ba9f37951161ce0eb160d123cf7ed42
#   adapted here  : no - byte-identical at copy time
#
# There is no submodule here and substrate does not follow this copy. If substrate's
# version moves, this one does not move with it. Diff the two against the origin commit
# above before assuming they still agree.
#
<#
.SYNOPSIS
    CI check "generated-match-config": the rendered files match config, AND ci.yml's job names
    are exactly config.required_checks.

.DESCRIPTION
    Two assertions, because there are two ways for the config to stop being the source of truth.

    1. Someone edits docs/POLICY.md or the PR template by hand. Caught by
       Generate-Policy.ps1 -Check, a byte comparison.

    2. Someone deletes a job from .github/workflows/ci.yml, or adds one, while
       config.required_checks still lists the old set. Nothing else would catch this: the
       automerge workflow asks GitHub whether the checks passed, and a check that no longer
       exists simply never reports, so the PR would look green by absence. This is the more
       dangerous drift of the two, and it is the reason this job exists at all.

    The YAML is read as TEXT on purpose. Adding a YAML parser module would put a dependency in
    the path of the check that guards the dependency list. Job keys live at exactly two spaces
    of indentation under `jobs:`, which is unambiguous in a file this repo generates and owns.

.EXAMPLE
    pwsh -NoProfile -File scripts/ci/Test-GeneratedMatchesConfig.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version 3.0

$RepoRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$config    = (Get-Content -LiteralPath (Join-Path $RepoRoot 'config/repo.json') -Raw | ConvertFrom-Json -Depth 20)
$generator = Join-Path $RepoRoot 'scripts/Generate-Policy.ps1'
$ciYaml    = Join-Path $RepoRoot '.github/workflows/ci.yml'

$failures = 0

Write-Host '--- 1/2 rendered files vs config ---'
$PSNativeCommandUseErrorActionPreference = $false
& pwsh -NoProfile -File $generator -Check
$checkExit = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
if ($checkExit -ne 0) { $failures++ }

Write-Host ''
Write-Host '--- 2/2 ci.yml job names vs config.required_checks ---'

if (-not (Test-Path -LiteralPath $ciYaml)) {
    Write-Host "generated-match-config: FAIL -- $ciYaml does not exist"
    exit 1
}

$lines   = [System.IO.File]::ReadAllLines($ciYaml)
$inJobs  = $false
$jobs    = [System.Collections.Generic.List[string]]::new()
foreach ($line in $lines) {
    if ($line -match '^jobs:\s*$') { $inJobs = $true; continue }
    if (-not $inJobs) { continue }
    # A non-indented, non-blank, non-comment line ends the jobs block.
    if ($line -match '^\S' ) { break }
    if ($line -match '^  ([A-Za-z0-9][A-Za-z0-9_-]*):\s*(#.*)?$') { $jobs.Add($Matches[1]) }
}

$declared = @($config.required_checks) | Sort-Object
$actual   = @($jobs) | Sort-Object

Write-Host "  config.required_checks : $($declared -join ', ')"
Write-Host "  ci.yml job names       : $($actual -join ', ')"

$missing = @($declared | Where-Object { $actual -notcontains $_ })
$extra   = @($actual   | Where-Object { $declared -notcontains $_ })

foreach ($m in $missing) { Write-Host "  MISSING in ci.yml     : $m" }
foreach ($e in $extra)   { Write-Host "  EXTRA   in ci.yml     : $e" }

if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
    Write-Host 'generated-match-config: FAIL -- ci.yml job names are not exactly config.required_checks'
    $failures++
}
else {
    Write-Host 'generated-match-config: job names match config.required_checks exactly'
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "generated-match-config: FAIL -- $failures of 2 assertions failed"
    exit 1
}
Write-Host 'generated-match-config: PASS -- 2 of 2 assertions passed'
exit 0
