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
