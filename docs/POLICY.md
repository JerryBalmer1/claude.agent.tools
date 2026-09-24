<!--
  GENERATED FILE - DO NOT EDIT BY HAND.
  Rendered from config/repo.json by scripts/Generate-Policy.ps1.
  Edit the config and regenerate:
      pwsh -NoProfile -File scripts/Generate-Policy.ps1
  CI check "generated-match-config" fails the build if this file and the config disagree.
-->

# Policy - JerryBalmer1/claude.agent.tools

Every rule below is rendered from `config/repo.json`. This file is evidence of the
config, not a second copy of it. If you want to change a rule, change the config.

## Branch flow

Long-lived branches: `main` and `develop`.
Work starts on a branch named `feature/<something>`.

| From | Into |
|---|---|
| `feature/*` | `develop` |
| `develop` | `main` |

Any other pair is refused by the `branch-flow` check. There is no path that skips
`develop`.

## Merge strategy

Strategy: **merge**. Delete the branch on merge: **true**.

Merge commits only. Never squash, never rebase, never force-push, never amend anything
already pushed. A merge commit has two parents and that is the evidence; a squash has
one parent and a hash that corresponds to nothing that was ever reviewed.

## Review mode

Mode: **auto**.

> auto from birth: the automerge workflow merges a pull request once all six checks are green; flip to human and regenerate to stand it down

While the mode is `auto`, `.github/workflows/automerge.yml` merges a pull request
whose required checks are all green, with a merge commit. No human approval is
waited for. Flipping the mode to `human` and regenerating stops that on the next PR.

## Checks that must be green

- `requires-header`
- `trailer-guard`
- `branch-flow`
- `generated-match-config`
- `pester`
- `forensic-verify`

One CI job per entry, named exactly the string above. The `generated-match-config` job
asserts that the set of job names in `.github/workflows/ci.yml` equals this list, so
the workflow cannot quietly drop a check.

## Commit trailer

Every commit carries a `who:` trailer as its **last line**. Allowed values:

- `who: claude`
- `who: grok`
- `who: fable`
- `who: jerry`

Verify your own commit before pushing:

```powershell
git log -1 --format='%(trailers:key=who,valueonly)'
```

The trailer is **operator-asserted**. It is not a signature and it does not prove
anything. It is a place to be caught lying, checked by `trailer-guard`.

## Script version floor

PowerShell **7.4+** only. Every `.ps1` and `.psm1` in this repository starts with:

```powershell
#Requires -Version 7.4
```

No bash, no sh, no heredocs - including in CI, where workflow steps use `shell: pwsh`
and call scripts in `scripts/`. The `requires-header` check enforces the header.

## Owners

- @JerryBalmer1
