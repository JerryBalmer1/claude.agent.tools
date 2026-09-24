# claude.agent.tools

Commands that observe a repository and return verdicts. Each verdict is a typed PowerShell
object, not a printed line.

- `src/Inspect-Repo.ps1` observes a target repository and emits one verdict per finding.
- `tests/Test-AgentsClaims.ps1` measures every claim in [AGENTS.md](AGENTS.md) against this tree.
- `corpus/` holds frozen inspector output, each file named for the repository and commit it
  observed.

## Run

```powershell
Invoke-Build Full
pwsh -NoProfile -File tests/run.ps1
pwsh -NoProfile -File src/Inspect-Repo.ps1 -Path ..\claude.agent.images
```

PowerShell 7.4+. Clone with `--recurse-submodules`: `vendor/claude.agent.core` supplies the
policy and ledger modules.

Rendering, the fuzzer, chaos mode and the query surface are out of scope for now.
