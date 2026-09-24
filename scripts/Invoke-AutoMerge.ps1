#Requires -Version 7.4
#
# COPIED, NOT VENDORED.
#   origin repo   : claude.agent.substrate
#   origin file   : scripts/Invoke-AutoMerge.ps1
#   origin commit : 912c1c9eb48ab0b639d257bc7b10661d7212f985
#   origin sha256 : b3c9716326dd26d433f56e7c09d26a3b4afdd4ae4a5b2fbecf81165dd054beb8
#   adapted here  : no - byte-identical at copy time
#
# There is no submodule here and substrate does not follow this copy. If substrate's
# version moves, this one does not move with it. Diff the two against the origin commit
# above before assuming they still agree.
#
<#
.SYNOPSIS
    Merges a green pull request with a merge commit, while review.mode is "auto".

.DESCRIPTION
    Called by .github/workflows/automerge.yml. Exits 0 in every "not yet" case - a PR that is
    not ready is not an error, and a red automerge run on every push would be noise that hides
    a real failure.

    THREE DELIBERATE DEPARTURES FROM THE OBVIOUS IMPLEMENTATION, each because the obvious one
    is wrong here:

    1. `gh pr checks --required` is NOT used. "Required" is a branch-protection concept, and
       branch protection is not available on a private repository on the free tier - see
       docs/plans/2026-09-21-repo-policy/PROTECTION.md. On this repo `--required` has no set to
       report on. Instead the required set is read from config/repo.json, which is where it is
       defined anyway, and each name is looked up in the commit's check runs. That is stronger
       than --required, not weaker: it is config-driven rather than dependent on a paid feature,
       and a check that silently stopped reporting is absent rather than green-by-omission.

    2. `--delete-branch` is passed ONLY for feature branches. The run order said to pass it
       unconditionally; that would ask GitHub to delete `develop` when merging the
       develop -> main pull request. GitHub would likely refuse while develop is the default
       branch, but relying on a refusal is not a design. The head branch is checked against
       config.branches.feature_prefix and the long-lived branches are never deleted.

    3. The merge commit body carries a `who:` trailer. A merge commit cannot be repaired after
       the fact without rewriting pushed history, so the trailer has to be right at creation.
       scripts/ci/Test-Trailers.ps1 -IncludeMerges is what confirms it worked.

    THE KNOWN HOLE IS CLOSED (2026-09-21). It is left written down rather than deleted, because
    a hole that is quietly tidied away teaches nobody what to look for.

    What it was: review.mode was read from the PULL REQUEST HEAD, as the original run order
    specified. A pull request could flip review.mode from "human" to "auto" in its own diff and
    thereby authorise its own merge - the gate and the thing being gated were the same object.
    This script recorded that and said it was Jerry's call to make, not the script's.

    Jerry made the call: read it from the base. The config is now fetched once, from the base
    BRANCH, by scripts/AutoMerge.Lib.ps1, and it supplies review.mode AND required_checks AND
    branches - because a pull request that deleted a required check from its own config was the
    same hole wearing a different hat. The accepted cost is that a review.mode change does not
    govern the pull request that introduces it, only the ones after it has merged.

    tests/AutoMerge.Tests.ps1 is the proof, and it costs nothing to re-run: reverting
    Get-ReviewConfigRef to the head turns it red without a pull request being opened.

.EXAMPLE
    ./scripts/Invoke-AutoMerge.ps1 -Repo JerryBalmer1/claude.agent.substrate -PullRequest 1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Repo,
    [string]$PullRequest = '',
    [string]$HeadBranch  = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version 3.0

# The review-mode gate. Dot-sourced rather than inlined so that tests/AutoMerge.Tests.ps1 can
# drive the exact code path that runs here.
. (Join-Path $PSScriptRoot 'AutoMerge.Lib.ps1')

function Write-Step { param([string]$Message) Write-Host "automerge: $Message" }

# ------------------------------------------------------------------ resolve the pull request

$number = 0
if ($PullRequest -match '^\d+$') {
    $number = [int]$PullRequest
    Write-Step "pull request #$number (from the pull_request event)"
}
elseif (-not [string]::IsNullOrWhiteSpace($HeadBranch)) {
    Write-Step "no PR number on the event; looking for an open PR with head '$HeadBranch'"
    $found = @(gh pr list --repo $Repo --head $HeadBranch --state open --json number --limit 5 |
               ConvertFrom-Json -Depth 10)
    if ($found.Count -eq 0) {
        Write-Step "no open pull request for '$HeadBranch' - nothing to do"
        exit 0
    }
    $number = [int]$found[0].number
    Write-Step "pull request #$number (resolved from the workflow_run head branch)"
}
else {
    Write-Step 'neither a PR number nor a head branch on this event - nothing to do'
    exit 0
}

