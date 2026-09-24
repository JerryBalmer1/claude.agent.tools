#Requires -Version 7.4

<#
.SYNOPSIS
    Clean and Bootstrap.

.DESCRIPTION
    Copied from claude.agent.images@249752d (blob 81f3dc56), then adapted.
    The assessment gate and the docker check are removed, because tools has
    neither an assessment nor an image. The vendored-core check stays, aimed
    at the policy module, since -Policy resolves against it.
#>

# Synopsis: Remove output/.
task Clean {
    $out = $Build.OutputPath
    if (Test-Path -LiteralPath $out) {
        Remove-Item -LiteralPath $out -Recurse -Force
        Write-Build DarkGray "Removed $out"
    }
}

# Synopsis: Vendored core present, pinned host dependencies installed. Idempotent.
task Bootstrap {
    $manifest = Join-Path $Build.CoreRoot 'modules' 'policy' 'policy.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "Vendored core missing: $manifest. Run: git submodule update --init"
    }
    $coreCommit = exec { git -C $Build.CoreRoot rev-parse --short HEAD }
    Write-Build Green "Core vendored at $coreCommit"

    if ($Build.SkipBootstrap) {
        Write-Build DarkGray 'Bootstrap: dependency install skipped (-SkipBootstrap).'
        return
    }

    # Pinned to an exact version, not a floor: CI's `pester` check installs
    # exactly this one, and a host on another would test a different Pester.
    $pester = Get-Module -ListAvailable -Name 'Pester' |
        Where-Object { $_.Version -eq [version]$Build.PesterVersion } |
        Select-Object -First 1
    if (-not $pester) {
        Write-Build Yellow "Installing Pester $($Build.PesterVersion) ..."
        Install-PSResource -Name 'Pester' -Version $Build.PesterVersion -Scope CurrentUser `
            -TrustRepository -Reinstall -ErrorAction Stop
    }
    Write-Build Green "Pester $($Build.PesterVersion) present."

    Write-Build Green 'Bootstrap: dependencies present.'
}
