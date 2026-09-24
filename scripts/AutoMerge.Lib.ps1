#Requires -Version 7.4
#
# COPIED, NOT VENDORED.
#   origin repo   : claude.agent.substrate
#   origin file   : scripts/AutoMerge.Lib.ps1
#   origin commit : 912c1c9eb48ab0b639d257bc7b10661d7212f985
#   origin sha256 : 0e3564d420aa5a53975ba0db047108e1ef173381209cc63dbb91312aebb9ce6d
#   adapted here  : no - byte-identical at copy time
#
# There is no submodule here and substrate does not follow this copy. If substrate's
# version moves, this one does not move with it. Diff the two against the origin commit
# above before assuming they still agree.
#
<#
.SYNOPSIS
    The review-mode gate, factored out of Invoke-AutoMerge.ps1 so it can be tested.

.DESCRIPTION
    Dot-sourced by scripts/Invoke-AutoMerge.ps1 and by tests/AutoMerge.Tests.ps1.

    THIS FILE HAS NO TOP-LEVEL SIDE EFFECTS ON PURPOSE. Dot-sourcing it defines functions and
    does nothing else: it sets no preference variables, reads no config, and runs no command.
    A library that reconfigures its caller cannot be dot-sourced into a test without the test
    measuring the library's opinions instead of the repository's.

    WHY THE GATE IS A LIBRARY AND NOT AN INLINE BLOCK

    The gate is the single decision that authorises an unattended merge. While it lived inline
    in a script that starts by calling `gh pr view`, the only way to exercise it was to open a
    real pull request against a real repository and watch what happened. That is a proof that
    costs a merge, which means in practice it is a proof nobody runs. Here it is three functions
    over plain data, and tests/AutoMerge.Tests.ps1 drives them with a `gh` that answers from a
    table -- so "a pull request cannot authorise its own merge" is a claim that gets re-checked
    on every CI run, for free, without merging anything.

    `gh` is invoked as a bare command name rather than through a path or an injected callable.
    That is what lets a test shadow it with a function of the same name, and it is also the
    reason there is no -Fetcher parameter here: a seam that exists only for the test is a seam
    the production path never uses, and a test that drives a code path nobody ships proves
    nothing about the thing that ships.

.EXAMPLE
    . ./scripts/AutoMerge.Lib.ps1
    $pr = gh pr view 12 --repo owner/name --json baseRefName,headRefOid | ConvertFrom-Json
    Test-ReviewModeAuto -Repo owner/name -PullRequest $pr
#>

function Get-RepoConfigAtRef {
    <#
    .SYNOPSIS
        Reads config/repo.json out of the repository at an arbitrary git ref.

    .DESCRIPTION
        The ref may be a branch name or a commit sha. A branch name reads whatever that branch
        points at right now, which is the behaviour the review gate wants: flipping review.mode
        on develop takes effect on the next automerge run for every open pull request, without
        anyone having to rebase or repush a branch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Repo,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Ref
    )

    # A MISSING CONFIG ON THE BASE IS "STAND DOWN", NOT A CRASH.
    #
    # Reading the config from the base branch has a chicken-and-egg case that showed up on the
    # very first pull request to use it: the PR that INTRODUCES config/repo.json is, by
    # definition, opened against a base that does not have it yet. The API answers 404, and
    # with $PSNativeCommandUseErrorActionPreference the bare call threw a
    # NativeCommandExitException and failed the whole automerge run.
    #
    # That contradicts this script's own contract - "exits 0 in every 'not yet' case, because a
    # PR that is not ready is not an error, and a red automerge on every push is noise that
    # hides a real failure". So 404 returns $null and the caller stands down loudly.
    #
    # Returning $null rather than a default config is the safe direction: no config means no
    # authorisation, so a human merges. The failure mode of the other choice is an automerge
    # that invents its own permission.
    # NOT $LASTEXITCODE. The first version of this fix read it, and it is wrong in a way that
    # only shows up under test: $LASTEXITCODE is set by NATIVE commands, and a test that shadows
    # `gh` with a FUNCTION never touches it, so the variable keeps whatever stale value it had -
    # frequently $null - and the guard then rejects perfectly good configs. Caught in
    # claude.agent.substrate, where three passing tests went red the moment it landed. In
    # production it is worse than useless: silently correct until some earlier native call
    # leaves a non-zero behind.
    #
    # The caller sets $PSNativeCommandUseErrorActionPreference = $true and preferences are
    # dynamically scoped, so a real `gh` failure throws in here and the catch takes it.
    #
    # The empty-output check is the belt to that brace: a caller with native errors turned off
    # gets nothing back instead of an exception, and "nothing" must not be decoded as a config.
    $encoded = $null
    try {
        $encoded = gh api "repos/$Repo/contents/config/repo.json?ref=$Ref" --jq '.content'
    }
    catch {
        Write-Host "automerge: config/repo.json is not readable at '$Ref': $($_.Exception.Message)"
        return $null
    }

    if ([string]::IsNullOrWhiteSpace(($encoded | Out-String))) {
        Write-Host "automerge: config/repo.json came back empty at '$Ref'"
        return $null
    }

    # The contents API returns base64 with line breaks in it; -replace '\s' before decoding.
    $json = [System.Text.Encoding]::UTF8.GetString(
        [System.Convert]::FromBase64String((($encoded | Out-String) -replace '\s', ''))
    )
    return ($json | ConvertFrom-Json -Depth 20)
}

