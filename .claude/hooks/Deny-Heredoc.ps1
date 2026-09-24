#Requires -Version 7.4
<#
.SYNOPSIS
    PreToolUse guard: refuse any Bash tool call carrying a heredoc or herestring.

.DESCRIPTION
    WHY THIS EXISTS. AGENTS.md makes PowerShell 7.4+ law and the pull-request template
    carries "No bash, no heredocs, no `cat >`" as a wall item. Two packets running, the
    agent typed a heredoc anyway, and both times the only thing that caught it was a
    PowerShell PARSE ERROR - luck, not a control. Both were disclosed rather than hidden,
    which is the honour system working exactly as well as an honour system ever does.
    This replaces it with something that cannot forget.

    THE CONTRACT. Claude Code sends the hook payload as JSON on stdin: tool_name,
    tool_input, and session fields this script ignores. A PreToolUse hook denies by
    printing hookSpecificOutput.permissionDecision = deny with a reason, and EXITING 0.

    Exit 0 with a decision body, not exit 2, and that is not a style choice. This
    repository already learned it the hard way in the leash: hooks/sentinel.ps1 emitted a
    deny body and then exited 2, so the body was discarded every time and the reason never
    reached anyone. END_GOAL.md records the repair. The same shape is used here, for the
    same reason - a refusal nobody can read is a refusal that teaches nothing.

    FAIL OPEN, DELIBERATELY. If stdin is empty, unparseable, or carries no command, this
    allows. A guard against a typing reflex is not a security boundary: the leash sentinel
    is the thing that fails closed, because it gates an agent that may be adversarial. This
    gates the hands of an agent that is trying to comply and keeps slipping. Failing closed
    here would block every Bash call the moment the payload shape changed, which is a worse
    failure than the one it prevents.

    BLUNT ON PURPOSE. It matches the operator ANYWHERE in the command, so it also refuses a
    command that merely mentions one - grepping for the string, say. That is accepted: the
    rule in this repository is not "no heredocs", it is "no bash", and the PowerShell tool
    is the escape from every false positive this can produce.

    ARMING, AND THE LIMIT MEASURED ON THE DAY THIS LANDED. Claude Code snapshots hooks at
    session start, and its settings watcher only watches directories that already held a
    settings file when the session began. This repository had no .claude/ at all until this
    commit, so the hook could not arm in the session that wrote it: a heredoc pushed through
    the Bash tool minutes after this file was written ran normally and printed its output.
    That is a timing property, not a flaw in the shape - the script itself was driven both
    ways by piping payloads straight into it. After this lands, open /hooks once or start a
    new session and it is live from then on.

.EXAMPLE
    pwsh -NoProfile -File .claude/hooks/Deny-Heredoc.ps1
    Reads the hook payload on stdin. Prints nothing and exits 0 when the command is clean.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# The whole payload, not a line of it: a command can be multi-line and the operator may
# appear on any of them.
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

# -NoEnumerate IS LOAD-BEARING and was put here by a failing test, not by reading the docs.
# Without it ConvertFrom-Json unrolls a JSON array, so `[{"tool_input":{...}}]` arrives as a
# single PSCustomObject and sails straight through the type check below. Measured: the first
# version of this script DENIED that payload while its own comment claimed it failed open.
# END_GOAL.md records the identical trap in hooks/sentinel.ps1, where a one-element array was
# accepted as a valid payload and behaviour depended on the LENGTH of the thing being
# rejected. Same trap, same repository, twice.
try { $payload = ConvertFrom-Json -InputObject $raw -NoEnumerate -ErrorAction Stop }
catch { exit 0 }

if ($payload -isnot [pscustomobject]) { exit 0 }
if ($payload.PSObject.Properties.Name -notcontains 'tool_input') { exit 0 }

$toolInput = $payload.tool_input
if ($null -eq $toolInput -or $toolInput -isnot [pscustomobject]) { exit 0 }
if ($toolInput.PSObject.Properties.Name -notcontains 'command') { exit 0 }

$command = [string]$toolInput.command
if ([string]::IsNullOrEmpty($command)) { exit 0 }

# `<<` covers the heredoc and, as a prefix, the `<<<` herestring. Both are bash.
if (-not $command.Contains('<<')) { exit 0 }

$decision = [ordered]@{
    hookSpecificOutput = [ordered]@{
        hookEventName            = 'PreToolUse'
        permissionDecision       = 'deny'
        permissionDecisionReason = 'PowerShell only - see AGENTS.md. This command carries a heredoc or herestring (<<). Use the PowerShell tool: Set-Content or [System.IO.File]::WriteAllText for file writes, and git commit -F <file> for commit messages.'
    }
}

$decision | ConvertTo-Json -Depth 5 -Compress
exit 0
