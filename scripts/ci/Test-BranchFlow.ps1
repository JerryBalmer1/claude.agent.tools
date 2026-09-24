#Requires -Version 7.4
#
# COPIED, NOT VENDORED.
#   origin repo   : claude.agent.substrate
#   origin file   : scripts/ci/Test-BranchFlow.ps1
#   origin commit : 912c1c9eb48ab0b639d257bc7b10661d7212f985
#   origin sha256 : d8aee82fb7a25748864b9c08b9e9ce5afb685bea3671d527b6ef5e1b560f0275
#   adapted here  : no - byte-identical at copy time
#
# There is no submodule here and substrate does not follow this copy. If substrate's
# version moves, this one does not move with it. Diff the two against the origin commit
# above before assuming they still agree.
#
<#
.SYNOPSIS
    CI check "branch-flow": the (head, base) pair of a pull request matches a row in config.flow.

.DESCRIPTION
    config/repo.json -> flow is a list of [head-pattern, base] pairs. The head side is a glob
    (`feature/*`); the base side is an exact, case-sensitive branch name.

    This is what refuses `feature/x -> main`. There is no path that skips develop, and the only
    place that fact is written down is the config.

.EXAMPLE
    pwsh -NoProfile -File scripts/ci/Test-BranchFlow.ps1 -Head feature/repo-policy -Base develop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Head,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Base
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version 3.0

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$config   = (Get-Content -LiteralPath (Join-Path $RepoRoot 'config/repo.json') -Raw | ConvertFrom-Json -Depth 20)

# Refs sometimes arrive fully qualified depending on which event field CI hands over.
$h = $Head -replace '^refs/heads/', ''
$b = $Base -replace '^refs/heads/', ''

Write-Host "branch-flow: head '$h' -> base '$b'"
Write-Host 'branch-flow: allowed rows from config/repo.json -> flow'
foreach ($row in $config.flow) { Write-Host ("  {0,-20} -> {1}" -f $row[0], $row[1]) }

$matched = $null
foreach ($row in $config.flow) {
    if (($h -like $row[0]) -and ($b -ceq $row[1])) { $matched = $row; break }
}

if ($null -eq $matched) {
    Write-Host "branch-flow: FAIL -- '$h' -> '$b' matches no row in config.flow"
    Write-Host 'branch-flow: work goes feature/* -> develop -> main. Nothing skips develop.'
    exit 1
}

Write-Host "branch-flow: PASS -- matched row [$($matched[0]) -> $($matched[1])]"
exit 0