function Get-ReviewConfigRef {
    <#
    .SYNOPSIS
        The ref the review-mode gate reads its config from.

    .DESCRIPTION
        THE PULL REQUEST HEAD IS NOT AN ACCEPTABLE ANSWER HERE, and this one-line function
        exists so that there is exactly one place where that is decided.

        Reading review.mode from the head means the contents of a pull request decide whether
        that same pull request may merge itself. A branch that flips review.mode from "human"
        to "auto" in its own diff is, under a head-reading gate, self-authorising: CI goes
        green on the branch's own config and the merge happens with no human involved. The gate
        and the thing being gated are the same object.

        Reading it from the BASE branch makes the gate a property of the target, which is what a
        gate is. The cost is real and is accepted: a change to review.mode does not take effect
        for the pull request that introduces it, only once it has merged. That is the correct
        trade -- a mode change is a policy change, and a policy change should land through the
        flow before it governs anything.

        The base is taken by NAME, not by the base sha recorded on the pull request. The name
        resolves to the branch tip at the moment the gate runs, so flipping the mode stops
        automation immediately, including for pull requests opened before the flip. A base sha
        would pin the gate to the state of the world when the PR was opened, which is a stale
        gate wearing a fresh one's clothes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $PullRequest
    )
    return [string]$PullRequest.baseRefName
}

function Test-ReviewModeAuto {
    <#
    .SYNOPSIS
        Returns the review mode that governs this pull request, and whether it permits automerge.

    .DESCRIPTION
        The WHOLE config comes back on the returned object, read once from the base ref, and the
        caller is expected to use it for required_checks and branches too. review.mode is not the
        only field a pull request could rewrite in its own favour: a branch that deleted an entry
        from required_checks would, under a head-read, be merged without the check it removed.
        One read from the base closes every variant of that at once, and costs one API call.

    .OUTPUTS
        [pscustomobject] with Ref, Mode, IsAuto and Config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Repo,
        [Parameter(Mandatory)] [ValidateNotNull()] $PullRequest
    )

    $ref    = Get-ReviewConfigRef -PullRequest $PullRequest
    $config = Get-RepoConfigAtRef -Repo $Repo -Ref $ref

    # No config on the base means no authorisation. The pull request that introduces
    # config/repo.json is the obvious case and it is not an error - a human merges that one.
    if ($null -eq $config) {
        return [pscustomobject]@{
            Ref    = $ref
            Mode   = '(no config on the base branch)'
            IsAuto = $false
            Config = $null
        }
    }

    $mode = [string]$config.review.mode

    return [pscustomobject]@{
        Ref    = $ref
        Mode   = $mode
        IsAuto = ($mode -ceq 'auto')
        Config = $config
    }
}
