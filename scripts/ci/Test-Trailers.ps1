#Requires -Version 7.4
#
# COPIED, NOT VENDORED.
#   origin repo   : claude.agent.substrate
#   origin file   : scripts/ci/Test-Trailers.ps1
#   origin commit : 912c1c9eb48ab0b639d257bc7b10661d7212f985
#   origin sha256 : 3f9cab8876aa55ebb6f5585dc8c6b27cab0b382a4897642754e36e5ee6dca2ec
#   adapted here  : YES - adapted for this repo, diff before assuming they agree
#
# There is no submodule here and substrate does not follow this copy. If substrate's
# version moves, this one does not move with it. Diff the two against the origin commit
# above before assuming they still agree.
#
<#
.SYNOPSIS
    CI check "trailer-guard": every commit in <Base>..HEAD carries an allowed `who:` trailer.

.DESCRIPTION
    The trailer key and its allowed values come from config/repo.json -> trailer.

    WHY MERGE COMMITS ARE EXCLUDED BY DEFAULT, stated plainly rather than hidden:

    A merge commit in this repo is created by GitHub at merge time, by the automerge workflow,
    not by an agent making a change. If one ever landed without a trailer, it could not be
    repaired afterwards - amending or rewriting a pushed commit is forbidden here - and the
    check would be permanently red on every later PR whose range contained it. A gate that can
    be wedged into permanent failure by its own tooling is not a gate, it is a trap.

    So the PR gate runs with --no-merges. That is NOT the same as not checking them:
    `.github/workflows/automerge.yml` writes `who: claude` into the merge commit body, and
    a run with -IncludeMerges against origin/main confirms it actually did. The check exists;
    it just is not the thing that can deadlock the flow.

    THE GRANDFATHER FILE (added 2026-09-21).

    .continuity/trailer-grandfather.txt names, by exact full 40-character hash, the commits
    that predate the guard and carry no trailer. They cannot be given one: repairing them means
    rewriting pushed history, which this repo forbids for a better reason than tidiness - the
    forensic chain cites several of these hashes as evidence, which is also why the list lives
    beside forensic.jsonl rather than in config/.

    The exemption is BY EXACT HASH and nothing else. Not by date, not by author, not by a
    pattern, not by "everything before commit X". Those all quietly widen over time; a list of
    forty-character strings is a thing tests/Trailers.Tests.ps1 can constrain, and it does: it
    requires every entry to be a real commit in this repository that genuinely lacks a trailer,
    so the list cannot be padded with compliant hashes to make room for one that is not.

    IN THIS REPOSITORY THE LIST IS EMPTY and the file is 0 bytes. The commits it named in
    claude.pwsh.image.builder were not carried over at birth; every commit here carries the
    trailer, so nothing needs exempting and the guard passes with a count of zero. The test
    that asserted a count of twenty-four was retired on 2026-09-23 (forensic seq 8, subject
    prebirth-tests-retired) because those commits are not in this tree.

    An absent grandfather file is treated as an EMPTY list, loudly, never as permission - the
    quietest possible failure mode for an exemption list is for its deletion to make everything
    pass. On the lineage this was written for, deleting the file turned a full-history run red
    on the seed commit. THAT IS NO LONGER THE DEMONSTRATION HERE, and saying so beats leaving a
    claim that measures false: with the list already empty, a full-history run passes either
    way. What is left is the WARNING on stdout, which names the missing path.

    -Base is OPTIONAL. Without it the range is every commit reachable from -Head, root included,
    which is the run the grandfather file exists to make possible. With it the range is
    <Base>..<Head>, which is what CI passes and which never contains the root commit at all.

.EXAMPLE
    pwsh -NoProfile -File scripts/ci/Test-Trailers.ps1 -Base origin/develop

.EXAMPLE
    pwsh -NoProfile -File scripts/ci/Test-Trailers.ps1 -Head HEAD -IncludeMerges