$pr = gh pr view $number --repo $Repo --json number,title,state,isDraft,headRefName,headRefOid,baseRefName |
      ConvertFrom-Json -Depth 20

Write-Step "#$($pr.number) '$($pr.title)'  $($pr.headRefName) -> $($pr.baseRefName)  state=$($pr.state) draft=$($pr.isDraft)"

if ($pr.state -ne 'OPEN') { Write-Step "state is $($pr.state), not OPEN - nothing to do"; exit 0 }
if ($pr.isDraft)          { Write-Step 'pull request is a draft - nothing to do'; exit 0 }

# ------------------------------------------------------------------ the review-mode gate

# One read, from the BASE branch. See the closed-hole note above and tests/AutoMerge.Tests.ps1.
# $config is used below for required_checks and branches as well, and it is the base's copy of
# both on purpose - the head does not get a say in what gates it.
$gate   = Test-ReviewModeAuto -Repo $Repo -PullRequest $pr
$config = $gate.Config

Write-Step "review.mode = '$($gate.Mode)' (read from BASE '$($gate.Ref)', not from the head)"
if (-not $gate.IsAuto) {
    Write-Step "review.mode is not 'auto' - standing down, a human merges this one"
    Write-Host "::notice title=automerge stood down::review.mode is '$($gate.Mode)' on base '$($gate.Ref)'; this pull request will not be merged by automation."
    exit 0
}

# ------------------------------------------------------------------ the checks

$required = @($config.required_checks)
Write-Step "required checks from config: $($required -join ', ')"

$runs = gh api "repos/$Repo/commits/$($pr.headRefOid)/check-runs?per_page=100" --jq '.check_runs[] | [.name, .status, (.conclusion // "")] | @tsv'
$byName = @{}
foreach ($line in @($runs)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split "`t"
    # A name can report more than once across re-runs; the newest is first from this endpoint.
    if (-not $byName.ContainsKey($parts[0])) {
        $byName[$parts[0]] = [pscustomobject]@{ Status = $parts[1]; Conclusion = $parts[2] }
    }
}

$notGreen = [System.Collections.Generic.List[string]]::new()
foreach ($name in $required) {
    if (-not $byName.ContainsKey($name)) {
        Write-Step "  ABSENT     $name"
        $notGreen.Add($name); continue
    }
    $r = $byName[$name]
    if ($r.Status -ne 'completed') {
        Write-Step "  $($r.Status.PadRight(10)) $name"
        $notGreen.Add($name); continue
    }
    if ($r.Conclusion -ne 'success') {
        Write-Step "  $($r.Conclusion.PadRight(10)) $name"
        $notGreen.Add($name); continue
    }
    Write-Step "  success    $name"
}

if ($notGreen.Count -gt 0) {
    Write-Step "$($notGreen.Count) of $($required.Count) required check(s) not green yet: $($notGreen -join ', ')"
    Write-Step 'exiting 0 - this will run again when ci completes'
    exit 0
}

# ------------------------------------------------------------------ merge

$featurePrefix = $config.branches.feature_prefix
$longLived     = @($config.branches.main, $config.branches.develop)
$deleteBranch  = ($pr.headRefName.StartsWith($featurePrefix)) -and ($longLived -notcontains $pr.headRefName)

Write-Step "all $($required.Count) required checks green; merging with a merge commit"
Write-Step ("delete the head branch afterwards: {0} (head '{1}', feature prefix '{2}')" -f $deleteBranch, $pr.headRefName, $featurePrefix)

$subject = "Merge pull request #$($pr.number) from $($pr.headRefName)"
$body    = @(
    $pr.title
    ''
    "Merged by .github/workflows/automerge.yml. review.mode was 'auto' and every check in"
    'config/repo.json -> required_checks reported success:'
    ''
    ($required | ForEach-Object { "  $_" })
    ''
    "head $($pr.headRefOid) ($($pr.headRefName)) into $($pr.baseRefName)"
    ''
    'who: claude'
) -join "`n"

$mergeArgs = @('pr', 'merge', "$($pr.number)", '--repo', $Repo, '--merge', '--subject', $subject, '--body', $body)
if ($deleteBranch) { $mergeArgs += '--delete-branch' }

& gh @mergeArgs

Write-Step "merged #$($pr.number)"
exit 0
