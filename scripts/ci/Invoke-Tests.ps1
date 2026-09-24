#Requires -Version 7.4
#
# COPIED, NOT VENDORED.
#   origin repo   : claude.agent.substrate
#   origin file   : scripts/ci/Invoke-Tests.ps1
#   origin commit : 912c1c9eb48ab0b639d257bc7b10661d7212f985
#   origin sha256 : 6c6db2077f706dca66efc6a2acd91aa3b8aa06dcd7c09d233061f7c5d14b8345
#   adapted here  : YES - adapted for this repo, diff before assuming they agree
#   carried via   : claude.agent.images@249752d, blob 3d92bb83, adapted again for tools
#
# There is no submodule here and substrate does not follow this copy. If substrate's
# version moves, this one does not move with it. Diff the two against the origin commit
# above before assuming they still agree.
#
<#
.SYNOPSIS
    CI check "pester": runs the suite under the exact Pester version pinned in config/repo.json.

.DESCRIPTION
    The version is PINNED, from config/repo.json -> tooling.pester, and imported with
    -RequiredVersion. A suite whose runner floats is not a control: a green that came from a
    different Pester than the one the result was recorded under proves less than it looks like.

    Windows images ship a signed Pester 3.4.0 in the system module path, whose command surface
    is incompatible with 5.x. -SkipPublisherCheck and an explicit -RequiredVersion import are
    what stop that one being picked up.

    The suite is whatever Get-SuiteFile returns, the function Test.Unit and tests/run.ps1 also
    call: tests/*.Tests.ps1 plus tests/Test-*.ps1. Pester handed the directory alone would skip
    the compliance runner, whose name is not *.Tests.ps1.

    No tag is excluded. images excluded `Docker` here because its Docker-tagged tests needed
    both images built; tools builds no image and has no such tests.

.EXAMPLE
    pwsh -NoProfile -File scripts/ci/Invoke-Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version 3.0

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$config   = (Get-Content -LiteralPath (Join-Path $RepoRoot 'config/repo.json') -Raw | ConvertFrom-Json -Depth 20)
$pinned   = $config.tooling.pester

$helpers = Join-Path $RepoRoot 'build/Build.Helpers.psm1'
Import-Module $helpers -Force -ErrorAction Stop

# The vendored core MUST be present. -Policy resolves against its policy module, so a checkout
# without the submodule would run a suite that cannot exercise the thing it tests.
$policyManifest = Join-Path $RepoRoot 'vendor/claude.agent.core/modules/policy/policy.psd1'
if (-not (Test-Path -LiteralPath $policyManifest)) {
    Write-Host ''
    Write-Host 'pester: FAIL -- the vendored core is NOT present.'
    Write-Host "pester:   expected  $policyManifest"
    Write-Host 'pester:   fix       the actions/checkout step needs submodules: recursive.'
    Write-Host 'pester:             core is public; no token is required.'
    exit 1
}

$files = Get-SuiteFile -TestRoot (Join-Path $RepoRoot 'tests')

# An empty suite is a failure. The birth packet reported a 0/0/0/0 gate here while tests/ held no
# suite file; PR 1 landed the first tests and closed that branch.
if ($files.Count -eq 0) {
    Write-Host 'pester: FAIL -- no suite files under tests/; an empty suite is not a green'
    exit 1
}

Write-Host "pester: pinned version $pinned (config/repo.json -> tooling.pester)"

$have = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version.ToString() -eq $pinned } |
        Select-Object -First 1

if (-not $have) {
    Write-Host "pester: $pinned not installed, installing from PSGallery"
    Install-Module -Name Pester -RequiredVersion $pinned -Force -SkipPublisherCheck `
                   -Scope CurrentUser -AllowClobber -ErrorAction Stop
}

Remove-Module Pester -Force -ErrorAction SilentlyContinue
Import-Module Pester -RequiredVersion $pinned -Force -ErrorAction Stop
Write-Host "pester: imported $((Get-Module Pester).Version)"
Write-Host "pester: $($files.Count) suite file(s)"

$pc = New-PesterConfiguration
$pc.Run.Path           = $files
$pc.Run.PassThru       = $true
$pc.Output.Verbosity   = 'Detailed'
$pc.TestResult.Enabled = $false

$result = Invoke-Pester -Configuration $pc

Write-Host ''
Write-Host ("pester: gate passed={0} failed={1} skipped={2} notrun={3} total={4} duration={5}" -f
    $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.NotRunCount,
    $result.TotalCount, $result.Duration)

# Assert-SuiteClean is the SAME function Test.Unit calls, from build/Build.Helpers.psm1 - not a
# port of it. It fails on a failed test, on a skip with no BLOCKER-n or SkipWhen:<reason> tag on
# the test object, and on a run where nothing passed.
try {
    Assert-SuiteClean -Result $result -Where 'pester'
}
catch {
    Write-Host ''
    Write-Host $_.Exception.Message
    Write-Host 'pester: FAIL'
    exit 1
}

Write-Host 'pester: PASS'
exit 0
