# bru-run

Generic shell CLI for running Bruno collections from any project — not tied
to one API.

## Requirements

- **bash 4.0+** — the CLI is written in bash, not POSIX `sh`. Linux ships
  bash 4+ by default on essentially every mainstream distro. **macOS does
  not** — Apple has frozen macOS's system bash at 3.2 since 2007 (licensing,
  not neglect), so macOS users need `brew install bash` first. Check your
  version with `bash --version`; anything below 4.0 will fail with a clear
  error pointing back here.
- [`jq`](https://jqlang.org/) — used to patch and read JSON payloads.
- [`fzf`](https://github.com/junegunn/fzf) — optional, only needed for the
  interactive request/environment pickers.
- The [Bruno CLI](https://www.usebruno.com/) (`bru`) — runs the actual
  request.

## What it does

Point it at a project's Bruno collection with a `.bru-run.yml` file, and run
requests by search term or path, from any directory:

Run `bru-run --help` (or `-h`) any time for a quick reference of every flag.

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
`bru-run --project my-project ...` (or `-p my-project`).

### Running against a git worktree

A worktree can have its own in-progress collection. `--branch` (`-b`) uses it
without `cd`-ing there, looking under `.claude/worktrees/<branch-slug>/` at the
main checkout's root, where `<branch-slug>` is the branch name with every `/`
replaced by `-`:

```bash
bru-run -p my-project -b my-branch --list
```

To see which worktrees exist and which ones are ready, use `--branches` (`-B`):

```bash
$ bru-run -p my-project -B
👩‍💻 worktrees for my-project
  my-branch        ✓ has .bru-run.yml
  another-branch   ✗ missing
```

A worktree needs its own `.bru-run.yml` before `-b` can use it. `bru-run` never
creates it — both `-B` and a failed `-b` print the `cp` command to run.

### Protecting an environment

Add `protected_envs` to guard sensitive environments like `prod`:

```yaml
protected_envs: [prod]
```

`bru-run --env prod ...` then fails unless `--confirm` is also passed. This
is the only environment-safety check the code enforces — a project with no
`protected_envs` key has none, and it is the project's own choice which
names go in the list.

### Chaining values between requests

Every `bru run` is its own process, so a value one request returns is gone
before the next one starts. Point `chained_vars` at a file and `bru-run`
writes those values back into the env file, where the next request can read
them:

```yaml
chained_vars: ./bruno/chained-vars.tsv
```

The file holds one pair per line — the variable name, a run of whitespace,
then a jq expression run against the response body. Blank lines and `#`
comments are ignored:

```
itemId	.result.item.id // .result.items[0].id
itemName	.result.item.name
```

After each run, `bru-run` prints the names it saved, never the values. What
the expressions match is specific to one API's response shapes, so bru-run
ships no map of its own — see `examples/pompom-time/bruno/chained-vars.tsv`.

## Install

```bash
npm install -g bru-run
```

The npm package ships only the script. The runtime tools in **Requirements**
above (`bash` 4+, `jq`, `bru`, and optionally `fzf`) still have to be on your
`PATH`.

To hack on bru-run itself, clone the repo and run `npm link` instead.

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

Released, `1.0.0`. See [issue #1](https://github.com/nathpaiva/bru-run/issues/1)
for the original design notes.
