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
