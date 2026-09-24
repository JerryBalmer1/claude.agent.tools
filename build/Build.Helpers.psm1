#Requires -Version 7.4

<#
.SYNOPSIS
    Shared helpers for the claude.agent.images build surface.

.DESCRIPTION
    Task bodies in build/tasks/*.build.ps1 orchestrate and render. The work
    lives here so it can be unit-tested on the host without Invoke-Build.

    Canonical JSON is the load-bearing piece: run-01's preflight gate hashes
    prompts/assessment.2026-09-21.json and refuses to proceed on a mismatch.
    "Canonical" means recursively key-sorted (ordinal) and whitespace-free, so
    the hash is a property of the *values*, not of how someone formatted them.
    This must agree byte-for-byte with Python's
    json.dumps(obj, sort_keys=True, separators=(',', ':')).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function ConvertTo-CanonicalObject {
    <#
    .SYNOPSIS
        Rebuild an object graph with every mapping's keys in ordinal order.

    .DESCRIPTION
        Ordinal, not culture-aware: Sort-Object would order keys by the current
        culture's collation, which is a different order on a different machine.
        A canonicalizer that depends on the locale is not a canonicalizer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return $null }

    # Strings are IEnumerable; check before the sequence branch or they become char arrays.
    if ($Value -is [string] -or $Value -is [bool] -or $Value.GetType().IsPrimitive -or
        $Value -is [decimal] -or $Value -is [datetime]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $sorted = [ordered]@{}
        foreach ($k in $keys) { $sorted[$k] = ConvertTo-CanonicalObject -Value $Value[$k] }
        return $sorted
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $keys = [string[]]@($Value.PSObject.Properties.Name)
        [Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $sorted = [ordered]@{}
        foreach ($k in $keys) { $sorted[$k] = ConvertTo-CanonicalObject -Value $Value.$k }
        return $sorted
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        # Unary comma: a one-element result must stay an array through the return.
        $items = @(foreach ($item in $Value) { , (ConvertTo-CanonicalObject -Value $item) })
        return , $items
    }

    return $Value
}

function ConvertTo-CanonicalJson {
    <#
    .SYNOPSIS
        The exact bytes that get hashed. Key-sorted, compressed, no BOM.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        $InputObject
    )

    $canonical = ConvertTo-CanonicalObject -Value $InputObject
    return (ConvertTo-Json -InputObject $canonical -Compress -Depth 100)
}

function Get-StringSha256 {
    <#
    .SYNOPSIS
        Lowercase hex sha256 over a string's UTF-8 bytes.

    .DESCRIPTION
        Same convention as Ledger's Get-LedgerSha256Hex and Python's
        hashlib.sha256(s.encode('utf-8')).hexdigest().
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-CanonicalJsonSha256 {
    <#
    .SYNOPSIS
        Canonical sha256 of a JSON document on disk.

    .EXAMPLE
        Get-CanonicalJsonSha256 -Path ./prompts/assessment.2026-09-21.json
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Canonical hash requested for a file that does not exist: $Path"
    }

    Write-Verbose "[helpers] canonicalizing $Path"
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $obj = $raw | ConvertFrom-Json -Depth 100
    $canonical = ConvertTo-CanonicalJson -InputObject $obj
    Write-Debug "[helpers] canonical bytes: $canonical"
    return (Get-StringSha256 -Text $canonical)
}

function Test-AssessmentHash {
    <#
    .SYNOPSIS
        run-01 preflight gate. Throws on mismatch; returns the hash on success.

    .DESCRIPTION
        The gate exists because the run order carries the assessment inline and
        the repo carries it on disk. If those two ever disagree, every later
        step is being taken against a document nobody agreed to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [ValidatePattern('^[0-9a-f]{64}$')]
        [string]$ExpectedSha256
    )

    $actual = Get-CanonicalJsonSha256 -Path $Path
    if ($actual -ne $ExpectedSha256) {
        throw ("Assessment hash mismatch for {0}`n  expected: {1}`n  actual:   {2}" -f $Path, $ExpectedSha256, $actual)
    }
    Write-Verbose "[helpers] assessment hash verified: $actual"
    return $actual
}

function Get-SkipJustification {
    <#
    .SYNOPSIS
        The stated reason a skipped test is allowed to be skipped, or $null for none.

    .DESCRIPTION
        Two forms, and both are read off the TEST OBJECT — its own tags, plus every
        parent block's — never out of a comment sitting beside the test. A comment is
        not a measurement: nothing reads it, so nothing goes red when it stops being
        true, which is the honour system this gate exists to replace.

            BLOCKER-n                 a skip waiting on a numbered blocker.
            SkipWhen:<kebab-reason>   a precondition that is legitimately unmet today.

        The second form exists because BLOCKER-n is the wrong token for the trailer
        falsification tests. Blockers are being retired, and "no exempt commit in range"
        is not a blocker — it is a state this repository is simply in on most days, and
        will drop back into whenever a grandfathered commit enters the range again. A
        blocker gets fixed and struck; this does not.

        It returns the REASON rather than a boolean so a gate can report WHY a test did
        not run, not merely that it did not. For BLOCKER-n the reason is the token
        itself; for SkipWhen it is the text after the colon, pulled from the pattern's
        own named group so the pattern and the extraction cannot drift apart.

        THE HOME FOR THIS IS DELIBERATE. build/tasks/Test.build.ps1 (host) and
        build/InContainer.Test.ps1 (container) are two independent implementations of
        the same gate, and they already differ on NotRun. Writing this rule a third and
        fourth time would guarantee they eventually disagree about what a justification
        even is. The container reaches this module at /work/build, which is bind-mounted;
        nothing here depends on Invoke-Build.

    .EXAMPLE
        Get-SkipJustification -Tag @('SkipWhen:no-exempt-commit-in-range')
        no-exempt-commit-in-range
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Tag,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$BlockerPattern = '^BLOCKER-\d+$',

        # The 'reason' group is load-bearing: it is the string the gates print. A
        # replacement pattern that omits it falls back to the whole tag rather than
        # reporting an empty reason, which would read as a justification that justifies
        # nothing.
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SkipWhenPattern = '^SkipWhen:(?<reason>[a-z0-9]+(-[a-z0-9]+)*)$'
    )

    $tags = @($Tag | Where-Object { $_ })

    # Blockers first: if a test carries both, the blocker is the more serious claim and
    # is the one worth surfacing.
    foreach ($t in $tags) {
        if ($t -cmatch $BlockerPattern) { return $t }
    }

    foreach ($t in $tags) {
        $m = [regex]::Match($t, $SkipWhenPattern)
        if ($m.Success) {
            $reason = $m.Groups['reason'].Value
            if ($reason) { return $reason }
            return $t
        }
    }

    return $null
}

function Assert-SuiteClean {
    <#
    .SYNOPSIS
        Fail on any failed test, and on any skip that does not state its reason
        on the test object. Report the skips that do.

    .DESCRIPTION
        IT LIVES HERE SO MORE THAN ONE CALLER CAN REACH IT. It used to be a function
        inside build/tasks/Test.build.ps1, where it called Write-Build - an Invoke-Build
        command - so no plain pwsh script could call it. scripts/ci/Invoke-Tests.ps1, the
        `pester` required check, therefore had no skip gate at all: it exited 1 only on a
        failed test or an empty suite, and an unjustified skip went green in CI while the
        same tree failed Invoke-Build Test.Unit. A required check that passes what the
        build fails is not a floor.

        Nothing in this module depends on Invoke-Build, which is the same property that
        lets the container import it off the /work bind mount. Write-Host, not Write-Build,
        for exactly that reason.

    .PARAMETER ExcludeTag
        The tag filter THIS RUN CARRIED, or nothing if it carried none.

        Pester reports a test excluded by -ExcludeTag as NotRun, which is not a skip: it
        was never part of the run. Passing the filter in is what lets one implementation
        serve a run that excludes tags and a run that does not, instead of two that differ
        by accident - which is how the host and container gates came to disagree on NotRun
        in the first place. build/InContainer.Test.ps1 applies the same rule inline.

        Test.Unit passes nothing here because it excludes nothing, so every NotRun it sees
        really is unexplained and stays unjustified. Inconclusive gets no tag escape in
        either case: it means an assertion gave up part-way through, which is not a
        precondition anyone declared in advance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Where,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ExcludeTag
    )

    $excluded = @($ExcludeTag | Where-Object { $_ })

    if ($Result.FailedCount -gt 0) {
        $names = @($Result.Tests | Where-Object Result -eq 'Failed' | ForEach-Object { $_.ExpandedPath })
        # ${Where} and not $Where: a colon straight after a variable name makes
        # PowerShell read it as a scope qualifier, the way $script: does, and
        # the file will not even parse.
        throw ("${Where}: $($Result.FailedCount) test(s) failed:`n  " + ($names -join "`n  "))
    }

    # The RULE for what counts as a justification is Get-SkipJustification, above. What
    # counts as needing one is decided here.
    $verdicts = @(
        $Result.Tests | ForEach-Object {
            if ($_.Result -notin @('Skipped', 'Inconclusive', 'NotRun')) { return }

            $tags = @($_.Tag)
            $block = $_.Block
            while ($block) { $tags += @($block.Tag); $block = $block.Parent }
            $tags = @($tags | Where-Object { $_ })

            # A test the filter excluded did not skip. It belongs in neither list.
            if ($_.Result -eq 'NotRun' -and @($tags | Where-Object { $excluded -contains $_ }).Count -gt 0) { return }

            $reason = if ($_.Result -eq 'Skipped') { Get-SkipJustification -Tag $tags } else { $null }

            [pscustomobject]@{
                Test   = $_.ExpandedPath
                Result = [string]$_.Result
                Reason = $reason
            }
        }
    )

    $unjustified = @($verdicts | Where-Object { -not $_.Reason })
    $justified   = @($verdicts | Where-Object { $_.Reason })

    # WHY, not just how many. A green log that says "skipped: 2" tells a reader
    # nothing they can act on; grouped by reason, it tells them what precondition
    # was unmet and therefore what would have to change for those tests to run.
    foreach ($group in ($justified | Group-Object -Property Reason | Sort-Object -Property Name)) {
        Write-Host ("${Where}: skipped - $($group.Name):") -ForegroundColor Yellow
        foreach ($t in $group.Group) { Write-Host "    $($t.Test)" -ForegroundColor DarkGray }
    }

    if ($unjustified.Count -gt 0) {
        throw ("${Where}: no justification tag (BLOCKER-n or SkipWhen:<reason>) on:`n  " +
            (@($unjustified | ForEach-Object { "$($_.Result.ToLowerInvariant()) - $($_.Test)" }) -join "`n  "))
    }

    if ($Result.PassedCount -eq 0) {
        throw "${Where}: no tests ran; that is a failure, not a pass"
    }
}

Export-ModuleMember -Function 'ConvertTo-CanonicalObject', 'ConvertTo-CanonicalJson',
    'Get-StringSha256', 'Get-CanonicalJsonSha256', 'Test-AssessmentHash',
    'Get-SkipJustification', 'Assert-SuiteClean'
