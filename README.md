# bru-run

Generic shell CLI for running Bruno collections from any project — not tied
to one API.

## What it does

Point it at a project's Bruno collection with a `.bru-run.yml` file, and run
requests by search term or path, from any directory:

```bash
bru-run item list --env dev --show
bru-run --list
bru-run --docs item create
```

Secrets for each environment live outside any repo, in
`~/.bru-run/<namespace>/<env>.bru` — never committed, never gitignored (a
gitignored secret is still one `git add -A` away from a leak; a secret that
physically isn't in the tree can't leak through git at all).

## Setup

Inside a project with a Bruno collection:

```bash
bru-run init
```

This writes a `.bru-run.yml` at the project root:

```yaml
namespace: my-project
collection: ./bruno
env_helper: ~/.bru-run/my-project
```

From then on, `bru-run` finds this config by walking up from wherever it's
run, the same way git finds `.git`. From outside the project:
`bru-run --project my-project ...`.

### Protecting an environment

Add `protected_envs` to guard sensitive environments like `prod`:

```yaml
protected_envs: [prod]
```

`bru-run --env prod ...` then fails unless `--confirm` is also passed. This
is the only environment-safety check the code enforces — a project with no
`protected_envs` key has none, and it is the project's own choice which
names go in the list.

## Install (local, for now)

```bash
npm link
```

## Example

`examples/pompom-time/` is a small fake collection used to prove the design
end to end — invented endpoints, no real data.

```bash
cd examples/pompom-time
bru-run --list
```

## Claude skill

`skill/SKILL.md` teaches an agent to use `bru-run` safely: never print a
secret, never edit a saved `.bru`, discover requests via `--list`/`--docs`
instead of grep. It carries no project-specific rules (like which
environment is production) — that's for whoever configures a project's own
skill instance to add.

## Status

v1 in progress. See [issue #1](https://github.com/nathpaiva/bru-run/issues/1)
and `docs/superpowers/specs/2026-08-09-bru-run-design.md` for the full design.
