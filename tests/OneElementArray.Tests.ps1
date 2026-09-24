#Requires -Version 7.4

<#
    Ported from claude.agent.images@249752d:tests/Sentinel.Tests.ps1 (blob 0106bea5), the
    Describe block 'One-element JSON array: one trap, met two ways' at lines 237-274. The It body
    is unchanged. The BeforeAll carries only what that block reads from the original file's
    BeforeAll: the repository root, the sentinel's path and the ledger manifest path. The rest
    of Sentinel.Tests.ps1 tests the leash sentinel's receipts and is not ported.

    Both scripts under test were carried into this repository in PR 0: hooks/sentinel.ps1
    adapted (decision logic unchanged) and .claude/hooks/Deny-Heredoc.ps1 byte-identical.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    $script:RepoRoot = Get-RepoRoot
    $script:Sentinel = Join-Path $script:RepoRoot 'hooks' 'sentinel.ps1'
    $script:LedgerModule = Get-LedgerManifestPath
}

Describe 'One-element JSON array: one trap, met two ways' {
    # A RECURRENCE, recorded as one in images (forensic chain seq 19 there). A PowerShell
    # pipeline unrolls a one-element JSON array into its element, so `[{...}]` arrives as a
    # perfectly good object. hooks/sentinel.ps1 defends with a raw-text StartsWith('{') check
    # before its bare ConvertFrom-Json. .claude/hooks/Deny-Heredoc.ps1 defends with
    # -NoEnumerate.
    #
    # Two defences, not one fix twice, and the intended verdicts are OPPOSITE on purpose: the
    # sentinel gates an agent that may be adversarial and fails CLOSED; Deny-Heredoc guards
    # the hands of one that is trying to comply and fails OPEN. This asserts each script's
    # own verdict, so removing either defence turns it red.
    It 'the sentinel fails closed and Deny-Heredoc fails open on [{...}], and the control is denied' {
        $inner = @{
            session_id      = 'one-element-array'
            hook_event_name = 'PreToolUse'
            tool_name       = 'Bash'
            tool_input      = @{ command = "cat <<EOF`nx`nEOF" }
        } | ConvertTo-Json -Compress -Depth 5
        $array = "[$inner]"
        $denyHeredoc = Join-Path $script:RepoRoot '.claude' 'hooks' 'Deny-Heredoc.ps1'

        $s = Invoke-LeashScript -Path $script:Sentinel -Arguments @('-Mode', 'Enforce') -Stdin $array -Environment @{
            LEASH_LEDGER_PATH   = (Join-Path ([System.IO.Path]::GetTempPath()) 'never-written' 'ledger.jsonl')
            LEASH_LEDGER_MODULE = $script:LedgerModule
            LEDGER_PRINCIPAL    = 'one-element-array'
        }
        $s.ExitCode | Should -Be 2 -Because 'the sentinel fails closed on anything that is not a JSON object'
        $s.StdOut | Should -BeExactly ''
        $s.StdErr | Should -Match 'payload is not a JSON object'

        $h = Invoke-LeashScript -Path $denyHeredoc -Stdin $array
        $h.ExitCode | Should -Be 0
        $h.StdOut | Should -BeExactly '' -Because 'Deny-Heredoc fails open on a payload that is not an object'

        # The control. Without it the line above passes against a script that allows
        # everything: the same object, unwrapped, must be denied.
        $c = Invoke-LeashScript -Path $denyHeredoc -Stdin $inner
        $c.ExitCode | Should -Be 0
        (ConvertFrom-JsonSafe -Text $c.StdOut).hookSpecificOutput.permissionDecision | Should -BeExactly 'deny'
    }
}
