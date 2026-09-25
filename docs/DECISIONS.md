# Decisions

Conventions this repository runs on that no config file states. Each entry says what was
decided, why, and where the evidence lives. An entry is appended, not rewritten; a decision that
is reversed gets a new entry that names the old one.

## D1 - The default branch is `develop`, not `main`

**Decided** 2026-09-23, at birth, packet T0 PR 0. Recorded here in packet T1 PR 1.

`develop` was pushed before `main` so that GitHub made it the default branch. images keeps
`main` as its default; tools does not, and the difference is deliberate.

**Why.** `.github/workflows/automerge.yml` merges on its `workflow_run` trigger, and a
`workflow_run` workflow always runs the copy of itself that sits on the repository's DEFAULT
branch, never the pull request's copy. At birth `main` held only the birth commit
(`AGENTS.md`, `README.md`, `.gitignore`) and carried no `automerge.yml` and no
`config/repo.json` until the first promotion. With `main` as the default, automerge could not
have run for any `feature/*` -> `develop` pull request before that promotion. With `develop` as
the default, it could from the moment `develop` held the workflow and the config.

**Evidence.** Forensic chain seq 1 (`birth-claude-agent-tools`), section "DECISION, default
branch = develop". Live: `gh repo view --json defaultBranchRef` answers `develop`.

## D2 - PRs #1 and #4 were merged by claude with `gh`, not by automerge

**Decided** by the code, not by anyone at the time: `scripts/AutoMerge.Lib.ps1` reads
`config/repo.json` from the pull request's BASE branch, and a base with no config means no
authorisation. Recorded here in packet T1 PR 1.

| PR | Head -> base | Why automerge stood down | Merged by | Merge commit |
|---|---|---|---|---|
| #1 | `feature/scaffold` -> `develop` | `develop` was the birth commit and had no `config/repo.json` (run 35946658154) | claude, `gh pr merge --merge` | `a3d36b6` |
| #4 | `develop` -> `main` | `main` was still the birth commit and had no `config/repo.json` (run 35948338236) | claude, `gh pr merge --merge` | `ec807ec` |

In both cases every required check was green on the head before the merge. #2, #3 and #5 were
merged by automerge (`github-actions[bot]`), because by then the base carried the config.

