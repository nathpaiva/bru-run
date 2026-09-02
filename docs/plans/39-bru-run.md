# Plan — issue #39: CI (shellcheck + smoke test on every PR)

Issue: https://github.com/nathpaiva/bru-run/issues/39

## Branches

Work started on: `chore/39-bru-run-ci` (branched from `main`)
Worktree: `.claude/worktrees/chore-39-bru-run-ci`

| # | Branch | Branched from | Carries | Status |
|---|--------|---------------|---------|--------|
| 1 | `chore/39-bru-run-ci` | `main` | Everything | done |

## What is wrong

There is no `.github/` in the repo. Nothing checks a change before it lands on
`main`. `CLAUDE.md` even says "There's no test suite".

Running the exact command the issue names, `shellcheck -s bash bin/bru-run
lib/bru-run.sh`, exits 1 today on the code already on `main`. shellcheck
reports from severity `style` up by default, so a first CI run would be red:

- `bin/bru-run:170` — SC2154 (warning) x3: `envHelper`, `protectedEnvs`,
  `chainedVarsFile` "referenced but not assigned". They are set at runtime by
  `bruFieldsOf` through `printf -v`, which shellcheck cannot see.
- `bin/bru-run:30` — SC1091 (info): the `source` line is not followed.
- `lib/bru-run.sh` — four style/info items: SC2295 and SC2018/SC2019 are real
  minor bugs; SC1003 and SC2016 are false positives.

## What I am changing (Option B — full strictness)

### 1. `.github/workflows/ci.yml`

- Triggers: `pull_request` and `push` to `main`.
- One job on `ubuntu-latest` (ships bash 5, satisfies the 4.0+ floor, and has
  `shellcheck` preinstalled).
- `permissions: contents: read` — least privilege.
- `concurrency` group so a new push to a PR cancels the stale run.
- Steps:
  1. `actions/checkout@v4`
  2. `shellcheck -s bash bin/bru-run lib/bru-run.sh` — no severity flag, must
     be completely clean
  3. smoke: `cd examples/pompom-time && ../../bin/bru-run --list &&
     ../../bin/bru-run --envs`

### 2. `bin/bru-run` — two directives

- Above the `source` line: `# shellcheck source=../lib/bru-run.sh` (fall back
  to `# shellcheck disable=SC1091` if the path does not resolve — lib is
  checked directly in the same run anyway).
- Above line 170: `# shellcheck disable=SC2154` with a one-line note that
  `bruFieldsOf` populates those three names.

### 3. `lib/bru-run.sh` — four one-liners

| Line | Finding | Change |
|---|---|---|
| ~71 | SC1003 (false positive: `'\'` is a literal backslash) | `# shellcheck disable=SC1003` + note |
| ~924 | SC2295 (real: unquoted pattern in `${tmp#...}`) | quote it: `"${tmp#"$collection"/}"` |
| ~1126 | SC2016 (false positive: `{{$guid}}` is a literal Bruno token) | `# shellcheck disable=SC2016` + note |
| ~1327 | SC2018/SC2019 (real: `tr 'a-z' 'A-Z'` is locale-fragile) | `tr '[:lower:]' '[:upper:]'` |

## How I will test it

No suite in this repo. Verify by running the exact workflow commands locally
from the worktree:

- `shellcheck -s bash bin/bru-run lib/bru-run.sh` — must exit 0, no output
- `cd examples/pompom-time && ../../bin/bru-run --list && ../../bin/bru-run --envs` — both exit 0
- `bash -n bin/bru-run lib/bru-run.sh` — syntax still clean
- After the PR is up, confirm the Actions run is green on the PR itself

## Project skills

- `superpowers:using-git-worktrees` — worktree already created for this branch
- No `Co-Authored-By` line (personal repo)
- Draft PR only, `Closes #39` in the body

## Follow-up (not this branch)

The two SC1003/SC2016 disables are false positives from shellcheck's parser.
Worth a note in the tracker if a newer shellcheck ever fixes them, so the
directives can be dropped. Not blocking.
