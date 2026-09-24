#Requires -Version 7.4

<#
.SYNOPSIS
    Test.Unit - the suite on this host, through the same gate CI uses.

.DESCRIPTION
    Copied from claude.agent.images@249752d (blob d05ae7a2), then adapted.
    Test.InContainer is removed because tools builds no image. What stays is
    the part that matters: the suite runs under the pinned Pester and passes
    through Assert-SuiteClean, the SAME function scripts/ci/Invoke-Tests.ps1
    calls, so an unjustified skip goes red here and in CI alike.

    The gate line is printed as passed/failed/skipped/notrun, in that order.
#>

# Synopsis: Run the whole suite on this host.
task Test.Unit {
    Import-Module Pester -RequiredVersion $Build.PesterVersion -Force -ErrorAction Stop

    $files = Get-SuiteFile -TestRoot $Build.TestRoot

    # An empty suite is a failure, not a pass. The birth packet reported
    # 0/0/0/0 here while tests/ held no suite file; PR 1 landed the first
    # tests and closed that branch.
    if ($files.Count -eq 0) {
        throw 'host: no suite files under tests/; an empty suite is not a green'
    }

    $outDir = $Build.OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) { [void](New-Item -ItemType Directory -Path $outDir -Force) }

    $config = New-PesterConfiguration
    $config.Run.Path = $files
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = Join-Path $outDir 'host.tests.xml'
    $config.TestResult.OutputFormat = 'NUnit2.5'

    $result = Invoke-Pester -Configuration $config
    Write-Build Cyan ("host: gate passed={0} failed={1} skipped={2} notrun={3}" -f
        $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.NotRunCount)

    # No -ExcludeTag: this run excludes nothing, so every NotRun it sees
    # really is unexplained.
    Assert-SuiteClean -Result $result -Where 'host'
}
