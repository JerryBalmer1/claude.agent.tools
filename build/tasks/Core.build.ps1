#Requires -Version 7.4

<#
.SYNOPSIS
    Clean and Bootstrap.
#>

# Synopsis: Remove output/.
task Clean {
    $out = $Build.OutputPath
    if (Test-Path -LiteralPath $out) {
        Remove-Item -LiteralPath $out -Recurse -Force
        Write-Build DarkGray "Removed $out"
    }
}

# Synopsis: Preflight gate plus pinned host dependencies. Idempotent.
task Bootstrap {
    # ---- the gate -------------------------------------------------------
    # The assessment hash is checked before anything else in the chain runs.
    # Every later step is taken on the authority of that document, so if the
    # copy on disk is not the copy the run order named, the correct number of
    # steps to take is zero.
    $sha = Test-AssessmentHash -Path $Build.AssessmentPath -ExpectedSha256 $Build.AssessmentSha
    Write-Build Green "Assessment verified: $sha"

    # ---- the snake ------------------------------------------------------
    $ledgerRoot = Join-Path $Build.RepositoryRoot 'vendor' 'claude.agent.core'
    $manifest = Join-Path $ledgerRoot 'modules' 'ledger' 'ledger.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "Vendored core missing: $manifest. Run: git submodule update --init"
    }
    $ledgerCommit = exec { git -C $ledgerRoot rev-parse --short HEAD }
    Write-Build Green "Ledger vendored at $ledgerCommit"

    if ($Build.SkipBootstrap) {
        Write-Build DarkGray 'Bootstrap: dependency install skipped (-SkipBootstrap).'
        return
    }

    # ---- host dependencies ----------------------------------------------
    # Pester is pinned to an exact version, not a floor. The image ships
    # exactly this version, and a host on a different one would be testing a
    # different Pester than the one the artefact promises.
    $pester = Get-Module -ListAvailable -Name 'Pester' |
        Where-Object { $_.Version -eq [version]$Build.PesterVersion } |
        Select-Object -First 1
    if (-not $pester) {
        Write-Build Yellow "Installing Pester $($Build.PesterVersion) ..."
        Install-PSResource -Name 'Pester' -Version $Build.PesterVersion -Scope CurrentUser `
            -TrustRepository -Reinstall -ErrorAction Stop
    }
    Write-Build Green "Pester $($Build.PesterVersion) present."

    foreach ($m in @('InvokeBuild', 'PSScriptAnalyzer')) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Write-Build Yellow "Installing $m ..."
            Install-PSResource -Name $m -Scope CurrentUser -TrustRepository -ErrorAction Stop
        }
    }

    # ---- docker ----------------------------------------------------------
    if (-not (Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'docker is not on PATH; Build.Image and Test.InContainer cannot run.'
    }

    Write-Build Green 'Bootstrap: dependencies present.'
}
