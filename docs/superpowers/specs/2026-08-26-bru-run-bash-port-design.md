# Port bru-run from zsh to bash — Design

**Issue:** [nathpaiva/bru-run#4](https://github.com/nathpaiva/bru-run/issues/4)

## Goal

`bru-run` currently requires zsh (`bin/bru-run` shebang, all of
`lib/bru-run.zsh` written in zsh-only syntax). zsh ships by default on macOS
but not on most Linux distros, so a Linux user has to install it first —
a real barrier for a CLI meant to be generic and installable anywhere.

This ports the engine to bash so `bru-run` needs nothing beyond a shell most
systems already have. Behavior stays identical — this is a portability fix,
not a feature change.

## Scope

Full rewrite, not an incremental patch. Both files change:

- `lib/bru-run.zsh` (1156 lines, ~35 functions) → new file `lib/bru-run.sh`
- `bin/bru-run` (117 lines) → same file, shebang and one `source` line
  change, rest is behavior-identical

`lib/bru-run.zsh` is deleted in the same PR that adds `lib/bru-run.sh` — no
period where both files exist and diverge. `bin/bru-run` switches to the new
file the moment it's ready, since it's a thin entrypoint with no zsh-isms of
its own beyond the shebang.

## Target: bash 4.0+, not 3.2

macOS ships bash 3.2 (frozen there since 2007 — Apple won't ship a GPLv3
binary), so targeting bash 4.0+ **reintroduces a dependency on macOS
without Homebrew** — the same shape of barrier issue #4 exists to remove,
just moved from "install zsh" to "upgrade bash". This is a conscious
trade-off, not an oversight:

- **Why 4.0+ anyway:** native associative arrays (`declare -A`). The
  current zsh code has exactly one associative-array use site
  (`bruCaptureVars`, `lib/bru-run.zsh:579`, driving `chained_vars`
  lookups). On bash 3.2 this has to be emulated (parallel indexed arrays or
  a temp file of `key\tvalue` pairs) — more code for one function, in
  exchange for every other function reading closer to the current zsh.
- **What this means for Linux:** no new barrier — bash 4+ has shipped by
  default on essentially all mainstream distros for over a decade.
- **What this means for macOS:** every macOS user (with or without zsh
  already) needs `brew install bash` — this must be documented clearly
  (see Documentation section) so a Linux user isn't misled into thinking
  the whole dependency problem disappears; it only disappears for Linux.
- **Considered, not done:** a bash-3.2-compatible fallback for just the
  `chained_vars` associative-array use site, so macOS's system bash would
  work unmodified. Not pursued now — adds real complexity (dual code path
  or emulation layer) for a single function, and every other function
  needs bash 4+ syntax anyway (`${var,,}`, `mapfile`) with no 3.2
  equivalent that's worth writing. If someone needs this later, it's a
  fresh issue with real motivation behind it, not speculative work now.

**bin/bru-run gets a version guard** at startup: if
`${BASH_VERSINFO[0]}` < 4, print a clear error pointing at the install
command, instead of letting 3.2 fail on unfamiliar syntax with a confusing
parse error.

## Syntax mapping (zsh → bash 4+)

| zsh | bash 4+ |
|---|---|
| `typeset -A map` / `${(kv)map[@]}` | `declare -A map` / `for key in "${!map[@]}"` |
| `${(f)"$(cmd)"}` (split by newline into array) | `mapfile -t arr <<< "$(cmd)"` |
| `${(s:,:)var}` (split on `,`) | `IFS=',' read -ra arr <<< "$var"` |
| `${(j:,:)array}` (join with `,`) | `(IFS=','; echo "${array[*]}")` (subshell — don't leak IFS) |
| `${(M)array:#pattern}` (glob-filter array) | loop with `[[ "$item" == pattern ]]` |
| `${0:A:h}` (script's own absolute dir) | `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd` |
| `(#i)` case-insensitive glob qualifier | `shopt -s nocasematch` around the `[[ ]]` |
| `${var:l}` (lowercase) | `${var,,}` |
| `${var:t}` (basename) | `${var##*/}` |
| `local -a arr=()` | `local arr=()` (bash doesn't type-tag the declaration) |

This table is the reference for the implementation plan's tasks — each
function in `lib/bru-run.zsh` gets ported using these equivalents, function
by function, preserving names and signatures.

## Testing

No automated suite exists in this repo (see `CLAUDE.md`) and this port
doesn't introduce one — out of scope for a portability fix. Verification is
manual, side by side:

1. Before deleting `lib/bru-run.zsh`, run each function's exercising
   command against `examples/pompom-time/` on the current zsh code and
   record the output.
2. Run the same command against the new `lib/bru-run.sh` (with `bin/bru-run`
   pointed at it).
3. Compare output byte-for-byte where the command is deterministic (`--list`,
   `--docs`, `--envs`); for anything touching timestamps or ordering that
   isn't guaranteed, compare structurally instead.

Covers, at minimum: `init`, `--list`, `--docs <request>`, `--envs`,
`--project`, `--branch`, `--set`, `--data`, `--confirm` + `protected_envs`,
a full `bru run` invocation (if `bru` is installed), and `chained_vars`
capture (the one associative-array path, worth extra attention).

## Documentation to update

- **README.md** — "Requirements" section: replace the zsh requirement with
  bash 4.0+; state plainly that macOS's system bash (3.2) does not qualify
  and the fix is `brew install bash` (with the exact command); remove the
  link to issue #4 once it's closed.
- **CLAUDE.md** — "Language: zsh, not bash" section is rewritten to
  "Language: bash 4.0+, not POSIX sh / not zsh", explaining why 4.0+ was
  chosen (native associative arrays, one use site) and stating the
  Homebrew-on-macOS cost explicitly, so a future contributor doesn't
  "helpfully" downgrade the syntax to 3.2-compatible without knowing why
  4.0+ was picked.
- **bin/bru-run / lib/bru-run.sh** — top-of-file comments updated to
  describe bash instead of zsh.

## Out of scope

- No new features, no behavior changes — pure portability.
- No automated test suite.
- No bash-3.2 fallback for `chained_vars` (see "Considered, not done"
  above).
- No support for running under both zsh and bash — bash replaces zsh
  entirely, this repo carries one engine.
