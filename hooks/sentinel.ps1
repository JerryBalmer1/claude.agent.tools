#Requires -Version 7.4

<#
.SYNOPSIS
    PreToolUse sentinel. One script, one policy switch, both images.

.DESCRIPTION
    The gate Claude Code calls before every matched tool use. It speaks the
    current hook contract, which is not the one the previous version spoke:

      * A decision is carried in hookSpecificOutput.permissionDecision on
        stdout, with exit 0. The top-level "decision" key is stale and is
        ignored by current Claude Code.
      * stdout JSON is honored ONLY on exit 0. The old code emitted a deny
        body and then exited 2, so the body was discarded and the block
        depended entirely on the exit code — the reason never reached anyone.
      * exit 2 blocks the call and feeds stderr back to Claude. That is what
        this script uses for its own internal failures, so a broken sentinel
        fails CLOSED.

    All of the above is recorded as confirmed in
    prompts/assessment.2026-09-21.json.

    A hook decision can never widen permissions: a permissions.deny rule wins
    regardless of what this script says. The deny list in managed-settings.json
    is the wall; this script is the camera and the receipt.

.PARAMETER Mode
    Enforce - gated tools are denied.
    Observe - nothing is denied, receipts are still written.
    There is deliberately no second, no-op copy of this script for the
    developer image. Two files drift; one file with a switch does not.

.PARAMETER GatedTool
    Tools denied under Enforce. Must stay in step with the permissions.deny
    list in both managed-settings.json files; tests/Settings.Tests.ps1 asserts
    that it does.

.PARAMETER LedgerPath
    The receipt chain, on the host-mounted volume. Every decision — allow and
    deny alike — appends one Ledger record BEFORE this script returns. If the
    receipt cannot be written, the decision does not happen: stderr, exit 2.

