#Requires -Version 7.4
<#
.SYNOPSIS
    Prints live repository state as a paste-ready block. Read-only.

.DESCRIPTION
    Every stale-state incident in this repo has come from a human or an agent
    typing SHAs and PR numbers by hand. This script exists so nobody has to.

    It is read-only. The only thing it changes is remote-tracking refs, via
    `git fetch --prune` — without that the output would be confidently wrong,
    which is the exact failure it exists to prevent. Pass -NoFetch to skip it.

    Paste the output into a planning chat. If a plan's Context disagrees with
    this output, the plan is wrong.

    Copied from claude.agent.images@249752d (blob d1d3704a), then adapted: the
    citations of FLOW.md, AFTER-CLAUDE-COMMITS.md and snake.ps1 are gone because
    none of them exist in this repository, and the active-plan section reads
    docs/plans/<date>-<slug>/PLAN.md. The origin guard is unchanged.

.PARAMETER NoFetch
    Skip `git fetch`. Output may be stale. Use only when offline.

.EXAMPLE
    pwsh -NoProfile -File scripts/state.ps1
#>
[CmdletBinding()]
param(
    [switch] $NoFetch
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-Tolerant {
    <#  Native commands throw under $PSNativeCommandUseErrorActionPreference. For
        probes where "it failed" is a legitimate answer, that has to be caught. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Command,
        $Fallback = $null
    )
    try {
        $out = & $Command 2>$null
        if ($LASTEXITCODE -ne 0) { return $Fallback }
        return $out
    }
    catch {
        Write-Debug "tolerated failure: $($_.Exception.Message)"
        return $Fallback
    }
}

function ConvertFrom-JsonTolerant {
    <#  gh prints its "Unknown JSON field" complaint to stderr and still exits 0,
        so a field rename in a future gh yields non-JSON here rather than an
        error. Degrade to nothing instead of taking the whole report down. #>
    [CmdletBinding()]
    param($Json)
    if (-not $Json) { return $null }
    try {
        return ($Json | ConvertFrom-Json)
    }
    catch {
        Write-Debug "unparseable gh output: $($_.Exception.Message)"
        return $null
    }
}

function Get-RefSha {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Ref)
    $sha = Invoke-Tolerant -Command { git rev-parse --short $Ref } -Fallback $null
    if ([string]::IsNullOrWhiteSpace($sha)) { return 'unknown' }
    return ([string]$sha).Trim()
}

function Write-Section {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name)
    Write-Host ''
    Write-Host "-- $Name "
}

# --------------------------------------------------------------------------
# guard: the work tree this script BELONGS to, or nothing
# --------------------------------------------------------------------------

$root = Invoke-Tolerant -Command { git rev-parse --show-toplevel } -Fallback $null
if (-not $root) {
    Write-Host 'state: not inside a git work tree.'
    Write-Host "state: cd to the clone first."
    exit 1
}
$root = ([string]$root).Trim()

# THE ORIGIN IS READ, NEVER ASSERTED AGAINST A NAME. This guard was pinned to
# the literal 'claude.pwsh.image.builder' and therefore exited 1 in
# claude.agent.images, the repository it was carried into at birth - so every
# state block here was hand-assembled instead, which is the exact failure the
# script exists to prevent. Replacing one hardcoded name with two would just
# reschedule that bug for the next birth.
#
# What is asserted instead is the property that makes the report trustworthy: the
# work tree being reported on is the work tree THIS COPY of the script lives in.
# Run from inside another clone, it says so, rather than quietly printing that
# clone's branches under this one's name. Compared as resolved full paths, because
# git answers with forward slashes on Windows and a string compare would fail on
# the separator alone.
$origin = ([string](Invoke-Tolerant -Command { git remote get-url origin } -Fallback '')).Trim()

$scriptRoot = Invoke-Tolerant -Command { git -C $PSScriptRoot rev-parse --show-toplevel } -Fallback $null
if (-not $scriptRoot) {
    Write-Host 'state: this script is not itself inside a git work tree.'
    Write-Host "state: script at $PSScriptRoot."
    exit 1
}
$scriptRoot = ([string]$scriptRoot).Trim()

if ([System.IO.Path]::GetFullPath($root) -ne [System.IO.Path]::GetFullPath($scriptRoot)) {
    Write-Host 'state: wrong work tree.'
    Write-Host "state: reporting on    $root  (origin = $origin)"
    Write-Host "state: script lives in $scriptRoot"
    Write-Host 'state: cd into the clone this script belongs to.'
    exit 1
}

