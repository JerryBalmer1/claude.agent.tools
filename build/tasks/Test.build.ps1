#Requires -Version 7.4

<#
.SYNOPSIS
    Test.Unit (host) and Test.InContainer (inside the built image).

.DESCRIPTION
    The two runs are not redundant. Test.Unit runs on Windows against whatever
    PowerShell the developer has; Test.InContainer runs the same suite on
    Linux, on the exact pwsh and Pester the image ships, as the non-root user
    that the leash depends on being unable to write to /opt/leash. A suite that
    only ever ran on the host has not tested the artefact being shipped.
#>

# Synopsis: Run the whole suite on this host, including the docker-tagged tests.
task Test.Unit {
    Import-Module Pester -MinimumVersion $Build.PesterVersion -ErrorAction Stop

    $outDir = $Build.OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) { [void](New-Item -ItemType Directory -Path $outDir -Force) }

    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $Build.RepositoryRoot 'tests'
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = Join-Path $outDir 'host.tests.xml'
    $config.TestResult.OutputFormat = 'NUnit2.5'

    $result = Invoke-Pester -Configuration $config
    Write-Build Cyan ("Host: passed={0} failed={1} skipped={2}" -f
        $result.PassedCount, $result.FailedCount, $result.SkippedCount)

    # Assert-SuiteClean lives in build/Build.Helpers.psm1, imported by .build.ps1, because
    # scripts/ci/Invoke-Tests.ps1 calls it too - it used to be a function in this file and
    # therefore unreachable from a plain pwsh script. No -ExcludeTag: this run excludes
    # nothing, so every NotRun it sees really is unexplained.
    Assert-SuiteClean -Result $result -Where 'host'
}

# Synopsis: Build the image, then run the suite inside it as the non-root user.
task Test.InContainer Build.Image, {
    $root = $Build.RepositoryRoot
    $outDir = $Build.OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) { [void](New-Item -ItemType Directory -Path $outDir -Force) }

    # --entrypoint pwsh bypasses entrypoint.ps1 on purpose: the entrypoint's
    # own refusals are asserted BY the suite (Entrypoint.Tests.ps1), so making
    # the suite depend on the entrypoint arming first would be circular.
    $relativeOut = [System.IO.Path]::GetRelativePath($root, $outDir).Replace('\', '/')

    # A persistent chain for this run, mounted at /ledger. The suite's own
    # receipts go to throwaway sandboxes; this one survives, because END_GOAL.md
    # has to name a ledger head that someone can go and verify afterwards.
    $ledgerDir = Join-Path $outDir 'ledger'
    if (-not (Test-Path -LiteralPath $ledgerDir)) { [void](New-Item -ItemType Directory -Path $ledgerDir -Force) }

    # /work is a bind mount, so its files carry the HOST uid, not the container's. git refuses
    # to operate in a repository owned by another user - "detected dubious ownership", exit 128
    # - and that took down the whole BeforeAll of any suite that asks git a question, which
    # reads as 25 failures and 21 NotRun rather than as one configuration problem.
    #
    # The exception lives in build/container.gitconfig and is passed as GIT_CONFIG_GLOBAL, so it
    # is scoped to this one invocation and neither image carries it. That file documents why it
    # is a FILE and not GIT_CONFIG_COUNT/KEY/VALUE: those arrive in git's "command line" scope,
    # which was enough for `git rev-parse` but not for the `git clone /work ...` the
    # planted-twin probe does, because safe.directory is deliberately restricted in which
    # scopes it may be honoured from.
    #
    # The alternative was to tag the git-dependent tests and exclude them in here. That would
    # have been skipping tests to get green, which the run order forbids, and it would have
    # quietly dropped the secret-scan assertions from the container run.
    Write-Build Cyan "Running the suite inside $($Build.LeashTag) ..."
    exec {
        docker run --rm `
            -v "${root}:/work" `
            -v "${ledgerDir}:/ledger" `
            -w /work `
            -e LEDGER_PRINCIPAL=run-01-incontainer `
            -e GIT_CONFIG_GLOBAL=/work/build/container.gitconfig `
            --entrypoint pwsh `
            $Build.LeashTag `
            -NoProfile -File /work/build/InContainer.Test.ps1 `
            -TestPath /work/tests `
            -ResultPath "/work/$relativeOut/incontainer"
    }

    $summaryPath = Join-Path $outDir 'incontainer.json'
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        throw "In-container run produced no summary at $summaryPath"
    }
    $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding utf8 | ConvertFrom-Json

    Write-Build Cyan ("Container: passed={0} failed={1} skipped={2} (pwsh {3}, Pester {4}, uid {5})" -f
        $summary.passed, $summary.failed, $summary.skipped,
        $summary.ps_version, $summary.pester_version, $summary.uid)
    Write-Build Cyan ("Ledger head: {0}" -f $summary.ledger_head)

    # The container gate already decided which skips were justified; this end reports
    # them, so the reason survives into the host log rather than only into the JSON.
    # Guarded: a summary written before justified_skips existed is still readable, and
    # StrictMode would otherwise turn an old artefact into a parse error.
    $justified = @()
    if ($summary.PSObject.Properties.Name -contains 'justified_skips') {
        $justified = @($summary.justified_skips)
    }
    foreach ($group in ($justified | Group-Object -Property reason | Sort-Object -Property Name)) {
        Write-Build Yellow ("Container: skipped — $($group.Name):")
        foreach ($t in $group.Group) { Write-Build DarkGray "    $($t.test)" }
    }

    if ($summary.uid -eq '0') { throw 'the in-container suite ran as root; it proves nothing about the leash' }
    if ($summary.failed -gt 0) { throw "$($summary.failed) test(s) failed inside the container" }
    if (@($summary.unjustified_skips).Count -gt 0) {
        throw ("no justification tag (BLOCKER-n or SkipWhen:<reason>) on: " +
            (@($summary.unjustified_skips) -join ', '))
    }
    if ($summary.passed -eq 0) { throw 'no tests ran inside the container; that is a failure, not a pass' }

    Write-Build Green 'Test.InContainer: green.'
}

