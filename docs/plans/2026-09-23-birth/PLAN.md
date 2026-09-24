# T0 - claude.agent.tools birth

Branch: feature/scaffold, then feature/baseline, then feature/inspector, then develop -> main
Status: in progress
Pattern source: claude.agent.images@249752d. Vendor: claude.agent.core@a68664e.

## Packet

Conventions as images: PowerShell 7.4+, no bash, no heredocs, no Python, `who:` trailer, no
`Co-Authored-By`, merge commits only, `feature/*` -> `develop` -> `main`, `review.mode: auto`,
park on `develop` clean, `scripts/state.ps1` last.

- **PR 0, `feature/scaffold` -> `develop`.** Orphan birth commit holding only `AGENTS.md`,
  `README.md` and `.gitignore`. `AGENTS.md` states the role as measurable claims. Copy from
  images byte-identical, then adapt: `build/Build.Helpers.psm1` (`Assert-SuiteClean`,
  `Get-SkipJustification`, the `SkipWhen:` gate), `.continuity/trailer-grandfather.txt`,
  `scripts/state.ps1`, `ci.yml` with `submodules: recursive` and the six checks,
  `.claude/settings.json`, `.claude/hooks/Deny-Heredoc.ps1`, `hooks/sentinel.ps1`,
  `config/repo.json` and its schema, and `tests/run.ps1` without the directory-name guard. Core
  as a submodule at `a68664e`. The genesis forensic entry cites the old plan's commit.
  *Postcondition:* `Full` exits 0 from clean with zero tests, the gate reports 0/0/0/0, six
  checks green, automerge landed.
- **PR 1, `feature/baseline` -> `develop`.** Pester scaffold, the one-element-array test, a test
  that fails if any test file reads `$env:TEMP`, and `tests/Test-AgentsClaims.ps1` with one `It`
  per `AGENTS.md` claim. *Postcondition:* green, and every claim goes red when broken, proved by
  one scratch commit and its revert.
- **PR 2, `feature/inspector` -> `develop`.** `src/Inspect-Repo.ps1` with `-Path`, `-Policy` and
  `-Halt`, emitting one typed verdict per finding (Id, Rule, Path, Line, Verdict, Evidence). Rules:
  stale repo names, dead vendor paths, cited files that don't exist, directory-name guards, and
  unprotected branches read from the API. Output against images@249752d frozen as
  `corpus/images-249752d.jsonl`. *Postcondition:* every measurable item in the I10 "what's left"
  list is found; each miss is listed with the reason.
- **PR 3, `develop` -> `main`.** Clauses re-measured. Promotion record, hyphenated subject.

Out of scope: fuzzer, chaos mode, query surface, `Docs.Render`, touching core or images.

## Progress

- 2026-09-23 - birth `6dacb34` pushed to `develop` (first, so it is the default branch) and
  `main`. Copy commit `d88c816`: 25 files byte-identical to images@249752d. Core submodule
  `76ba0b8`. Forensic genesis seq 1.
- 2026-09-23 - PR 0 #1 merged `a3d36b6`, six checks green (run 35946658179). Automerge stood
  down as predicted (no config on the base), so claude merged it with `gh pr merge --merge`.
  A fresh recursive clone of `develop` ran `Invoke-Build Full`: exit 0, gate 0/0/0/0.
- 2026-09-23 - PR 1 on `feature/baseline`: TestHelpers copied and adapted, the one-element-array
  test, the `$env:TEMP` test, `tests/Test-AgentsClaims.ps1`, and the empty-suite branch
  closed. Local: 14/0/0/0. Each of the six claims plus the loop check was broken in a temp clone,
  and each break turned exactly its own `It` red.
- 2026-09-24 - PR 1 #2: scratch `ee1fc92` added a Dockerfile; run 35947096213 went red on exactly
  `no-dockerfile`, and `b0c0098` removed the file. Automerge merged #2 as `1915092` on its own.
- 2026-09-24 - PR 2 on `feature/inspector`: `src/Inspect-Repo.ps1` with five rules, `-Policy`
  through core, `-Halt`, `-Offline`. Suite 26/0/0/0. Corpus `corpus/images-249752d.jsonl`, 155
  verdicts, reproducible; the I10 mapping of found and missed items is on the forensic chain at
  seq 2.