if (-not $NoFetch) {
    Write-Verbose 'fetching remote refs'
    $null = Invoke-Tolerant -Command { git fetch origin --prune --quiet } -Fallback $null
}

$gh = Get-Command gh -ErrorAction SilentlyContinue

# --------------------------------------------------------------------------
# report
# --------------------------------------------------------------------------

Write-Host '=== LIVE STATE - generated, do not hand-edit ==='
Write-Host ("generated:    {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss K'))
Write-Host ("repo root:    {0}" -f $root)
Write-Host ("origin:       {0}" -f $origin)
if ($NoFetch) { Write-Host 'WARNING:      -NoFetch used, remote values may be stale' }

Write-Section 'branch'
$branch = (Invoke-Tolerant -Command { git rev-parse --abbrev-ref HEAD } -Fallback 'unknown')
$dirty = @(Invoke-Tolerant -Command { git status --porcelain } -Fallback @())
Write-Host ("current:      {0} @ {1}" -f ([string]$branch).Trim(), (Get-RefSha -Ref 'HEAD'))
if ($dirty.Count -gt 0) {
    Write-Host ("tree:         DIRTY - {0} path(s)" -f $dirty.Count)
    $dirty | ForEach-Object { Write-Host "                $_" }
}
else {
    Write-Host 'tree:         clean'
}

Write-Section 'key refs'
foreach ($ref in 'origin/main', 'origin/develop', 'main', 'develop') {
    Write-Host ("{0,-22}{1}" -f ($ref + ':'), (Get-RefSha -Ref $ref))
}

Write-Section 'local branches not merged into develop'
$unmerged = @(Invoke-Tolerant -Command { git branch --no-merged develop --format='%(refname:short)' } -Fallback @())
if ($unmerged.Count -eq 0) {
    Write-Host '(none)'
}
else {
    foreach ($b in $unmerged) {
        $b = ([string]$b).Trim()
        if (-not $b) { continue }
        $ahead = Invoke-Tolerant -Command { git rev-list --count "develop..$b" } -Fallback '?'
        $pushed = if ((Get-RefSha -Ref "origin/$b") -eq 'unknown') { 'NOT PUSHED' } else { 'pushed' }
        Write-Host ("{0,-34}{1,3} commit(s) ahead   {2}" -f $b, ([string]$ahead).Trim(), $pushed)
    }
}

Write-Section 'pull requests'
if (-not $gh) {
    Write-Host 'gh not installed - PR state unavailable'
}
else {
    # One quoted string, not a comma list: PowerShell would split the latter into
    # separate arguments and gh would reject it.
    $prs = Invoke-Tolerant -Command {
        gh pr list --state all --limit 15 --json 'number,state,title,baseRefName,headRefName,mergeable'
    } -Fallback $null
    $parsed = ConvertFrom-JsonTolerant -Json $prs
    if (-not $parsed) {
        Write-Host 'gh present but returned nothing (not authenticated?)'
    }
    else {
        $open = @($parsed | Where-Object { $_.state -eq 'OPEN' })
        if ($open.Count -eq 0) {
            Write-Host 'open:         (none)'
        }
        else {
            Write-Host 'open:'
            foreach ($p in $open) {
                Write-Host ("  #{0}  {1} -> {2}  [{3}]  {4}" -f $p.number, $p.headRefName, $p.baseRefName, $p.mergeable, $p.title)
            }
            # A head branch cut from another open PR's head must merge after it.
            foreach ($p in $open) {
                foreach ($q in $open) {
                    if ($p.number -eq $q.number) { continue }
                    $isChained = Invoke-Tolerant -Command {
                        git merge-base --is-ancestor "origin/$($q.headRefName)" "origin/$($p.headRefName)"
                        if ($LASTEXITCODE -eq 0) { 'yes' } else { 'no' }
                    } -Fallback 'no'
                    if ($isChained -eq 'yes') {
                        Write-Host ("  ORDER: #{0} must merge BEFORE #{1} (#{1} is built on it)" -f $q.number, $p.number)
                    }
                }
            }
        }
        $merged = @($parsed | Where-Object { $_.state -eq 'MERGED' } | Select-Object -First 5)
        if ($merged.Count -gt 0) {
            Write-Host 'merged (recent):'
            foreach ($p in $merged) {
                Write-Host ("  #{0}  {1} -> {2}  {3}" -f $p.number, $p.headRefName, $p.baseRefName, $p.title)
            }
        }
    }
}

Write-Section 'ci'
if (-not $gh) {
    Write-Host 'gh not installed - CI state unavailable'
}
else {
    # Field names vary between gh versions; displayTitle is not universal.
    $runs = Invoke-Tolerant -Command {
        gh run list --limit 6 --json 'headBranch,status,conclusion,name,headSha'
    } -Fallback $null
    $parsedRuns = ConvertFrom-JsonTolerant -Json $runs
    if (-not $parsedRuns) {
        Write-Host '(no runs returned)'
    }
    else {
        foreach ($r in $parsedRuns) {
            $verdict = if ($r.status -ne 'completed') { ([string]$r.status).ToUpperInvariant() } else { ([string]$r.conclusion).ToUpperInvariant() }
            $sha = if ($r.headSha) { ([string]$r.headSha).Substring(0, 7) } else { '-------' }
            Write-Host ("{0,-10}{1,-28}{2,-9}{3}" -f $verdict, $r.headBranch, $sha, $r.name)
        }
    }
}

Write-Section 'tags'
$localTags = @(Invoke-Tolerant -Command { git tag -l } -Fallback @())
$remoteTags = @(Invoke-Tolerant -Command { git ls-remote --tags origin } -Fallback @())
Write-Host ("local:        {0}" -f $(if ($localTags.Count) { $localTags -join ', ' } else { 'none' }))
Write-Host ("remote:       {0}" -f $(if ($remoteTags.Count) { $remoteTags.Count.ToString() + ' ref(s)' } else { 'none' }))

Write-Section 'merge settings (squash-only flattens chained PRs)'
if (-not $gh) {
    Write-Host 'gh not installed - settings unavailable'
}
else {
    $repoJson = Invoke-Tolerant -Command {
        gh api "repos/{owner}/{repo}" --jq '{m:.allow_merge_commit,s:.allow_squash_merge,r:.allow_rebase_merge,p:.private}'
    } -Fallback $null
    $s = ConvertFrom-JsonTolerant -Json $repoJson
    if (-not $s) {
        Write-Host '(unavailable)'
    }
    else {
        Write-Host ("merge commits: {0}   squash: {1}   rebase: {2}   private: {3}" -f $s.m, $s.s, $s.r, $s.p)
        if (-not $s.m) { Write-Host 'WARNING:      merge commits are DISABLED - chained PRs will be flattened' }
        # NO WARNING ON VISIBILITY. This printed "repository is PUBLIC - it must not be",
        # sourced from an AGENTS.md rule that was RETIRED on 2026-09-23 when Jerry decided the
        # repository stays public (disagreement table row 8, forensic chain seq 16). The
        # `private:` value above stays, because visibility is a fact worth reporting and this
        # script exists to report facts. What it no longer does is call that fact a violation
        # of a rule that no longer exists - a report that judges by a retired rule is worse
        # than one that does not judge, because a reader cannot tell which of its warnings
        # still mean anything. The merge-commit warning above stays: that rule is live, and
        # AGENTS.md still requires merges rather than squashes.
    }
}

Write-Section 'plans'
# Tools records each packet's plan at docs/plans/<yyyy-MM-dd>-<slug>/PLAN.md. There is no
# ACTIVE.md here; the newest dated folder is the current one, and the report names it.
$plansDir = Join-Path $root 'docs/plans'
$plans = @()
if (Test-Path -LiteralPath $plansDir) {
    $plans = @(Get-ChildItem -LiteralPath $plansDir -Directory |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'PLAN.md')) } |
        Sort-Object -Property Name)
}
if ($plans.Count -eq 0) {
    Write-Host 'docs/plans: no dated PLAN.md'
}
else {
    Write-Host ("newest:       docs/plans/{0}/PLAN.md   ({1} plan(s))" -f $plans[-1].Name, $plans.Count)
}

Write-Section 'guard preview (CI enforces these)'
# Anchored: a trailer is a line starting with the key, not any mention of it.
$trailers = @(Invoke-Tolerant -Command { git log develop..HEAD --format='%b' } -Fallback @()) |
    Where-Object { $_ -match '(?im)^co-authored-by:' }
Write-Host ("Co-Authored-By on this branch: {0}" -f $(if ($trailers.Count) { 'PRESENT - CI WILL FAIL' } else { 'none' }))
$lightweight = @($localTags | Where-Object {
        $t = Invoke-Tolerant -Command { git cat-file -t (git rev-parse $_) } -Fallback 'unknown'
        ([string]$t).Trim() -ne 'tag'
    })
Write-Host ("lightweight tags:              {0}" -f $(if ($lightweight.Count) { ($lightweight -join ', ') + ' - CI WILL FAIL' } else { 'none' }))

Write-Host ''
Write-Host '=== END LIVE STATE ==='
Write-Host 'This output outranks any pasted state block.'
exit 0
