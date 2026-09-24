#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the repo's Pester suite. Read-only: it never commits, pushes or tags.

.DESCRIPTION
    Pinned to Pester 5.x deliberately. Three majors are installed on this machine
    (3.4.0, 5.7.1, 6.1.0) and an unpinned `Import-Module Pester` takes the highest,
    which changes the configuration API underneath the suite without warning.

    A later plan extends this runner. Keep the contract: -Path narrows the run,
    -Evidence tees the transcript to a file, exit code is 0 green / 1 red.
#>
[CmdletBinding()]
param(
    # Test files or directories to run. Defaults to every *.Tests.ps1 beside this script.
    [string[]] $Path,

    # Tee the full transcript to this file as well as the screen.
    [string] $Evidence
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repoRoot = (git rev-parse --show-toplevel)
if ($repoRoot -notmatch 'claude\.agent\.images$') { throw 'NOT IN CLAUDE.AGENT.IMAGES' }
Set-Location -LiteralPath $repoRoot

if (-not $Path) { $Path = Join-Path $repoRoot 'tests' }

# Pester 5.x, not 6, not 3. See the note above.
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.999.999 -Force
Write-Verbose ("Pester {0}" -f (Get-Module Pester).Version)

if ($Evidence) {
    $evidenceDir = Split-Path -Parent $Evidence
    if ($evidenceDir -and -not (Test-Path -LiteralPath $evidenceDir)) {
        $null = New-Item -ItemType Directory -Path $evidenceDir -Force
    }
    Start-Transcript -LiteralPath $Evidence -Force | Out-Null
}

try {
    $config = New-PesterConfiguration
    $config.Run.Path = $Path
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.Should.ErrorAction = 'Continue'   # report every failure in a run, not just the first

    $result = Invoke-Pester -Configuration $config

    Write-Host ''
    Write-Host ("SUITE: {0} passed, {1} failed, {2} skipped" -f
        $result.PassedCount, $result.FailedCount, $result.SkippedCount)
}
finally {
    if ($Evidence) { Stop-Transcript | Out-Null }
}

if ($result.FailedCount -gt 0) { exit 1 }
exit 0
