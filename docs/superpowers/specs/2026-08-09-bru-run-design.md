# bru-run design

Issue: [nathpaiva/bru-run#1](https://github.com/nathpaiva/bru-run/issues/1)

## Why

`bru-api` (in dotfiles' `zsh/bruno.zsh`) already has a fully generic engine —
`bruRun`, `bruPickRequest`, `bruPatchBody`, `bruCaptureVars`, and the rest take
a collection path and a helper name as arguments. Nothing inside them is
specific to the project it was first built for. Only the thin wrapper at the
bottom is:

```zsh
function bru-api() {
  bruRun "$SOME_COLLECTION_PATH" some-namespace "$@"
}
```

`bru-run` extracts the generic engine into its own installable CLI, so any
project with a Bruno collection can use it, not just the one `bru-api` was
written for.

## Scope

- Generic CLI (`bru-run`), shell-based, no dependency on Claude.
- A new, generic Claude skill, in this same repo, separate from the existing
  project-specific skill (which stays in dotfiles, untouched).
- Config per project, secrets always outside any versioned repo.
- Tested against a fake collection from the `pompom-time` project.
- Repo stays private until we've verified nothing project-specific or
  personal leaks into it (code or example collection).

## Out of scope

- Migrating `bru-api` itself off dotfiles yet — that's a follow-up once
  `bru-run` is proven.
- The paused project-specific skill investigation (session ID never visible)
  — unrelated work, on a different agent, not touched here.

## Design

### Project config: `.bru-run.yml`

Lives at a project's root, versioned:

```yaml
namespace: pompom-time
collection: ./bruno              # path to the Bruno collection, relative to this file
env_helper: ~/.bru-run/pompom-time   # where this project's per-env secrets live
```

Only paths and a name — never a secret value.

### Discovering the project

Two ways `bru-run` finds which project to run against:

1. **From inside a project** — walks up from the current directory looking
   for `.bru-run.yml`, the same way git finds `.git`. No flag needed.
2. **From anywhere** — `bru-run --project <namespace> ...` looks the name up
   in the global registry.

### Global registry

`~/.config/bru-run/projects.yml` — one entry per project (`namespace` →
absolute path to its `.bru-run.yml`). Auto-updated every time `bru-run` finds
a `.bru-run.yml` by walking up from cwd — no manual registration step.
Never versioned anywhere, same rule as the secrets below.

### Secrets: always outside the repo

`~/.bru-run/<namespace>/<env>.bru` holds the real per-environment values
(one file per environment: `dev.bru`, `stage.bru`, `prod.bru`, ...). This
folder is never inside a git repo — not even gitignored inside one. A
gitignored secret is still one `git add -A` away from a leak; a secret that
physically isn't in the tree can't leak through git at all.

**Auto-creation.** The first time `bru-run` resolves `--env <name>` and finds
neither `~/.bru-run/<namespace>/<name>.bru` nor the collection's own
`environments/<name>.bru`, it:

1. Creates `~/.bru-run/<namespace>/` (`chmod 700`) if missing.
2. Generates `<name>.bru` (`chmod 600`) with empty placeholders for whatever
   vars the collection declares as `vars:secret`, if any.
3. Prints the path and stops, asking the user to fill in the values and
   re-run.

This keeps the "secrets never touch the repo" rule without adding a manual
setup step for a new project.

### The generic Claude skill

New skill, lives in this repo (not dotfiles), teaches an agent to use
`bru-run` against whatever `.bru-run.yml` is in scope. It inherits the
**universal** safety rules already proven in the project-specific skill it
came from:

- Never print a secret value.
- Never edit the saved `.bru` file — use `--set`/`--data` for overrides.
- Discover requests via `--list`/`--docs`, never `grep`/`find`/`cat` on the
  collection.
- Never invent a request path or a flag.

It does **not** inherit domain rules that only make sense for the one API
this was extracted from, most notably "never run against prod without the
literal word prod" — that stays in that project's own skill. A
generic skill can't know what "production" means for an arbitrary project;
environment-gating policy is left to whoever configures a given project's
skill instance, out of scope for this first version.

### Distribution

- CLI: installable package (Homebrew tap, private for now; `npm link` as a
  first working version before a tap exists).
- Skill: installed separately, alongside the CLI, for whoever wants Claude
  integration — not a hard dependency of the CLI itself.

### Testing

Fake collection modeled on the `pompom-time` project, committed to this repo
under an example folder — no real pompom-time data, no real production data.

## Open questions for the implementation plan

- Exact Homebrew tap vs. npm packaging choice — first pass can be npm link
  local only, formalize distribution later.
- Whether the generic skill ships example `.bru-run.yml` scaffolding
  (`bru-run init`) or expects it hand-written for v1.