#>
[CmdletBinding()]
param(
    [string]$Base = '',
    [string]$Head = 'HEAD',
    [switch]$IncludeMerges,
    [string]$GrandfatherPath = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version 3.0

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$config   = (Get-Content -LiteralPath (Join-Path $RepoRoot 'config/repo.json') -Raw | ConvertFrom-Json -Depth 20)
$key      = $config.trailer.key
$allowed  = @($config.trailer.allowed)

if ([string]::IsNullOrWhiteSpace($GrandfatherPath)) {
    # .continuity/, not config/, as in claude.agent.substrate. The exemption list belongs beside
    # forensic.jsonl here: it exists because several of the hashes it names are cited by that
    # chain and therefore cannot be rewritten. config/ in this repository is build configuration.
    $GrandfatherPath = Join-Path $RepoRoot '.continuity/trailer-grandfather.txt'
}

# A `#` comment and blank lines are tolerated so the file can say what the hashes are without
# the parser caring. Everything before the first `#` on a line is the datum.
$grandfathered = @()
if (Test-Path -LiteralPath $GrandfatherPath) {
    $grandfathered = @(Get-Content -LiteralPath $GrandfatherPath |
                       ForEach-Object { ($_ -split '#')[0].Trim() } |
                       Where-Object { $_ -ne '' })
}
else {
    Write-Host "trailer-guard: WARNING -- no grandfather file at $GrandfatherPath; the exemption list is EMPTY, not permissive"
}

Push-Location $RepoRoot
try {
    $range = if ([string]::IsNullOrWhiteSpace($Base)) { $Head } else { "$Base..$Head" }
    Write-Host "trailer-guard: range $range, key '$key', allowed [$($allowed -join ', ')]"
    Write-Host ("trailer-guard: merge commits are {0}" -f $(if ($IncludeMerges) { 'INCLUDED (-IncludeMerges)' } else { 'excluded (see .DESCRIPTION)' }))
    Write-Host ("trailer-guard: grandfathered {0} commit(s) from {1}" -f
        $grandfathered.Count, [System.IO.Path]::GetRelativePath($RepoRoot, $GrandfatherPath).Replace('\', '/'))

    # Not $args: that is an automatic variable, and splatting it is a trap waiting to be sprung.
    $logArgs = @('log', '--format=%H', $range)
    if (-not $IncludeMerges) { $logArgs += '--no-merges' }
    $shas = @(& git @logArgs)

    if ($shas.Count -eq 0) {
        Write-Host 'trailer-guard: PASS -- no commits in range'
        exit 0
    }

    $bad   = [System.Collections.Generic.List[string]]::new()
    $usedG = [System.Collections.Generic.List[string]]::new()
    foreach ($sha in $shas) {
        $value   = (& git log -1 --format="%(trailers:key=$key,valueonly)" $sha | Out-String).Trim()
        $subject = (& git log -1 --format='%s' $sha | Out-String).Trim()
        $short   = $sha.Substring(0, 8)

        if ([string]::IsNullOrWhiteSpace($value)) {
            # Exact, full-hash membership. $sha is always 40 chars from --format=%H, so a
            # shortened entry simply never matches rather than matching a prefix by accident.
            if ($grandfathered -ccontains $sha) {
                Write-Host "  GRAND $short  no '${key}:' trailer, exempted by exact hash  -- $subject"
                $usedG.Add($sha); continue
            }
            Write-Host "  MISS  $short  no '${key}:' trailer  -- $subject"
            $bad.Add($sha); continue
        }
        if ($allowed -notcontains $value) {
            Write-Host "  BAD   $short  ${key}: '$value' is not in the allowed vocabulary  -- $subject"
            $bad.Add($sha); continue
        }

        $body = (& git log -1 --format='%B' $sha | Out-String)

        # NO Co-Authored-By. AGENTS.md forbids it and the `who:` trailer is what replaces it.
        # This guard existed on the develop lineage as its own CI step; porting substrate's CI
        # wholesale would have dropped it, so it is folded in here rather than lost. It is a
        # trailer rule, it belongs in the trailer check, and it needs no seventh required check.
        #
        # Anchored to line start: an unanchored match also hits commit messages that merely
        # DISCUSS the rule, which is how the original guard first failed - on the commit that
        # added it.
        #
        # Grandfathered commits never reach this line, and that is deliberate: on the lineage
        # this came from, eight run-01 commits carried Co-Authored-By and could not be repaired
        # without rewriting pushed history that the forensic chain cites, so all eight sat in
        # the exemption list. None of those commits are in this repository and the list here is
        # empty, so today every commit in range reaches this check. The ordering is kept anyway:
        # it is what makes an exemption survivable if one is ever needed again.
        if ($body -match '(?im)^co-authored-by:') {
            Write-Host "  COAUTH $short  carries a Co-Authored-By trailer, which AGENTS.md forbids  -- $subject"
            $bad.Add($sha); continue
        }

        # Advisory, not a gate: the trailer is supposed to be the LAST line. Reported so drift
        # is visible, but not failed on - the gate is presence and vocabulary, per the spec.
        $lastLine = (($body -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
        $note     = if ($lastLine -match "^\s*$key\s*:") { '' } else { "  [note: '${key}:' is not the last line]" }
        Write-Host "  OK    $short  ${key}: $value$note  -- $subject"
    }

    Write-Host "trailer-guard: $($shas.Count) commit(s) checked, $($usedG.Count) grandfathered, $($bad.Count) non-compliant"

    # An exemption listed but not needed in this range is not an error - a PR range legitimately
    # does not contain the seed. It is reported so that a list which has stopped meaning anything
    # is visible rather than inherited forever.
    $unused = @($grandfathered | Where-Object { $usedG -cnotcontains $_ })
    foreach ($u in $unused) {
        $show = if ($u.Length -ge 8) { $u.Substring(0, 8) } else { $u }
        Write-Host "  note: grandfather entry $show was not needed in this range"
    }

    if ($bad.Count -gt 0) {
        Write-Host 'trailer-guard: FAIL'
        exit 1
    }
    Write-Host 'trailer-guard: PASS'
    exit 0
}
finally { Pop-Location }
