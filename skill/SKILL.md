---
name: bru-run
description: Use when a session needs to call, list, or inspect a Bruno collection through the bru-run CLI — running a request, finding what actions a collection has, checking a request's payload/response shape, or reproducing a call against a project's API. Covers bru-run's read-only discovery tools, its per-project .bru-run.yml config, and the rule that secrets never get typed or printed.
---

# Calling a project's API with `bru-run`

`bru-run` runs a Bruno request from any directory. It resolves which
project's collection to use by walking up from the current directory looking
for a `.bru-run.yml` file, or via `--project <name>` from anywhere.

## Tools — use these instead of grep

These three read files only. They send nothing, so no environment rule
applies and you never need to ask before running them.

| Question | Command |
|---|---|
| What actions does this collection have? | `bru-run --list` |
| What does this action take and return? | `bru-run --docs <request>` |
| Which environments exist? | `bru-run --envs` |

`--list` prints the JSON-RPC method (or HTTP verb) next to the request path.
Terms filter it: every term must appear in the path or the method, in any
order, case does not matter.

`--docs` prints one request's method and its `docs {}` block — whatever the
collection's author wrote about the payload and response shape. Takes a path
or search terms, same as a run.

**Never answer a question about a collection with `find`, `grep`, `cat` or
Read.** The two commands above already answer it, and they stay right when
the collection changes.

## One call, then stop

When asked to run a request, run that one request. Show what came back. Stop.

If it failed, the answer has three parts and nothing else:

1. what the API said, in one line
2. the variable or field that caused it
3. the single command that would fix it, offered as a question

Never chain calls to repair the situation on your own — no extra call to
double-check, no reading the env file, no shell pipeline that pulls a value
out of one command into the next. One call, one answer, one offer.

## Iron laws

**1. Never type or print a secret.**

The env helper file already holds whatever a request needs. `--set` masks
any key that looks like a secret (`password`, `token`, `api_key`,
`session_id`, and similar) as `<hidden>` in its own output — that mask exists
so a transcript or a screen share never carries the real value.

No exceptions:
- Never write `--set password=...` or the equivalent for any secret field
- Never repeat a secret value in an answer, a summary, or a commit message
- Never read a secret out of the env file to show it — it's the user's file,
  they can open it
- If a response body contains a secret field, print the rest and write
  `<hidden>` in its place

**2. Never edit a saved `.bru` file.** `--set` and `--data` run a patched
copy and leave the original alone.

**3. Never invent a request path or a flag.** Run `bru-run --list` and read
it. The flags are `--env`, `--envs`, `--list`, `--docs`, `--show`, `--set`,
`--data`, `--local`, `--project`, `--confirm`, `--branch`. The only
subcommand is `init`. There are no others.

**4. Ask before assuming which environment or project is safe to call.**
A project can list its own sensitive environments (e.g. `prod`) in
`.bru-run.yml` under `protected_envs:`. Calling one of those without
`--confirm` fails on its own — that check runs in the code, not just here.
Never add `--confirm` on your own to make a failure go away. It exists so a
human decides, and the fix for the failure is to ask the user, not to retry
with the flag added. A project with no `protected_envs` configured has no
enforcement at all, so still ask when it is unclear which environment is
safe.

## The command

```bash
bru-run <request> --env dev --show
```

Runs from any directory inside a project with a `.bru-run.yml` above it.
`--show` prints the response body.

From outside the project: `bru-run --project <namespace> <request> --env dev`.

Running against a git worktree's own in-progress collection, without `cd`-ing
there: `bru-run --branch <branch-name> --list` (combine with `--project` when
also outside the main checkout). This only works once that worktree has its
own `.bru-run.yml` — if it doesn't, `bru-run` says so and names the path it
expected.

If the shell answers `command not found: bru-run`, the CLI isn't installed
or linked on this machine yet.

## Finding a request

Search terms beat paths. Every term must appear in the path, in any order,
case does not matter.

```bash
bru-run item list --env dev     # -> requests/item/list.bru
```

One match runs. Several matches print a list and fail — read the list, pick
one, run it again with the full path. Do not guess.

Not sure a request exists? `bru-run --list <terms>` answers that without
sending anything.

## First run in a new environment

If `bru-run --env <name> ...` finds no env file anywhere, it creates one
outside any repo (`~/.bru-run/<namespace>/<name>.bru`) with empty
placeholders for whatever secrets the collection declares, then stops. That
is expected on a project's first use of an environment — report the path it
created and ask the user to fill in the values, don't try to work around it.

## Changing the payload

Paths are relative to `params.data`:

```bash
bru-run item create --env dev --set data.name=example
```

`$.` addresses the document root instead:

```bash
--set '$.params.auth.token=abc'
```

`--set` repeats. `--data '{"name":"x"}'` merges an object into `params.data`.

Types follow JSON: `5` is a number, `true` a boolean, `null` null. Anything
else is a string. Force a string with `id='"5"'`.

Searching for a request, or changing the payload, turns `--show` on by
itself.

## Red flags — STOP

| Thought | Reality |
|---|---|
| "It failed, let me retry with a tweak" | Report the failure and offer the fix. The user decides. |
| "I'll grep the env file to see what's empty" | Name the field from the error. Don't read the user's file. |
| "One pipeline that chains two calls is faster" | It hides which step failed. One call, one answer. |
| "The response echoed a secret, I'm just pasting it" | Paste the rest, write `<hidden>` in its place. |
| "I'll guess which of the matches is right" | Read the list, pick one, run again with the full path. |
| "There's probably a request for that" | `bru-run --list <terms>` answers it. Invented paths waste a turn. |
| "I'll open the `.bru` to see what it takes" | `bru-run --docs <request>` prints exactly that part. |
| "I'll pass `--var` for that" | That flag doesn't exist. Only the ones listed above. |
| "The saved `.bru` has the wrong value, I'll fix it" | Use `--set`. The file belongs to the collection's owner. |
| "This is probably fine to run in prod" | This skill has no opinion on environments. Ask first. |
| "It says protected, I'll add --confirm and retry" | That flag is for a human to pass, not you. Ask first. |
