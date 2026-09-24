<!--
  GENERATED FILE - DO NOT EDIT BY HAND.
  Rendered from config/repo.json by scripts/Generate-Policy.ps1.
  CI check "generated-match-config" fails the build if this file and the config disagree.
-->

## What this changes

<!-- One paragraph. What is different after this merges, and how would someone tell? -->

## Base branch

Tick exactly one. Any other pair fails the `branch-flow` check.

- [ ] `feature/*` -> `develop`
- [ ] `develop` -> `main`

## Trailer

- [ ] Every commit ends with a `who:` trailer as its last line
- [ ] The value is one of: `claude`, `grok`, `fable`, `jerry`

## Merge

- [ ] This will land as a **merge commit** - not a squash, not a rebase

## Checks that must be green

- [ ] `requires-header`
- [ ] `trailer-guard`
- [ ] `branch-flow`
- [ ] `generated-match-config`
- [ ] `pester`
- [ ] `forensic-verify`

`review.mode` is `auto`: once every check above is green, the automerge workflow
merges this pull request without waiting for a human.

## Wall

- [ ] Nothing under `vendor/` was edited, and the submodule pin is unchanged
- [ ] No sibling repository was touched
- [ ] `Invoke-Build` is still the build entry point - no direct Pester or ScriptAnalyzer call
- [ ] No bash, no heredocs, no `cat >` - including in CI
- [ ] No Python and no Dockerfile
- [ ] No `Co-Authored-By` trailer on any commit
