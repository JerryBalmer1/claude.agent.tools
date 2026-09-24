#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the repo's Pester suite. Read-only: it never commits, pushes or tags.

.DESCRIPTION
    Copied from claude.agent.images@249752d (blob 181aa202), then adapted.

    THE DIRECTORY-NAME GUARD IS GONE. images asserted that the work tree's
    folder was named claude.agent.images and threw otherwise, which ties a
    runner to one folder name on one machine: a clone into any other
    directory could not run its own tests. The property that guard was
    reaching for is that the suite being run is the suite THIS COPY of the
    runner lives beside. That is now how the root is found: from
    $PSScriptRoot, never from the caller's current directory, so running
    this file from inside another clone still runs this clone's suite.

    Pester is pinned to config/repo.json -> tooling.pester, the version CI
    installs, rather than the 5.x range images pinned here while its CI ran
    6.1.0.

    Contract: -Path narrows the run, -Evidence tees the transcript to a
    file, exit code is 0 green / 1 red.
#>
[CmdletBinding()]
param(
    # Test files or directories to run. Defaults to every suite file beside this script.
    [string[]] $Path,

    # Tee the full transcript to this file as well as the screen.
    [string] $Evidence
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'build' 'Build.Helpers.psm1') -Force -ErrorAction Stop

$pinned = (Get-Content -LiteralPath (Join-Path $repoRoot 'config' 'repo.json') -Raw |
    ConvertFrom-Json -Depth 20).tooling.pester

if (-not $Path) { $Path = Get-SuiteFile -TestRoot $PSScriptRoot }

# The birth packet's empty suite. See build/tasks/Test.build.ps1; PR 1 removes this.
if (@($Path).Count -eq 0) {
    Write-Host 'SUITE: 0 passed, 0 failed, 0 skipped, 0 notrun -- no suite files under tests/'
    exit 0
}

Import-Module Pester -RequiredVersion $pinned -Force
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
    Write-Host ("SUITE: {0} passed, {1} failed, {2} skipped, {3} notrun" -f
        $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.NotRunCount)
}
finally {
    if ($Evidence) { Stop-Transcript | Out-Null }
}

if ($result.FailedCount -gt 0) { exit 1 }
exit 0
