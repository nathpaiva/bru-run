# Plan — issue #38: init and README stop before the setup is finished

Issue: https://github.com/nathpaiva/bru-run/issues/38

## Branches

Work started on: `docs/38-bru-run-setup-flow` (branched from `main`)
Worktree: `.claude/worktrees/docs-38-bru-run-setup-flow`

| # | Branch | Branched from | Carries | Status |
|---|--------|---------------|---------|--------|
| 1 | `docs/38-bru-run-setup-flow` | `main` | Everything | done |

## What is wrong

`bru-run init` writes `.bru-run.yml` and stops. The next steps — create the
collection, do a first `--env` run to get the empty secrets file, fill it in —
are nowhere. The README `## Setup` stops at the same spot. `init` also does
not register the project, so `-p <name>` fails until the user runs `bru-run`
from inside the project once.

## What I am changing

### 1. `bin/bru-run` — the `init` block

- After writing the file, call `bruRegisterProject "$namespace"
  "$PWD/.bru-run.yml"`. It is already sourced (line 31), silent, locked, and
  dedups. Print one line saying `-p <name>` now works.
- Print the next steps: create `<collection>/` and
  `<collection>/environments/<env>.bru`; the first `bru-run <request> --env
  <env>` creates `~/.bru-run/<namespace>/<env>.bru` with empty slots; fill it
  in; run again for the real call.

Nothing else in the block changes. Still `exit 0` at the end.

### 2. README — `## Setup`

- Soften the opener: `init` is also how you start a project whose collection
  does not exist yet, not only one that already has it.
- After the yml example, add the four-step sequence from the issue.
- Say `init` registers the project now, so `-p <name>` works right away.
- Document the auto-created `~/.bru-run/<namespace>/<env>.bru`: what makes it,
  when, and that it starts empty. Today this fact lives only in a code
  comment at `lib/bru-run.sh`.

Issue point 7 ("Install says 'ships only the script'") is already fixed —
PR #36 rewrote that section. Nothing to do there.

## How I will test it

No suite in this repo.

- `shellcheck -s bash bin/bru-run lib/bru-run.sh` — still clean (CI from #39
  will gate this on the PR too)
- `bash -n bin/bru-run`
- Run `bru-run init` in a throwaway dir with a fake `BRU_RUN_CONFIG_DIR`:
  - `.bru-run.yml` written as before
  - the registry file now has the entry
  - `bru-run -p <name> --list` works from a different directory straight away
  - the next-steps text prints
- Re-run `bru-run init` in the same dir → still refuses with `exit 1` (that
  guard is untouched)
- Read the rendered README section for flow

## Project skills

- `superpowers:using-git-worktrees` — worktree already made for this branch
- No `Co-Authored-By` line (personal repo)
- Draft PR only, `Closes #38` in the body
