# bru-run

Generic shell CLI for running Bruno collections from any project. It started
as a project-specific `bru-api` wrapper and was extracted here so any Bruno
collection can use the same engine, not just the one it was built for.

## This repo is public

No company-specific or personal references anywhere: not in code, not in
docs, not in commit messages, not in PR or issue comments. Before adding an
example, a fake project name, or a log line, check it doesn't leak anything
real.

Anything posted to GitHub (PR comments, issue comments, commit messages) is
always in English, no matter what language the working conversation happens
to be in.

## Language: zsh, not bash

`bin/bru-run` and `lib/bru-run.zsh` use zsh-only syntax throughout —
associative arrays, `${(f)"..."}` splitting, `${0:A:h}`, `(#i)` glob
qualifiers, `${var:l}`/`${var:t}` modifiers, and more. Don't write plain
POSIX/bash assuming it'll work here; it won't.

zsh ships by default on macOS (Catalina+) but not on most Linux distros —
this is a known gap, tracked in
[issue #4](https://github.com/nathpaiva/bru-run/issues/4) (remove the zsh
dependency, port to plain bash). Until that lands, treat zsh as a hard
requirement, not an implementation detail to casually change.

## Where things live

- `bin/bru-run` — the entrypoint. Resolves which project to run against,
  handles the `init` subcommand, then hands off to `bruRun`.
- `lib/bru-run.zsh` — the engine. Project/env resolution, env file locking,
  payload patching, request discovery, the main `bruRun` function.
- `skill/SKILL.md` — the Claude skill. Generic on purpose: it carries only
  the safety rules that make sense for *any* Bruno collection (never print a
  secret, never edit a saved `.bru`, discover via `--list`/`--docs`). It does
  **not** carry project-specific policy like "which environment is
  production" — that's for whoever configures a project's own skill
  instance.
- `examples/pompom-time/` — a fake collection used to prove the design end
  to end. Invented endpoints only. Never add real data here, even
  gitignored.
- `docs/superpowers/specs/` — design docs for planned or completed work.

## `.bru-run.yml` — the per-project config

Lives at a project's root, versioned. Kept intentionally shallow — no YAML
parser dependency, just grep-based key reads (`bruReadConfigKey`):

```yaml
namespace: my-project
collection: ./bruno              # path to the Bruno collection
env_helper: ~/.bru-run/my-project    # where this project's secrets live
protected_envs: [prod]           # optional — see below
chained_vars: ./bruno/chained-vars.tsv   # optional — see below
```

- `namespace` — used to look this project up from anywhere via
  `--project <namespace>`, and as the registry key in
  `~/.config/bru-run/projects.yml`. Treat it as an arbitrary string, not a
  safe identifier — it gets escaped before use in any regex (`bruEscapeRegex`).
- `collection` — resolved relative to the config file's own directory.
- `env_helper` — resolved relative to the config file too; `~` expands.
  Defaults to `$BRU_RUN_SECRETS_ROOT/<namespace>` when omitted.
- `protected_envs` — a flow-list (`[a, b]`) of environment names that need
  `--confirm` before `bruRun` will call them. This is the *only*
  environment-safety check enforced in code. A project with no
  `protected_envs` key has no enforcement at all — everything else is prose
  in `SKILL.md` that an agent has to choose to follow. Don't treat that
  prose as equivalent to a real gate.

- `chained_vars` — a path to the file holding this project's
  `{envVarName -> jq expression}` map, one `name<whitespace>expression` pair
  per line. Resolved relative to the config file. It is a pointer instead of
  an inline map because of the rule below; the expressions are long enough
  that a one-line flow-list would be unreadable. A missing file warns and
  carries on rather than failing the run — chaining is optional, and killing
  the run would take `--list` and `--docs` down with it.

If you're adding a new top-level config key, keep it a single-line, shallow
value (or a one-line flow-list, like `protected_envs`) — the whole config
format depends on not needing a real YAML parser. When a key needs more
structure than that, point at a sidecar file the way `chained_vars` does.

## Associative arrays never cross a process boundary

`BRU_RUN_CHAINED_VARS` was originally the only way to supply a chaining map,
and it silently did nothing: `bin/bru-run` is its own process and zsh cannot
export an associative array (`typeset -gAx` does not help). It still works
when `lib/bru-run.zsh` is sourced into the calling shell, and it is kept for
that case, but anything the CLI has to see belongs in `.bru-run.yml` or a
file it points at. See [issue #10](https://github.com/nathpaiva/bru-run/issues/10).

## Secrets never touch the repo

`~/.bru-run/<namespace>/<env>.bru` holds the real per-environment values.
This directory is never inside a git repo — not even gitignored. A
gitignored secret is still one `git add -A` away from a leak; a secret that
physically isn't in the tree can't leak through git at all. This is a hard
invariant, not a style preference — don't add a code path that writes a
secret value anywhere under a versioned directory, even temporarily.

The global registry (`~/.config/bru-run/projects.yml`, mapping namespace →
config file path) follows the same rule: never versioned, lives in
`$BRU_RUN_CONFIG_DIR`.

## Concurrency

Two shell invocations can race on the same file. `bruWithEnvLock` (mkdir-based,
atomic, with stale-lock cleanup) is the general mechanism for this — used both
for env-file writes (`bruCaptureVars`) and the project registry write
(`bruRegisterProject`). If you add a new code path that reads, rewrites, and
moves a shared file back into place, wrap it the same way instead of adding a
new locking scheme.

## Testing changes

There's no test suite — verify by running `bin/bru-run` directly against
`examples/pompom-time/`:

```bash
cd examples/pompom-time
../../bin/bru-run --list
../../bin/bru-run --envs
```

`bru` (the real Bruno CLI) may not be installed in a given environment —
that's fine for testing resolution, discovery, and payload-patching logic;
only the final `bru run` call itself needs the real binary.
