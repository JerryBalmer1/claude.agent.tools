#Requires -Version 7.4
<#
.SYNOPSIS
Test for Resolve-RetiredPaths.ps1
#>

BeforeAll {
    $script:resolverPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts' 'Resolve-RetiredPaths.ps1'
}

Describe 'Resolve-RetiredPaths' {
    It 'exits 0 when zero paths resolve on disk' {
        & pwsh -NoProfile -File $script:resolverPath
        $LASTEXITCODE | Should -Be 0
    }
}
