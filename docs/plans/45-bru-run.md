# Plan — issue #45: Harden env resolution

Issue: https://github.com/nathpaiva/bru-run/issues/45
Title: Harden env resolution: regression tests + bruSecretKeys parsing + secrets dir perms

## Branches

Work started on: `fix/45-bru-run-harden-env-resolution` (branched from `main`)
Worktree: `.claude/worktrees/fix-45-bru-run-harden-env-resolution`

| # | Branch | Branched from | Carries | Status |
|---|--------|---------------|---------|--------|
| 1 | `fix/45-bru-run-harden-env-resolution` | `main` | Everything | done |

One branch, one PR. All changes are in `lib/bru-run.sh`, a new `test/` script,
`package.json`, and `.github/workflows/ci.yml`.

## Context

Two bugs have landed in env resolution: #34 (worktree config) and #43 (`--env`
never bootstrapping the secrets file). CI only runs `shellcheck` + a smoke test
that never touches env resolution.

Confirmed RED state on this branch:

- `bruSecretKeys` on a single-line `vars:secret [api_key, token]` returns nothing.
- `bruSecretKeys` on a CRLF file returns `api_key\r` (trailing `\r` kept).

Both make `bruEnsureEnvFile` read "no secrets declared", return 0, and let the
request go out with blank auth — the exact failure #43 removed, on a
hand-edited file.

## Approach

### Part 1 — regression tests

- New `test/env-resolution.sh`: a plain bash script (no `bats` — keeps the repo
  dependency-free). It `source`s `lib/bru-run.sh`, runs asserts, prints
  `PASS`/`FAIL` per case, exits non-zero if any fail. Uses a scratch collection
  built with `mktemp -d` and a scratch `BRU_RUN_SECRETS_ROOT`, cleaned on exit.
- `package.json`: add `"test": "bash test/env-resolution.sh"`.
- `.github/workflows/ci.yml`: add a `npm test` step after the smoke step.

### Part 2 — `bruSecretKeys` parsing

Rewrite the awk in `bruSecretKeys` to handle all three shapes:

- multi-line `vars:secret [ \n key \n key \n ]` (current)
- single-line `vars:secret [a, b]`
- CRLF: strip `\r` from every line before parsing

Split on `,` and trim each key in both the multi-line and single-line cases.
Keep `bruSecretKeys` pure — parse only, no hard failure — so `bruAllSecretKeys`
and `--set` masking cannot break.

### Part 3 — loud failure in `bruEnsureEnvFile`

After the `bruSecretKeys` call: if the env file contains a `vars:secret` line
but `secretKeys` came back empty, print a clear error to stderr and `return 1`
instead of "using collection env ... (no secrets declared)" + `return 0`. This
is the belt-and-suspenders for any shape the parser still misses.

### Part 4 — parent secrets dir permissions

Before writing the stub, `mkdir -p "$BRU_RUN_SECRETS_ROOT"` then
`chmod 700 "$BRU_RUN_SECRETS_ROOT"`. `mkdir -p "$envHelper"` alone creates
`~/.bru-run` itself with the default umask (755) — values are protected but the
layout is world-listable. The existing `chmod 700 "$envHelper"` and
`chmod 600` on the file stay.

### Part 5 — cosmetic

`echo "  ${key}: "` -> `echo "  ${key}:"` (drop the trailing space in stub lines).

## Test cases

`test/env-resolution.sh` covers:

1. `bruEnsureEnvFile`: real env + declares a secret + no helper file -> stub
   written, request not sent (return 1)
2. real env + no secrets -> runs (return 0), no file created
3. typo'd env name -> "unknown environment" on stderr, return 1
4. helper file already present -> return 0, file bytes unchanged (not truncated)
5. `bruSecretKeys`: multi-line block -> keys (regression guard, passes today)
6. `bruSecretKeys`: single-line `vars:secret [a, b]` -> `a\nb` (RED today)
7. `bruSecretKeys`: CRLF file -> keys with no `\r` (RED today)
8. `bruEnsureEnvFile`: `vars:secret` line present but parses to zero keys ->
   return 1 (loud fail), not return 0 (RED today)
9. perms: after stub creation, `$BRU_RUN_SECRETS_ROOT` is `700`, stub file is `600`
10. stub line has no trailing space

RED-GREEN: run `test/env-resolution.sh` before the `lib/bru-run.sh` changes and
confirm cases 6, 7, 8 fail. Apply the changes, confirm all pass.

## Verification

- `bash test/env-resolution.sh` green
- `shellcheck -s bash bin/bru-run lib/bru-run.sh` exit 0
- `npm run smoke` exit 0

## Project skills

- `superpowers:test-driven-development` for the `lib/bru-run.sh` behavior changes.

### What shipped on branch 1

Followed the plan as written, with three small differences Nath approved
after an inline review (no reviewer agent dispatched — the project's real
review gate is the cross-session `code-review` session, on the PR):

- `vars:secret []` (present but empty) now also triggers the Part 3 loud
  failure, not just a `vars:secret [` block that fails to parse. This is a
  deliberate choice, not an edge case missed by the parser.
- `prepublishOnly` became `npm run smoke && npm test` — beyond the plan's
  "add a test script + CI step", so a broken env-resolution path can't ship.
