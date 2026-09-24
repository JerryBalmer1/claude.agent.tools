# AGENTS.md

`claude.agent.tools` is **commands**: deterministic scripts that observe a repository and emit
verdicts. It absorbs `claude.build.inspector` and `claude.build.fuzzer`. Conventions are carried
from `claude.agent.images` at `249752d`, not from substrate.

## Claims

Each row is a claim about this tree that a test measures. `tests/Test-AgentsClaims.ps1` holds one
Pester `It` per row, keyed by the id in the first column, and a claim with no `It` fails that
file. A row that cannot be measured does not belong in this table.

| id | Claim | Measured as |
|---|---|---|
| `commands-not-library` | Tools ships commands, not a library. | Every file under `src/` is a `.ps1` with a `[CmdletBinding()]` param block. No `.psm1` or `.psd1` under `src/`, and no `Export-ModuleMember` in it. |
| `verdicts-not-receipts` | Tools emits verdicts, not receipts. | Nothing under `src/` imports the ledger module, calls `Add-LedgerRecord`, or names `forensic.jsonl`. Receipts are core's; a verdict is an observation. |
| `no-python` | No Python. | No tracked `*.py` outside `vendor/`, and no tracked `.ps1`, `.psm1` or `.yml` outside `vendor/` invokes `python`, `python3` or `py`. |
| `no-dockerfile` | No Dockerfile. | No tracked `Dockerfile*`, `*.dockerfile`, `.dockerignore` or compose file outside `vendor/`. Images is the only repository that builds images. |
| `typed-verdicts` | Every verdict is a typed object with a result field, never a printed line. | Every `[pscustomobject]` literal under `src/` carries a `PSTypeName` beginning `claude.agent.tools.` and a `Verdict` key. No `Write-Host`, `Out-Host` or `Format-*` call under `src/`. |
| `temp-root` | Every suite resolves its temp root from `[System.IO.Path]::GetTempPath()`. | No file under `tests/` reads `$env:TEMP`, `$env:TMP` or `$env:TMPDIR`. |

## Branches

`feature/*` -> `develop` -> `main`, merge commits only, one feature per branch per pull request.
No direct push to `develop` or `main`. No force-push, no amend of anything pushed.
`config/repo.json` is the source of truth for the flow, the required checks and `review.mode`;
`docs/POLICY.md` is rendered from it.

## Commits

Every commit ends with a `who:` trailer as its last line: `claude`, `grok`, `fable` or `jerry`.
No `Co-Authored-By` trailer, on any commit. `trailer-guard` checks both.

## Runtime

PowerShell 7.4+ only. `#Requires -Version 7.4` on line 1 of every `.ps1` and `.psm1`. No bash, no
heredocs, no Python, including in CI. Run scripts with `pwsh -NoProfile -File <repo-relative path>`.
`Invoke-Build` is the build entry point.

## Vendor

`vendor/claude.agent.core` is a submodule, pinned. Nothing under `vendor/` is edited here.
`-Policy` resolves against core's `modules/policy`, and it isn't reimplemented here.

## Records

`.continuity/forensic.jsonl` is the forensic chain, append-only through `scripts/forensic.ps1`.
Verify with `pwsh -NoProfile -File scripts/forensic.ps1 -Verify`.

## State

Never transcribe repository state. Run `pwsh -NoProfile -File scripts/state.ps1`, last, at the
end of every packet, and park on `develop` clean.
