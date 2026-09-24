#Requires -Version 7.4

<#
.SYNOPSIS
    Invoke-Build entry point for claude.agent.images.

.DESCRIPTION
    Builds the agent images (claude.pwsh.image.developer, future .agent) and
    enforces the shared plan contract: structured plan output, fail-first
    tests, and skills that don't exist yet (to be built).

    This is the only supported entry point. Never call docker, Invoke-Pester,
    or Invoke-ScriptAnalyzer directly.

    PowerShell 7.4+ is mandatory: $PSNativeCommandUseErrorActionPreference = $true
    so native command failures (docker build, git) surface as terminating errors.

.PARAMETER Configuration
    Debug or Release. Carried on the build context.

.PARAMETER OutputPath
    Directory for build artifacts. Defaults to ./output.

.PARAMETER SkipBootstrap
    Skip dependency installation.

.PARAMETER Preview
    Show what a state-changing task would do, without doing it.

.EXAMPLE
    Invoke-Build
    Runs the default chain.

.EXAMPLE
    Invoke-Build ?
    Lists every available task (tab-completable via ArgumentCompleters).
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = "$PSScriptRoot/output",

    [switch]$SkipBootstrap,

    [switch]$Preview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 7.4+ only. Native executables that exit non-zero become terminating errors
# inside try/catch, so docker, git cannot fail silently in a task.
$PSNativeCommandUseErrorActionPreference = $true

# Loaded on EVERY Invoke-Build invocation. Force + Stop so a stale copy in the
# session never masks an edit.
Import-Module -Name InvokeBuild -Force -ErrorAction Stop

# Resolved once. Every task reads from $Build, never from a literal.
$script:Build = [pscustomobject]@{
    RepositoryRoot = $PSScriptRoot
    OutputPath     = $OutputPath
    Configuration  = $Configuration
    WhatIf         = [bool]$Preview
    SkipBootstrap  = [bool]$SkipBootstrap

    # run-01. Pinned here so no task carries a literal tag or version.
    LeashTag       = 'claude.pwsh.image.leash:run-01'
    DeveloperTag   = 'claude.pwsh.image.developer:run-01'
    PesterVersion  = '6.1.0'
    RunId          = 'run-01'

    # The gate from the run order's WHERE block. Canonical sha256 (keys sorted
    # ordinal, no whitespace) of prompts/assessment.2026-09-21.json.
    AssessmentPath = Join-Path $PSScriptRoot 'prompts' 'assessment.2026-09-21.json'
    AssessmentSha  = '798b10ee3ca2d64b28bc779611484ddc0565448c6468ae2ddaf54a53a98030a3'
}

Import-Module (Join-Path $PSScriptRoot 'build' 'Build.Helpers.psm1') -Force -ErrorAction Stop

# Task files. Each is thin; helpers do the work.
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

# Synopsis: Default chain -- everything a pull request must satisfy.
#
# Test.FailFirst is gone. It asserted that a test calling a function that did
# not exist would fail, and then treated that failure as proof the discipline
# was working; it would have stayed green against any validator at all,
# including none. The real suite replaces it, and Test.InContainer runs it
# where it counts.
task . Bootstrap, Build.Image, Test.InContainer, Goal.Update

# Synopsis: Fast inner loop for local development -- host only, no image build.
task Quick Plan.Check, Test.Unit

# Synopsis: Everything, host and container. Slower than the default chain.
task Full Bootstrap, Plan.Check, Build.Image, Test.Unit, Test.InContainer, Skills.Audit, Goal.Update
