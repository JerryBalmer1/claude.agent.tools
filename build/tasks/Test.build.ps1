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

    # THE EMPTY SUITE, FOR THE BIRTH PACKET ONLY. Pester throws on a path
    # with no test files rather than returning a result, so a repository
    # born with zero tests needs this line to report 0/0/0/0 honestly
    # instead of a stack trace. PR 1 lands the first tests and turns this
    # branch into a failure.
    if ($files.Count -eq 0) {
        Write-Build Yellow 'host: gate passed=0 failed=0 skipped=0 notrun=0 -- no suite files under tests/'
        return
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