**Merger, as recorded.** GitHub reports `mergedBy: JerryBalmer1` for #1 and #4. That is the
account the `gh` token belongs to, not the actor who ran the command. The actor is recorded
three times, and all three say claude: the body of each merge commit ("Merged by claude with gh
pr merge --merge, NOT by automerge"), `docs/plans/2026-09-23-birth/PLAN.md` (Progress), and
forensic chain seq 3 for #4. Neither pull request was merged by a human.

The T1 packet said the opposite, that a human merged both. That premise was false, and the
records were not changed to match it. Forensic seq 1 says "the PR that introduces
config/repo.json is merged by a human". That sentence describes what `AutoMerge.Lib.ps1`
expects, and it was written before #1 was opened. It does not record who merged #1. No record
before seq 4 names #1's merger. Seq 4 does.

**Consequence.** Neither case can recur. `develop` and `main` both carry `config/repo.json`
now, so every later pull request on either base is gated by automerge.

## D3 - Merge commits only, enforced by the repository and measured by a claim

**Decided** at birth as convention (`config/repo.json` -> `merge.strategy: merge`), and made a
repository setting in packet T1 PR 1: squash merging and rebase merging are disabled with
`gh repo edit --enable-squash-merge=false --enable-rebase-merge=false`, so the merge button
offers only a merge commit.

Branch protection is not used. The T1 packet ruled it out; the repository is public, so the
free tier would have allowed it. `src/Inspect-Repo.ps1` rule `unprotected-branch` reports that
as a fail whenever it runs online.

**Measured.** `AGENTS.md` claim `merge-commits-only`, tested in `tests/Test-AgentsClaims.ps1`
through `gh api graphql` with the workflow's `GITHUB_TOKEN`. The REST repository endpoint
leaves the `allow_*_merge` fields out for a caller without push access. GraphQL returns
`mergeCommitAllowed`, `squashMergeAllowed` and `rebaseMergeAllowed` to any authenticated caller.

## D4 - The inspector's settings.json observer is ported as six rules in `src/Inspect-Repo.ps1`

**Decided** 2026-09-24, packet R1 PR 2.

**Source.** The inspector's `origin/main`,
[`cf5105f`](https://github.com/JerryBalmer1/claude.build.inspector/commit/cf5105fdb2951b73c49382a690b69efc3c3c432d),
file `claude.build.inspector@cf5105f:src/claude.build.inspector/claude.build.inspector.psm1`:
[lines 391-424](https://github.com/JerryBalmer1/claude.build.inspector/blob/cf5105fdb2951b73c49382a690b69efc3c3c432d/src/claude.build.inspector/claude.build.inspector.psm1#L391-L424)
(the five settings findings) and
[lines 266-298](https://github.com/JerryBalmer1/claude.build.inspector/blob/cf5105fdb2951b73c49382a690b69efc3c3c432d/src/claude.build.inspector/claude.build.inspector.psm1#L266-L298)
(the policy path, including `allow-contains-bash`; its shell pattern is line 23).

| Source finding | Rule here | Verdict |
|---|---|---|
| `settings.json missing` | `settings-missing` | warn |
| `defaultMode is auto` | `default-mode-auto` | warn |
| `defaultMode is bypassPermissions` | `default-mode-bypass` | fail |
| `no deny rules` | `no-deny-rules` | warn |
| `disableAllHooks is true` | `hooks-disabled` | fail |
| `policy halt: allow-contains-bash` | `allow-contains-bash` | warn; fail under `-Policy` with at least one halt-weight rule |

**Where the port differs, and why.**

- **Output.** The source added a lowercase string to a report object. Here each finding is a
  `claude.agent.tools.Verdict` with a rule, a line and a verdict (`typed-verdicts`).
- **Weights.** The source had none; a finding was a string a human read. `fail` is kept for the
  two settings that switch a control off outright: every permission check (`bypassPermissions`)
  or every hook (`disableAllHooks`). Absence and posture are `warn`. `no-deny-rules` has to be
  `warn` in any case: this repository's own `.claude/settings.json` declares hooks and no deny
  list, and the claim `self-inspection-clean` forbids a `fail` here.
- **Tracked, not on disk.** The source read whatever file was on disk. Here
  `.claude/settings.json` counts only when it is tracked, the same as every other rule in this
  command, so two clones of one commit give the same verdicts.
- **`allow-contains-bash` keeps its trigger.** The source raised it only when the parser had
  returned a halt-weight rule. That case, `-Policy` with halt-weight law, is the `fail`. Without
  law it is reported as a `warn` rather than hidden, one verdict per entry.
- **Bad JSON still throws.** The source raised `InspectorBadSettings` for an empty file, bad JSON
  or a non-object. Here it is a terminating error with the same three causes, since none of the
  six rules can judge such a file.
- **Not ported.** The user scope (`$HOME/.claude`), the `policy module not found` fail-open, the
  `policy halt:` pass-through of every halt rule, and `-Halt`'s `InspectorPolicyHalt`. `-Halt`
  here already exits 1 on any `fail`, and core's policy module is vendored, so there is no
  missing module to fail open on.

**Measured.** `tests/Inspect-Repo.Tests.ps1`, Describe *Inspect-Repo: .claude/settings.json
rules*: one fixture per rule that trips it, a clean fixture that trips none, and the refusal
of a file that is not a JSON object. Against the `src/Inspect-Repo.ps1` before this entry, 8 of
its 9 tests fail. The rules are at `src/Inspect-Repo.ps1:488-556`.

## D5 - The fuzzer is not ported; it is archived at `1cf2c63`

**Decided** 2026-09-24, packet R1 PR 2.

The fuzzer repository is retiring, and nothing of it comes here: not `Get-FuzzerCase`,
`Invoke-ClaudeFuzzer` or `Add-FuzzerRegression`, and not its 8-case corpus,
`claude.build.fuzzer@1cf2c63:corpus/cases.jsonl`. The archive is its `origin/main`,
[`1cf2c63`](https://github.com/JerryBalmer1/claude.build.fuzzer/tree/1cf2c63bc68c14bfacf020ffd3d7f7dc4637655c),
and that sha is the whole of the carry.

**Why.** A fuzzer case is an adversarial input run against a live Claude Code permission surface,
recorded as a regression when it gets through. Tools observes a tree and emits verdicts; it runs
nothing against an agent. Porting the fuzzer would put an attacker in a repository whose claims
(`commands-not-library`, `verdicts-not-receipts`) are about observation. `README.md` already
lists the fuzzer as out of scope.

`config/retired-repos.json` is unchanged. It already names `claude.build.fuzzer` and
`claude.build.inspector`, with `claude.agent.tools` as the successor of both. "Successor" names
where the work went, not a claim that every function came with it; this entry says what did not.

**Evidence.** In a clone of the fuzzer, `git branch -r --contains 1cf2c63` answers `origin/main`.
`git grep` at that sha finds `Get-FuzzerCase` at line 543, `Invoke-ClaudeFuzzer` at line 619 and
`Add-FuzzerRegression` at line 717 of
`claude.build.fuzzer@1cf2c63:src/claude.build.fuzzer/claude.build.fuzzer.psm1`, and the corpus
has 8 lines.
