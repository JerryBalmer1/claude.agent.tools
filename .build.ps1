#Requires -Version 7.4

<#
.SYNOPSIS
    Invoke-Build entry point for claude.agent.tools.

.DESCRIPTION
    Copied from claude.agent.images@249752d (blob f75bca92), then adapted.
    Tools builds no image and carries no assessment, so the chain is
    Bootstrap then Test.Unit. The Pester pin is read from config/repo.json
    -> tooling.pester instead of a literal here, which is the same number
    CI's `pester` check installs.

    PowerShell 7.4+ is mandatory: $PSNativeCommandUseErrorActionPreference = $true
    so native command failures (git) surface as terminating errors.

.PARAMETER Configuration
    Debug or Release. Carried on the build context.

.PARAMETER OutputPath
    Directory for build artifacts. Defaults to ./output.

.PARAMETER SkipBootstrap
    Skip dependency installation.

.EXAMPLE
    Invoke-Build Full
    Bootstrap, then the whole suite on this host.

.EXAMPLE
    Invoke-Build ?
    Lists every available task.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = "$PSScriptRoot/output",

    [switch]$SkipBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module -Name InvokeBuild -Force -ErrorAction Stop

$repoConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config' 'repo.json') -Raw |
    ConvertFrom-Json -Depth 20

# Resolved once. Every task reads from $Build, never from a literal.
$script:Build = [pscustomobject]@{
    RepositoryRoot = $PSScriptRoot
    OutputPath     = $OutputPath
    Configuration  = $Configuration
    SkipBootstrap  = [bool]$SkipBootstrap
    PesterVersion  = [string]$repoConfig.tooling.pester
    TestRoot       = Join-Path $PSScriptRoot 'tests'
    CoreRoot       = Join-Path $PSScriptRoot 'vendor' 'claude.agent.core'
}

Import-Module (Join-Path $PSScriptRoot 'build' 'Build.Helpers.psm1') -Force -ErrorAction Stop

$taskDir = Join-Path $PSScriptRoot 'build' 'tasks'
if (Test-Path $taskDir) {
    Get-ChildItem -Path $taskDir -Filter '*.build.ps1' | ForEach-Object {
        . $_.FullName
    }
}

Enter-Build {
    Write-Build DarkGray ("Build root: {0} | Config: {1} | Output: {2}" -f $script:Build.RepositoryRoot, $script:Build.Configuration, $script:Build.OutputPath)
}

# Synopsis: Grouped task catalog for humans and agents (no Bootstrap).
task Help {
    $records = foreach ($task in ${*}.All.Values) {
        $jobs = foreach ($job in @($task.Jobs)) {
            if ($job -is [string]) { $job } else { '{}' }
        }
        [pscustomobject]@{
            Name     = $task.Name
            Synopsis = Get-BuildSynopsis $task
            Jobs     = @($jobs)
        }
    }
    $records | Format-Table -AutoSize | Out-String | Write-Build Cyan
}

# Synopsis: Everything a pull request must satisfy on this host.
task Full Bootstrap, Test.Unit

# Synopsis: Fast inner loop -- the suite only, no dependency check.
task Quick Test.Unit

# Synopsis: Default chain, the same as Full.
task . Full