- No test added for a custom `env_helper` outside `$BRU_RUN_SECRETS_ROOT`
  (Part 4's `if` guard has a false branch nothing exercises). Known gap, low
  risk — that branch's behavior is unchanged from before this fix.

### Round 2 — the `env-resolution-code-review` session's findings on PR #46

That session ran `/code-review` (the superpowers plugin) against the PR and
found 9 issues, 3 of them real correctness/secret-leak bugs. Nath asked for
all 9 fixed before merge. Each was reproduced locally first, then fixed with
a new RED test:

- **HIGH** — `bruEnsureEnvFile` checked `-e`, `bruRun` checked `-f`. A
  directory at the helper path, or a file created between the two checks,
  returned 0 and ran with blank auth. Fixed: the existence check now lives
  inside `bruEnsureEnvFileLocked` (under `bruWithEnvLock`), rejects anything
  that is not a regular file, and `bruRun` re-checks `-f` after calling
  `bruEnsureEnvFile` instead of trusting the branch it took.
- **HIGH** — a `vars:secret [` with no closing `]` fed the rest of the file
  into the key list. Fixed: `bruSecretKeys` now exits 2 (not 0 with empty
  output) when the block was opened but never closed, or parsed to zero
  keys either way — one signal, not a second grep guessing at the same thing.
- **HIGH** — a Bruno-disabled key (`~token`) kept its `~`, so masking by name
  (`bruAllSecretKeys`) missed it and `--set token=...` could print the real
  value for any secret name outside the hardcoded heuristic list. Fixed:
  `bruSecretKeys` strips a leading `~` from every key.
- **MEDIUM** — `$BRU_RUN_SECRETS_ROOT` only got `chmod 700` on the
  stub-write path, so an existing install stayed `755` forever, and the
  `mkdir`/`chmod` pair left a brief window at the old mode. Fixed: tightened
  on every `bruEnsureEnvFile` call (not gated on a path-prefix check
  anymore), and created with `umask 077` so it is never briefly world-listable.
- **MEDIUM** — chmod-ing a directory bru-run did not create, if
  `BRU_RUN_SECRETS_ROOT` pointed somewhere repurposed. Not changed: pointing
  that variable at a directory is telling bru-run "this is my secrets root",
  and 700 is the correct mode for that regardless of who else wrote to it
  first — documented as a known tradeoff rather than coded around.
- **MEDIUM** — the stub write raced two concurrent `bru-run` invocations on
  the same brand-new env, against `bruWithEnvLock`'s own stated job. Fixed:
  the whole existence-check-then-write sequence now runs under
  `bruWithEnvLock`.
- **LOW** — the loud-failure guard re-implemented `bruSecretKeys`'s own
  `vars:secret [` detection in a second regex (grep vs. awk), so the two
  could drift. Fixed: removed, now reads `bruSecretKeys`'s exit code instead.
- **LOW** — `CLAUDE.md`'s "Testing changes" section said "there's no test
  suite". Fixed — points at `test/env-resolution.sh` / `npm test` now.
- **LOW** — no test covered Bruno's own multi-key, comma-separated,
  multi-line form. Added.

17 test cases (11 original + 6 new) passed before the re-review.

### Round 3 — re-review found #4 not actually fixed, plus a regression

The re-review on `27f55fe` closed 6 of 9: #1, #2, #3, #6, #7, #8, #9 held up.
Two things did not:

- **#4 was not fixed for the case it described.** `bruRun` only calls
  `bruEnsureEnvFile` when the helper file does not exist yet. An install
  from before this PR has its helper files already filled in, so that call
  never happens again for them — the root stayed at the old mode forever,
  exactly what #4 reported. The new test only exercised the
  no-helper-yet path, so it passed without covering the real case.
- **New regression** — the fix for #4 dropped the `envHelper` path-prefix
  guard, so every project's `bruEnsureEnvFile` call now creates and chmods
  `$BRU_RUN_SECRETS_ROOT` even when that project's own `env_helper:` is
  somewhere else entirely and never uses it.

Fixed by pulling the root-tightening out into its own `bruTightenSecretsRoot`
helper, called from two places: inside `bruEnsureEnvFile` (unchanged
behavior) and from `bruRun` itself, before the `-f` check, every time `--env`
is used — covering an existing install without `bruEnsureEnvFile` ever
running. The path-prefix guard moved into the helper, so it still applies
either way.

Also asked to fix the three LOW findings from that same round instead of
deferring them:

- `bruWithEnvLock`'s timeout message said "skipped saving variables" even on
  the bootstrap path, where nothing is being saved. Changed to a neutral
  "env file is busy, try again".
- A Bruno-disabled (`~`) secret had its tilde stripped by `bruSecretKeys`
  itself, so the stub it feeds asked for a value Bruno would never send —
  silently re-enabling something the collection author turned off. Fixed:
  `bruSecretKeys` now keeps the `~` as-is; only `bruAllSecretKeys` (used for
  `--set` masking, where only the name matters) strips it.
- An unclosed block now makes that one env's keys drop out of
  `bruAllSecretKeys`'s masking union with no signal. Fixed:
  `bruAllSecretKeys` reads `bruSecretKeys`'s exit code per file and warns on
  stderr when a file's `vars:secret` could not be read.

21 test cases (17 + 4 new) pass; `shellcheck` and `npm run smoke` stay clean.