.NOTES
    stdout discipline: this script writes to stdout exactly once, and only a
    JSON document. Anything else there corrupts the hook response, so no
    Write-Host, no uncaptured pipeline output. Diagnostics go to the verbose,
    debug and error streams, which Claude Code does not parse as a decision.

    Receipt field mapping. The Ledger v1 record is a fixed set of eight keys
    and adding a ninth would invalidate every hash already in the file, so a
    sentinel receipt is expressed in the existing fields rather than extending
    them:

        attempt   1                          (a hook call has no retry loop)
        validator 'sentinel'
        mode      Enforce | Observe          (the policy switch)
        model     <principal>/<tool>/<decision>
        sha256    sha256 of the raw stdin payload

    sha256 over the raw payload is the part that matters: it proves what the
    sentinel actually saw, not what it later decided to say about it.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Enforce', 'Observe')]
    [string]$Mode = $(if ($env:LEASH_MODE) { $env:LEASH_MODE } else { 'Enforce' }),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$GatedTool = @('Bash', 'Shell', 'Edit', 'Write'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LedgerPath = $(if ($env:LEASH_LEDGER_PATH) { $env:LEASH_LEDGER_PATH } else { '/ledger/ledger.jsonl' }),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LedgerModule = $(if ($env:LEASH_LEDGER_MODULE) { $env:LEASH_LEDGER_MODULE } else { '/opt/leash/ledger/Ledger.psd1' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Exit 2 is the fail-closed path: it blocks the tool call and hands stderr back
# to Claude. Every internal failure in this script lands here.
function Exit-Closed {
    param([Parameter(Mandatory)][string]$Reason)
    [Console]::Error.WriteLine("leash-sentinel: $Reason")
    [Console]::Error.Flush()
    exit 2
}

# ---------------------------------------------------------------- read stdin
$raw = $null
try {
    $raw = [Console]::In.ReadToEnd()
}
catch {
    Exit-Closed "could not read stdin: $($_.Exception.Message)"
}

if ([string]::IsNullOrWhiteSpace($raw)) {
    Exit-Closed 'empty stdin; a PreToolUse payload is required'
}

# A PreToolUse payload is a JSON OBJECT. This is checked against the raw text
# rather than the parsed result because the pipeline unrolls:
#
#     $payload = '[{"tool_name":"Bash"}]' | ConvertFrom-Json
#
# leaves $payload holding the inner object, not the array — so a one-element
# array would sail through every later check as a perfectly good payload.
# Arrays with two elements would not. A validator whose behaviour depends on
# the length of the thing it is rejecting is not a validator.
if (-not $raw.TrimStart().StartsWith('{')) {
    Exit-Closed 'payload is not a JSON object'
}

$payload = $null
try {
    $payload = $raw | ConvertFrom-Json -Depth 100
}
catch {
    Exit-Closed "stdin is not valid JSON: $($_.Exception.Message)"
}

# A payload with no tool_name is malformed, not "a tool called unknown". The
# previous version invented the string 'unknown' and carried on, which turned a
# broken contract into a silent allow.
$tool = $null
if ($payload -is [pscustomobject] -and $payload.PSObject.Properties.Name -contains 'tool_name') {
    $tool = [string]$payload.tool_name
}
if ([string]::IsNullOrWhiteSpace($tool)) {
    Exit-Closed 'payload has no tool_name'
}

$principal = if ($env:LEDGER_PRINCIPAL) { $env:LEDGER_PRINCIPAL } else { 'unset' }
Write-Verbose "[sentinel] mode=$Mode tool=$tool principal=$principal"

# ----------------------------------------------------------------- decide
$isGated = $GatedTool -contains $tool
$decision = if ($Mode -eq 'Observe') { 'observe' } elseif ($isGated) { 'deny' } else { 'allow' }
Write-Debug "[sentinel] gated=$isGated decision=$decision"

# ---------------------------------------------------------------- receipt
# Written BEFORE the decision is returned. A decision nobody can prove was made
# is not a decision, it is a claim.
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $payloadSha = [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()

    $ledgerDir = [System.IO.Path]::GetDirectoryName($LedgerPath)
    if ($ledgerDir -and -not (Test-Path -LiteralPath $ledgerDir)) {
        Exit-Closed "ledger directory is not mounted: $ledgerDir"
    }

    Import-Module -Name $LedgerModule -Force -ErrorAction Stop

    # Add-LedgerRecord is part of the module's public surface at the vendored
    # pin: FunctionsToExport in ledger.psd1:9 and Export-ModuleMember at
    # ledger.psm1:1121-1122. It is therefore called plainly.
    #
    # Until 2026-09-23 these five lines were a scriptblock invoked with
    # `& $module { ... }`, reaching the function through the module's own
    # session state because the manifest did not export it. That workaround is
    # gone rather than left in place: it would keep working unchanged if the
    # export were ever withdrawn, which is exactly the failure worth being told
    # about. Called as an export, a withdrawal is loud here and in
    # tests/Sentinel.Tests.ps1 instead of silently passing through a private name.
    $receipt = Add-LedgerRecord -Path $LedgerPath -Attempt 1 -Validator 'sentinel' `
        -Mode $Mode -Model "$principal/$tool/$decision" -Sha256 $payloadSha

    Write-Verbose "[sentinel] receipt line $($receipt.Line) self=$($receipt.Self)"
}
catch {
    Exit-Closed "ledger write failed: $($_.Exception.Message)"
}

# ----------------------------------------------------------------- respond
# Exactly one write to stdout, and only JSON.
if ($decision -eq 'deny') {
    $reason = "Leash: $tool is denied by managed policy. " +
              "Receipt $($receipt.Self) appended to $LedgerPath. Principal=$principal."
    $body = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName          = 'PreToolUse'
            permissionDecision     = 'deny'
            permissionDecisionReason = $reason
        }
    }
    [Console]::Out.Write((ConvertTo-Json -InputObject $body -Compress -Depth 5))
}
else {
    # No opinion. Normal permission handling applies, and the receipt is
    # already on disk either way.
    [Console]::Out.Write('{}')
}
[Console]::Out.Flush()

exit 0
