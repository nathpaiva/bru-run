# bru-run Bash Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `lib/bru-run.zsh` with a new `lib/bru-run.sh` written in bash 4.0+, and update `bin/bru-run` to source and run it — identical behavior, no zsh dependency.

**Architecture:** One new file, `lib/bru-run.sh`, ported function-by-function from `lib/bru-run.zsh` using the syntax mapping table below. `lib/bru-run.zsh` is deleted in the task that completes the port. `bin/bru-run` changes its shebang to bash, adds a version guard, and its own zsh-isms (`${0:A:h}`, `local -a`) are ported too. No new files beyond `lib/bru-run.sh`.

**Tech Stack:** bash 4.0+ (was zsh). Same external tools as before: `jq`, `awk`, `fzf` (optional), `bru` (Bruno CLI, optional for non-run testing).

**Spec:** `docs/superpowers/specs/2026-08-26-bru-run-bash-port-design.md`

## Global Constraints

- Target bash 4.0+ (not 3.2) — native associative arrays via `declare -A`. macOS ships 3.2; document the Homebrew requirement (Task 6).
- Behavior must stay identical to the current zsh version — same flags, same output text (including the 👩‍💻 prefix lines), same exit codes. This is a portability fix, not a feature change.
- No automated test suite — verify manually against `examples/pompom-time/`, comparing zsh output (current `main` branch / `lib/bru-run.zsh`) against bash output (new `lib/bru-run.sh`) side by side.
- Public repo: grep every diff for "moz"/"app-api" (case-insensitive) before committing — must find nothing.
- Commit message format: header only, no scope prefix (`feat: ...` / `refactor: ...`, never `feat(cli): ...`).
- No `Co-Authored-By` line (personal repo).
- `lib/bru-run.zsh` is deleted in the same PR — no period where both files coexist.

## Syntax mapping reference (zsh → bash 4+)

| zsh | bash 4+ |
|---|---|
| `typeset -A map` / `${(kv)map[@]}` | `declare -A map` / `for key in "${!map[@]}"` |
| `${(f)"$(cmd)"}` (split by newline into array) | `mapfile -t arr <<< "$(cmd)"` |
| `${(s:,:)var}` (split on `,`) | `IFS=',' read -ra arr <<< "$var"` |
| `${(j:,:)array}` (join with `,`) | `(IFS=','; echo "${array[*]}")` (subshell) |
| `${(M)array:#pattern}` (glob-filter array) | loop with `[[ "$item" == pattern ]]` |
| `${0:A:h}` (script's own absolute dir) | `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd` |
| `(#i)` case-insensitive glob | `shopt -s nocasematch` around the `[[ ]]` |
| `${var:l}` (lowercase) | `${var,,}` |
| `${var:t}` (basename) | `${var##*/}` |
| `${var:h}` (dirname) | `${var%/*}` |
| `${var:r}` (strip extension) | `${var%.*}` |
| `local -a arr=()` | `local arr=()` |
| `typeset -g -ra NAME=(...)` (readonly global array) | `declare -ag NAME=(...)` (bash has no readonly array enforcement worth fighting; document intent with a comment instead) |
| `typeset -g "field=$value"` (dynamic var name) | `declare -g "$field=$value"` |
| `print -r -- "$x"` | `printf '%s\n' "$x"` |
| `${array[(Ie)$x]}` (index of exact match, 0 if absent) | loop: `for i in "${!array[@]}"; do [[ "${array[$i]}" == "$x" ]] && found=1 && break; done` |
| `setopt local_options extended_glob` (needed for `(#i)`) | not needed — `shopt -s nocasematch` is function-local enough via subshell or explicit `shopt -u` at function end |
| zsh arrays are 1-indexed (`${array[1]}` = first) | bash arrays are 0-indexed (`${array[0]}` = first) — every loop/index touch needs review, not just syntax swap |

**bash 4 caveat used throughout:** `mapfile -t arr <<< "$var"` adds a trailing empty element when `$var` is empty — every loop consuming a `mapfile` result must handle a possible single empty-string element the same way the zsh code's `${(f)"..."}` (which produces zero elements for empty input) did not need to.

## File Structure

- **Create:** `lib/bru-run.sh` — the ported engine, same ~35 functions as `lib/bru-run.zsh`, same names, same call signatures.
- **Modify:** `bin/bru-run` — shebang, `SCRIPT_DIR` resolution, `source` path, `local -a` → `local`, array syntax in the `init` subcommand.
- **Delete:** `lib/bru-run.zsh` (final task).
- **Modify:** `README.md`, `CLAUDE.md` (Task 6 — documentation).

Tasks are grouped by real dependency boundaries in the source (verified by reading the full file): config/registry resolution has no dependents outside itself until `bruRun`; env-file writes and locking are used by both project resolution (indirectly, via registration) and the main run path; payload patching is self-contained but is a hot spot for the trickiest zsh-isms (jq argument building, the shared awk depth-counter); the main `bruRun` function is the integration point that exercises everything before it, so it comes last among the engine tasks.

---

### Task 1: Project + env config resolution (lines 56-330 of the zsh source)

**Files:**
- Create: `lib/bru-run.sh` (new file, starts here — header comment block, then this section)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `bruEscapeRegex(str) -> stdout`, `bruFindProjectConfig() -> stdout path|exit 1`, `bruReadConfigKey(configFile, key) -> stdout`, `bruReadProtectedEnvs(configFile) -> stdout csv`, `bruReadChainedVarsFile(configFile) -> stdout path|empty`, `bruLoadProjectConfig(configFile) -> stdout "namespace\tcollection\tenvHelper\tprotectedEnvs\tchainedVarsFile"`, `bruFieldsOf(resolved)` (sets `namespace`, `collection`, `envHelper`, `protectedEnvs`, `chainedVarsFile` as global vars in caller scope), `bruRegisterProject(namespace, configFile)`, `bruWriteRegistryEntry(namespace, namespacePattern, configFile)`, `bruLookupProject(namespace) -> stdout path|exit 1`, `bruResolveProject(projectName, branchName) -> stdout resolved-tuple`, `bruResolveWorktreeConfig(mainConfigFile, branchName) -> stdout path|exit 1`. Env vars `BRU_RUN_CONFIG_DIR`, `BRU_RUN_REGISTRY`, `BRU_RUN_SECRETS_ROOT` exported at file scope.

- [ ] **Step 1: Create `lib/bru-run.sh` with the header comment and exports**

Copy the header comment block from `lib/bru-run.zsh:1-54` verbatim (it's documentation, not code — no zsh syntax in it). Then:

```bash
#!/usr/bin/env bash
# (header comment block copied from lib/bru-run.zsh:1-54 goes here, unchanged)

# ---------------------------------------------------------------------------
# Project + env resolution
# ---------------------------------------------------------------------------

export BRU_RUN_CONFIG_DIR="${BRU_RUN_CONFIG_DIR:-$HOME/.config/bru-run}"
export BRU_RUN_REGISTRY="$BRU_RUN_CONFIG_DIR/projects.yml"
export BRU_RUN_SECRETS_ROOT="${BRU_RUN_SECRETS_ROOT:-$HOME/.bru-run}"
```

- [ ] **Step 2: Port `bruEscapeRegex`**

zsh original (`lib/bru-run.zsh:64-76`) loops over a zsh array literal of metacharacters. Bash port:

```bash
# Escape ERE metacharacters in a string so it can be spliced into a grep -E
# or awk pattern as a literal match. namespace comes from --project or a
# project's own .bru-run.yml — both arbitrary strings, so `.` in a namespace
# like "foo.bar" must not act as "any char" and match "fooxbar" instead.
bruEscapeRegex() {
  local s="$1"
  local metaChars=('\' '^' '$' '.' '[' ']' '|' '(' ')' '*' '+' '?' '{' '}')
  local c
  for c in "${metaChars[@]}"; do
    s="${s//$c/\\$c}"
  done
  printf '%s\n' "$s"
}
```

- [ ] **Step 3: Port `bruFindProjectConfig`**

zsh original uses `${dir:h}` (dirname). Bash port:

```bash
# Walk up from $PWD looking for .bru-run.yml, the way git finds .git. Prints
# the absolute path to the file it finds, or nothing if it hits /.
bruFindProjectConfig() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.bru-run.yml" ]]; then
      printf '%s\n' "$dir/.bru-run.yml"
      return 0
    fi
    dir="${dir%/*}"
    [[ -z "$dir" ]] && dir="/"
  done
  return 1
}
```

Note the added `[[ -z "$dir" ]] && dir="/"` — `${dir%/*}` on `/foo` produces empty string, not `/`, unlike zsh's `${dir:h}` which produces `/`. Without this the loop would never terminate on a path exactly one level below root.

- [ ] **Step 4: Port `bruReadConfigKey` and `bruReadProtectedEnvs`**

`bruReadConfigKey` (`lib/bru-run.zsh:95-98`) has no zsh-isms — copy verbatim as a bash function. `bruReadProtectedEnvs` (`lib/bru-run.zsh:103-122`) uses `${(s:,:)raw}` split and `${(j:,:)trimmedNames}` join:

```bash
# Read one flat top-level key out of a .bru-run.yml. The file's shape is
# fixed and shallow (namespace / collection / env_helper), so a small grep
# does the job without adding a YAML parser dependency.
bruReadConfigKey() {
  local configFile="$1" key="$2"
  grep -m1 -E "^${key}:" "$configFile" | sed -E "s/^${key}:[[:space:]]*//" | sed -E "s/[[:space:]]+#.*$//"
}

# Read the optional `protected_envs: [a, b]` key — a one-line flow list of
# environment names that need --confirm before bruRun will call them. Prints
# a comma-separated list, or nothing if the key is absent.
bruReadProtectedEnvs() {
  local configFile="$1"
  local raw
  raw="$(bruReadConfigKey "$configFile" protected_envs)"
  [[ -z "$raw" ]] && return 0

  raw="${raw#\[}"
  raw="${raw%\]}"
  local names
  IFS=',' read -ra names <<< "$raw"
  local n trimmed
  local trimmedNames=()
  for n in "${names[@]}"; do
    trimmed="${n## }"
    trimmed="${trimmed%% }"
    [[ -n "$trimmed" ]] && trimmedNames+=("$trimmed")
  done
  local joined
  joined="$(IFS=','; echo "${trimmedNames[*]}")"
  printf '%s\n' "$joined"
}
```

- [ ] **Step 5: Port `bruReadChainedVarsFile` and `bruLoadProjectConfig`**

`bruReadChainedVarsFile` (`lib/bru-run.zsh:133-152`) uses `${configFile:h}` (dirname) and `${raw/#\~/$HOME}` (tilde expansion at start of string — this pattern already works identically in bash, no change needed):

```bash
# Read the optional `chained_vars: <path>` key — a pointer to the file that
# holds this project's {envVarName -> jq expression} map. Prints the resolved
# absolute path, or nothing when the key is absent.
#
# It is a pointer instead of an inline block on purpose. .bru-run.yml is read
# with grep and has no YAML parser behind it, so every key has to stay a
# single shallow line; a nested map would need indentation-aware parsing. The
# expressions are long enough that a one-line flow list is not readable
# either.
bruReadChainedVarsFile() {
  local configFile="$1"
  local base="${configFile%/*}"
  local raw
  raw="$(bruReadConfigKey "$configFile" chained_vars)"
  [[ -z "$raw" ]] && return 0

  [[ "$raw" == "~"* ]] && raw="${raw/#\~/$HOME}"
  [[ "$raw" != /* ]] && raw="$base/$raw"

  if [[ ! -f "$raw" ]]; then
    echo "👩‍💻 chained_vars file not found: $raw" >&2
    return 0
  fi

  printf '%s\n' "$raw"
}

# Load the keys out of a .bru-run.yml, resolving `collection`,
# `env_helper` and `chained_vars` relative to the config file's own
# directory, and expanding a leading ~ in env_helper.
bruLoadProjectConfig() {
  local configFile="$1"
  local base="${configFile%/*}"

  local namespace collection envHelper protectedEnvs chainedVarsFile
  namespace="$(bruReadConfigKey "$configFile" namespace)"
  collection="$(bruReadConfigKey "$configFile" collection)"
  envHelper="$(bruReadConfigKey "$configFile" env_helper)"
  protectedEnvs="$(bruReadProtectedEnvs "$configFile")"
  chainedVarsFile="$(bruReadChainedVarsFile "$configFile")"

  if [[ -z "$namespace" || -z "$collection" ]]; then
    echo "👩‍💻 $configFile is missing namespace or collection" >&2
    return 1
  fi

  [[ "$collection" != /* ]] && collection="$base/$collection"
  [[ "$envHelper" == "~"* ]] && envHelper="${envHelper/#\~/$HOME}"
  [[ -z "$envHelper" ]] && envHelper="$BRU_RUN_SECRETS_ROOT/$namespace"

  printf '%s\n' "$namespace"$'\t'"$collection"$'\t'"$envHelper"$'\t'"$protectedEnvs"$'\t'"$chainedVarsFile"
}
```

Note: `base="${configFile%/*}"` — since `configFile` always has at least one `/` (it's an absolute path ending in `.bru-run.yml`), the empty-dirname edge case from Step 3 doesn't apply here.

- [ ] **Step 6: Port the field-order array and `bruFieldsOf`**

zsh original (`lib/bru-run.zsh:180-205`) uses `typeset -g -ra`, `${(@ps:\t:)resolved}` (tab-split), 1-indexed `{1..${#array[@]}}` loop, and `typeset -g`. Bash port (arrays are 0-indexed, `declare -g` for dynamic var names, `IFS=$'\t' read -ra` for the tab split):

```bash
# The tab-delimited field order bruLoadProjectConfig/bruResolveProject print
# in — the single source of truth both bruFieldsOf (below) and any future
# reader has to match. Adding a field means adding it here, in the printf
# above, and nowhere else.
declare -ag bruResolvedFields=(namespace collection envHelper protectedEnvs chainedVarsFile)

# Split a bruResolveProject/bruLoadProjectConfig tab-delimited result into
# its named fields, instead of every caller hand-rolling %%/# slicing (which
# has no single source of truth for field order, and silently misreads if a
# field is ever added without updating every call site). Assigns each field
# to a variable of the same name in the caller's scope — the caller must
# `local` those names first, same convention as `read`.
#
# Usage: local namespace collection envHelper protectedEnvs chainedVarsFile
#        bruFieldsOf "$resolved"
bruFieldsOf() {
  local resolved="$1"
  local values
  IFS=$'\t' read -ra values <<< "$resolved"

  local i field
  for i in "${!bruResolvedFields[@]}"; do
    field="${bruResolvedFields[$i]}"
    declare -g "$field=${values[$i]}"
  done
}
```

- [ ] **Step 7: Port `bruRegisterProject`, `bruWriteRegistryEntry`, `bruLookupProject`**

No zsh-isms in these three beyond what's already covered (they're mostly `grep`/`sed`/`awk` already). Copy with only the function-declaration syntax changed:

```bash
# Write/update one entry in the global registry so `--project <name>` can
# find this project later, from anywhere. Called every time a .bru-run.yml
# is found by walking up from cwd — no manual registration step.
#
# Locked with bruWithEnvLock: this runs on every invocation, including
# read-only ones, so two bru-run calls at the same time could otherwise both
# read the old file, both write a tmp copy, and one registration is lost.
#
# Skips the lock and the write entirely when the entry already matches —
# without this, every --list/--docs call (read-only, nothing changed) still
# takes the lock and rewrites the registry file on every single invocation.
bruRegisterProject() {
  local namespace="$1" configFile="$2"
  mkdir -p "$BRU_RUN_CONFIG_DIR"

  local namespacePattern
  namespacePattern="$(bruEscapeRegex "$namespace")"

  [[ -f "$BRU_RUN_REGISTRY" ]] || touch "$BRU_RUN_REGISTRY"

  local existing
  existing="$(grep -m1 -E "^${namespacePattern}:" "$BRU_RUN_REGISTRY" 2>/dev/null | sed -E "s/^${namespacePattern}:[[:space:]]*//")"
  [[ "$existing" == "$configFile" ]] && return 0

  bruWithEnvLock "$BRU_RUN_REGISTRY" bruWriteRegistryEntry "$namespace" "$namespacePattern" "$configFile"
}

# Does the actual registry rewrite — split out from bruRegisterProject so it
# can run under bruWithEnvLock (which calls "$@" as a plain command).
bruWriteRegistryEntry() {
  local namespace="$1" namespacePattern="$2" configFile="$3"

  if grep -q -m1 -E "^${namespacePattern}:" "$BRU_RUN_REGISTRY" 2>/dev/null; then
    local tmp="${BRU_RUN_REGISTRY}.tmp$$"
    awk -v nsPattern="$namespacePattern" -v ns="$namespace" -v path="$configFile" '
      $0 ~ "^" nsPattern ":" { print ns ": " path; next }
      { print }
    ' "$BRU_RUN_REGISTRY" > "$tmp" && mv "$tmp" "$BRU_RUN_REGISTRY"
  else
    echo "${namespace}: ${configFile}" >> "$BRU_RUN_REGISTRY"
  fi
}

# Look a namespace up in the global registry. Prints the config path.
bruLookupProject() {
  local namespace="$1"
  [[ -f "$BRU_RUN_REGISTRY" ]] || return 1
  local namespacePattern
  namespacePattern="$(bruEscapeRegex "$namespace")"
  grep -m1 -E "^${namespacePattern}:" "$BRU_RUN_REGISTRY" | sed -E "s/^${namespacePattern}:[[:space:]]*//"
}
```

- [ ] **Step 8: Port `bruResolveProject` and `bruResolveWorktreeConfig`**

`bruResolveProject` (`lib/bru-run.zsh:270-311`) uses `${mainResolved%%$'\t'*}` (tab-delimited first-field extraction — this works identically in bash, no change) and calls the functions from earlier steps. `bruResolveWorktreeConfig` (`lib/bru-run.zsh:319-330`) uses `${mainConfigFile:h}` (dirname) and `${branchName//\//-}` (global replace — already bash-compatible):

```bash
# Resolve which project to run against: --project <name> forces a registry
# lookup; otherwise walk up from cwd. --branch <name> then swaps in that
# worktree's own .bru-run.yml instead of the one just resolved — see
# bruResolveWorktreeConfig. Registers the *main* project either way — never
# the worktree's config — so the registry always answers a later --project
# with the main checkout, not whichever worktree was resolved last. Prints
# "namespace\tcollection\tenvHelper\tprotectedEnvs\tchainedVarsFile" on
# success.
bruResolveProject() {
  local projectName="$1" branchName="$2"
  local mainConfigFile

  if [[ -n "$projectName" ]]; then
    mainConfigFile="$(bruLookupProject "$projectName")"
    if [[ -z "$mainConfigFile" || ! -f "$mainConfigFile" ]]; then
      echo "👩‍💻 unknown project '$projectName' — run bru-run from inside it once, or check $BRU_RUN_REGISTRY" >&2
      return 1
    fi

    local cwdConfigFile
    cwdConfigFile="$(bruFindProjectConfig)"
    if [[ -n "$cwdConfigFile" && "$cwdConfigFile" != "$mainConfigFile" ]]; then
      echo "👩‍💻 warning: --project '$projectName' ($mainConfigFile) differs from this directory's own project ($cwdConfigFile)" >&2
    fi
  else
    mainConfigFile="$(bruFindProjectConfig)" || {
      echo "👩‍💻 no .bru-run.yml found above $PWD — pass --project <name>, or run 'bru-run init' here" >&2
      return 1
    }
  fi

  local mainResolved
  mainResolved="$(bruLoadProjectConfig "$mainConfigFile")" || return 1
  local namespace="${mainResolved%%$'\t'*}"
  bruRegisterProject "$namespace" "$mainConfigFile"

  local configFile="$mainConfigFile"
  if [[ -n "$branchName" ]]; then
    configFile="$(bruResolveWorktreeConfig "$mainConfigFile" "$branchName")" || return 1
  fi

  if [[ "$configFile" == "$mainConfigFile" ]]; then
    printf '%s\n' "$mainResolved"
  else
    bruLoadProjectConfig "$configFile" || return 1
  fi
}

# Swap a project's main .bru-run.yml for the one inside one of its own git
# worktrees, so a request can run against a branch's in-progress collection
# changes without cd-ing there first. Matches the folder-naming convention
# Nath's own worktree-management tooling already uses: the branch name with
# every / replaced by -, under .claude/worktrees/ at the main checkout's
# root (the directory the resolved .bru-run.yml lives in).
bruResolveWorktreeConfig() {
  local mainConfigFile="$1" branchName="$2"
  local worktreeSlug="${branchName//\//-}"
  local worktreeConfigFile="${mainConfigFile%/*}/.claude/worktrees/${worktreeSlug}/.bru-run.yml"

  if [[ ! -f "$worktreeConfigFile" ]]; then
    echo "👩‍💻 no .bru-run.yml at .claude/worktrees/${worktreeSlug} — copy it from the main checkout first" >&2
    return 1
  fi

  printf '%s\n' "$worktreeConfigFile"
}
```

- [ ] **Step 9: Manual test — config resolution in isolation**

This task's functions aren't callable end-to-end yet (no `bruRun`, no `bruWithEnvLock` defined until Task 2), so verify by sourcing the file and calling functions directly:

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/refactor-4-bru-run-bash-port
bash -c '
  source lib/bru-run.sh
  cd examples/pompom-time
  bruFindProjectConfig
  echo "---"
  bruReadConfigKey .bru-run.yml namespace
  echo "---"
  bruReadProtectedEnvs .bru-run.yml
  echo "---"
  bruEscapeRegex "foo.bar[baz]"
'
```

Expected:
```
/Users/nathpaiva/www/labs/bru-run/.claude/worktrees/refactor-4-bru-run-bash-port/examples/pompom-time/.bru-run.yml
---
pompom-time
---
(empty line — pompom-time's .bru-run.yml has no protected_envs)
---
foo\.bar\[baz\]
```

Run `cat examples/pompom-time/.bru-run.yml` first if the exact namespace/protected_envs values are unknown — match against whatever it actually contains, this is illustrative.

`bruRegisterProject`/`bruWriteRegistryEntry`/`bruLookupProject` need `bruWithEnvLock` (Task 2) to run for real — defer their live test to Task 2's Step, note this in the commit if skipped here.

- [ ] **Step 10: Grep diff for moz/app-api, then commit**

```bash
git diff -- lib/bru-run.sh | grep -iE 'moz|app-api'
```

Expected: no output.

```bash
git add lib/bru-run.sh
git commit -m "refactor: port project/env config resolution to bash"
```

---

### Task 2: Env file writes, locking, and chained-vars capture (lines 332-589 of the zsh source)

**Files:**
- Modify: `lib/bru-run.sh` (append to the file created in Task 1)

**Interfaces:**
- Consumes: `bruListEnvNames` (defined in this task, used by `bruEnsureEnvFile`) — note this task both defines and uses it, unlike most cross-task dependencies.
- Produces: `bruSecretKeys(envFile) -> stdout lines`, `bruAllSecretKeys(collection) -> stdout lines`, `bruEnsureEnvFile(collection, envHelper, envName) -> exit 1 always (creates placeholder, tells user to fill it in)`, `bruListRequests(collection) -> stdout lines`, `bruListEnvNames(collection) -> stdout lines`, `bruPickRequest(collection) -> stdout path`, `bruPickEnv(collection) -> stdout name`, `bruSetEnvVar(envFile, key, value) -> exit 0 if written, 1 if unchanged/empty`, `bruWithEnvLock(file, cmd...) -> runs cmd under an mkdir-lock`, `bruLoadChainedVarsFile(mapFile) -> stdout "key\texpr" lines`, `bruCaptureVars(out, envFile, mapFile)`. These are used heavily by Task 5 (`bruRun`).

- [ ] **Step 1: Port `bruSecretKeys`, `bruAllSecretKeys`, `bruEnsureEnvFile` — collection listing first (needed by `bruEnsureEnvFile`)**

`bruListRequests`/`bruListEnvNames` (`lib/bru-run.zsh:397-406`) have no zsh-isms — copy verbatim as bash functions, needed here because `bruEnsureEnvFile` calls `bruListEnvNames`. `bruAllSecretKeys` (`lib/bru-run.zsh:350-356`) uses `${(f)"$( ... )"}` :

```bash
# ---------------------------------------------------------------------------
# Collection listing
# ---------------------------------------------------------------------------

# List a collection's request paths, one per line, sorted. folder.bru is
# Bruno's own folder-settings file, not a request — always excluded.
bruListRequests() {
  local collection="$1"
  ( cd "$collection" && find requests -name '*.bru' -not -name 'folder.bru' | sort )
}

# List a collection's environment names (no .bru suffix), one per line, sorted.
bruListEnvNames() {
  local collection="$1"
  ( cd "$collection" && find environments -name '*.bru' -exec basename {} .bru \; | sort )
}

# Print the names inside an environment file's vars:secret [ ... ] block, one
# per line — those are the ones whose real value has to live outside the
# versioned collection. Plain vars {} entries already carry a usable value in
# the collection itself.
bruSecretKeys() {
  local envFile="$1"
  [[ -f "$envFile" ]] || return 0
  awk '
    /^[ \t]*vars:secret[ \t]*\[/ { inSecret = 1; next }
    inSecret && /\]/ { inSecret = 0; next }
    inSecret { gsub(/^[ \t]*|[ \t]*,?[ \t]*$/, ""); if (length($0)) print }
  ' "$envFile"
}

# Union of every vars:secret key across all of a collection's environment
# files. --set patches a request before an environment is chosen, so the
# masking decision cannot depend on which one — a key that is secret in any
# environment is masked in the --set output regardless.
bruAllSecretKeys() {
  local collection="$1"
  local files
  mapfile -t files < <( cd "$collection" && find environments -name '*.bru' 2>/dev/null | sort )
  local f
  for f in "${files[@]}"; do
    [[ -z "$f" ]] && continue
    bruSecretKeys "$collection/$f"
  done | sort -u
}

# Create a project's env_helper directory and a placeholder env file the
# first time a requested environment is missing everywhere. Secrets never
# live inside a versioned repo — not even gitignored — so the first run
# always has to create this file outside of one.
#
# Only auto-creates when envName is a real environment (has a
# collection/environments/<envName>.bru) but is just missing its secrets
# file. A typo'd name (e.g. --env dve) is not silently turned into a new
# placeholder — that hides the real env names instead of showing them.
bruEnsureEnvFile() {
  local collection="$1" envHelper="$2" envName="$3"
  local envFile="$envHelper/$envName.bru"

  if [[ ! -f "$collection/environments/$envName.bru" ]]; then
    echo "👩‍💻 unknown environment '$envName' — available environments:" >&2
    bruListEnvNames "$collection" | sed 's/^/  /' >&2
    return 1
  fi

  mkdir -p "$envHelper" && chmod 700 "$envHelper"

  {
    echo "vars {"
    bruSecretKeys "$collection/environments/$envName.bru" \
      | while read -r key; do echo "  ${key}: "; done
    echo "}"
  } > "$envFile"
  chmod 600 "$envFile"

  echo "👩‍💻 created $envFile — fill in the values, then run this again" >&2
  return 1
}
```

Note the `mapfile -t files < <(...)` + explicit `[[ -z "$f" ]] && continue` guard in `bruAllSecretKeys` — this is the empty-input caveat from the syntax mapping table: if `find` produces no output, `mapfile` still yields one empty-string element, which zsh's `${(f)"..."}` would not have produced. The guard is necessary here because `bruSecretKeys "$collection/"` (empty filename) would otherwise be called once with a bogus path.

- [ ] **Step 2: Port the fzf pickers**

`bruPickRequest`/`bruPickEnv` (`lib/bru-run.zsh:413-430`) have no zsh-isms:

```bash
# ---------------------------------------------------------------------------
# fzf pickers
# ---------------------------------------------------------------------------

# fzf picker for a collection's requests. Prints the chosen path.
bruPickRequest() {
  local collection="$1"
  bruListRequests "$collection" \
    | fzf --height 60% --reverse --prompt 'request > ' \
          --header 'enter=select  esc=cancel' \
          --preview "sed -n '1,60p' '$collection/{}'" \
          --preview-window 'right:55%:wrap'
}

# fzf picker for a collection's environments. Prints the chosen env name.
bruPickEnv() {
  local collection="$1"
  bruListEnvNames "$collection" \
    | fzf --height 40% --reverse --prompt 'env > ' \
          --header 'enter=select  esc=cancel' \
          --preview "cat '$collection/environments/{}.bru'" \
          --preview-window 'right:55%:wrap'
}
```

- [ ] **Step 3: Port `bruSetEnvVar` and `bruWithEnvLock`**

Both (`lib/bru-run.zsh:438-508`) have no zsh-isms beyond function declaration syntax and `${current## }`/`${current%% }` trimming (already bash-compatible):

```bash
# ---------------------------------------------------------------------------
# Env file writes and locking
# ---------------------------------------------------------------------------

# Write key: value into a Bruno env file's `vars {}` block, replacing any
# existing line for that key.
bruSetEnvVar() {
  local envFile="$1" key="$2" value="$3"
  [[ -z "$value" || "$value" == "null" ]] && return 1

  local line current
  line="$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*:" "$envFile")"

  if [[ -n "$line" ]]; then
    current="${line#*:}"
    current="${current## }"
    current="${current%% }"
    [[ "$current" == "$value" ]] && return 1
  fi

  local tmp="${envFile}.tmp$$"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    {
      if (!done && $0 ~ "^[ \t]*" k "[ \t]*:") {
        match($0, /^[ \t]*/)
        print substr($0, 1, RLENGTH) k ": " v
        done = 1
        next
      }
      if (!done && $0 ~ /^\}/) {
        print "  " k ": " v
        done = 1
      }
      print
    }
  ' "$envFile" > "$tmp" && mv "$tmp" "$envFile" && chmod 600 "$envFile"
  return 0
}

# Run a command while holding a lock on the env file.
#
# bruSetEnvVar reads the whole file, rewrites it and moves it back. Two runs
# at the same time — two agents, two terminal tabs — both read the old copy
# and the last mv wins, so the other one's values are lost. That is how a
# whole env file ends up empty.
#
# mkdir is atomic on every filesystem here, so it works as the lock. A lock
# older than 30 seconds is left over from a run that died, and gets removed.
bruWithEnvLock() {
  local envFile="$1"
  shift
  local lock="${envFile}.lock"
  local waited=0

  while ! mkdir "$lock" 2>/dev/null; do
    if [[ -d "$lock" ]] && [[ -z "$(find "$lock" -maxdepth 0 -mmin -0.5 2>/dev/null)" ]]; then
      rmdir "$lock" 2>/dev/null
      continue
    fi
    sleep 0.1
    (( waited += 1 ))
    if (( waited > 100 )); then
      echo "👩‍💻 env file is busy, skipped saving variables" >&2
      return 1
    fi
  done

  "$@"
  local rc=$?
  rmdir "$lock" 2>/dev/null
  return $rc
}
```

- [ ] **Step 4: Port `bruLoadChainedVarsFile` and `bruCaptureVars` — the associative-array use site**

This is the one place the spec calls out for extra attention. zsh original (`lib/bru-run.zsh:514-589`) uses `local -A map=()`, `map[$key]="$expr"`, `${(@k)map}` (keys), `${(f)"$(...)"}` (line split), `${(kv)map[@]}` (key-value pairs), `${(j:, :)saved}` (join), `${envFile:t:r}` (basename without extension):

```bash
# Read a chained-vars map file into an associative array. One pair per line:
# the variable name, a run of whitespace, then the jq expression. Blank lines
# and `#` comments are skipped. The expression keeps every space inside it, so
# only the first whitespace run counts as the separator.
bruLoadChainedVarsFile() {
  local mapFile="$1"
  local -A map=()
  local line key expr

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line#"${line%%[![:space:]]*}"}" == '#'* ]] && continue

    key="${line%%[[:space:]]*}"
    expr="${line#"$key"}"
    expr="${expr#"${expr%%[![:space:]]*}"}"
    [[ -z "$key" || -z "$expr" ]] && continue

    map[$key]="$expr"
  done < "$mapFile"

  local k
  for k in "${!map[@]}"; do
    printf '%s\n' "$k"$'\t'"${map[$k]}"
  done
}

# Pull chained variables out of a --output json and persist them to the env
# file. Chaining is specific to one API's response shapes, so bru-run carries
# no built-in map of its own — a project supplies {envVarName: jq expression}
# in one of two ways:
#
#   1. `chained_vars: <path>` in .bru-run.yml, which bin/bru-run resolves and
#      passes in as $3. This is the path the CLI uses.
#   2. BRU_RUN_CHAINED_VARS, an associative array set in the calling shell.
#      This only works when lib/bru-run.sh is sourced into that same shell:
#      the CLI's own bin/bru-run process cannot see a caller's shell
#      variables at all, associative array or not — this path only ever
#      worked for callers that `source lib/bru-run.sh` directly.
#
# The file wins when both are present. With neither, this is a no-op.
bruCaptureVars() {
  local out="$1" envFile="$2" mapFile="$3"

  local -A map=()
  local pair
  if [[ -n "$mapFile" && -f "$mapFile" ]]; then
    while IFS= read -r pair; do
      [[ -z "$pair" ]] && continue
      map["${pair%%$'\t'*}"]="${pair#*$'\t'}"
    done < <(bruLoadChainedVarsFile "$mapFile")
  else
    local k
    for k in "${!BRU_RUN_CHAINED_VARS[@]}"; do
      map[$k]="${BRU_RUN_CHAINED_VARS[$k]}"
    done
  fi

  (( ${#map[@]} == 0 )) && return 0

  local body key expr value
  local saved=()

  body="$(jq -c '.[0].results[-1].response.data' "$out" 2>/dev/null)"
  [[ -z "$body" || "$body" == "null" ]] && return 0

  for key in "${!map[@]}"; do
    expr="${map[$key]}"
    value="$(jq -r "$expr // empty" <<< "$body" 2>/dev/null | head -1)"
    [[ -z "$value" || "$value" == "null" ]] && continue
    bruSetEnvVar "$envFile" "$key" "$value" && saved+=("$key")
  done

  if (( ${#saved[@]} )); then
    local envBase="${envFile##*/}"
    envBase="${envBase%.*}"
    local savedJoined
    savedJoined="$(IFS=', '; echo "${saved[*]}")"
    echo "👩‍💻 saved to env '${envBase}': ${savedJoined}"
  fi
  return 0
}
```

Two things changed from a literal transliteration, both worth flagging in the implementer's self-review:
1. `for key expr in "${(kv)map[@]}"` (zsh, iterates key/value pairs in one loop) has no bash equivalent — bash's `${!map[@]}` only gives keys, so the port iterates keys and looks up `map[$key]` inside the loop. Same result, one extra lookup per iteration.
2. `${(j:, :)saved}` joins with `", "` (comma-space) — note this differs from `bruReadProtectedEnvs`'s join, which uses bare `,`. The port above uses `IFS=', '` — but `IFS` only ever uses its *first character* as a join separator in `"${array[*]}"`, so `IFS=', '` joins with `,` alone, not `, `. Use this instead to preserve the comma-space exactly: `savedJoined="$(local IFS=', '; printf '%s' "${saved[*]}")"` does NOT fix it either (same first-char rule). The correct fix: build the string with a manual loop or `printf` and `sed`:
   ```bash
   savedJoined="$(printf '%s, ' "${saved[@]}")"
   savedJoined="${savedJoined%, }"
   ```
   Use this version in the actual file, not the `IFS=', '` version shown first above — Step 4's code block above should be written with this corrected join. (This note exists because it's an easy transliteration trap; the implementer should use the corrected `printf`-based join, not the `IFS=', '` one.)

- [ ] **Step 5: Manual test — env writes and chained vars**

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/refactor-4-bru-run-bash-port
cat examples/pompom-time/bruno/chained-vars.tsv
bash -c '
  source lib/bru-run.sh
  bruLoadChainedVarsFile examples/pompom-time/bruno/chained-vars.tsv
'
```

Expected: each non-comment, non-blank line of `chained-vars.tsv` printed back as `key<TAB>expr`, one per line, in some order (associative array iteration order is not guaranteed identical to file order in either zsh or bash — this is fine, matches existing behavior).

Also test the registry functions deferred from Task 1:
```bash
bash -c '
  source lib/bru-run.sh
  cd examples/pompom-time
  bruRegisterProject "test-namespace" "$PWD/.bru-run.yml"
  bruLookupProject "test-namespace"
'
```
Expected: prints the absolute path to `examples/pompom-time/.bru-run.yml`. Clean up afterward: `rm -f ~/.config/bru-run/projects.yml` if this polluted the real registry, or better, run this test with `BRU_RUN_CONFIG_DIR` pointed at a scratch dir:
```bash
bash -c '
  export BRU_RUN_CONFIG_DIR=/tmp/bru-run-test-config-$$
  source lib/bru-run.sh
  cd examples/pompom-time
  bruRegisterProject "test-namespace" "$PWD/.bru-run.yml"
  bruLookupProject "test-namespace"
  rm -rf "$BRU_RUN_CONFIG_DIR"
'
```

- [ ] **Step 6: Grep diff for moz/app-api, then commit**

```bash
git diff -- lib/bru-run.sh | grep -iE 'moz|app-api'
```

Expected: no output.

```bash
git add lib/bru-run.sh
git commit -m "refactor: port env file writes, locking, chained-vars capture to bash"
```

---

### Task 3: Payload patching (lines 591-767 of the zsh source)

**Files:**
- Modify: `lib/bru-run.sh` (append)

**Interfaces:**
- Consumes: `bruAllSecretKeys` (Task 2).
- Produces: `bruPatchBody(collection, body, pair...) -> stdout patched-body`, `bruBlockDepthAwkFunc` (a string variable holding an awk function body, not a shell function — used by both `bruExtractBlock` and `bruTempRequest` in this task), `bruExtractBlock(file, blockName) -> stdout lines|exit 1`, `bruTempRequest(collection, request, newBody) -> stdout relative-path`. Used by Task 4 (`bruResolveRequest` doesn't need these, but Task 5's `bruRun` does).

- [ ] **Step 1: Port `bruPatchBody`**

zsh original (`lib/bru-run.zsh:606-668`) uses `${(f)"$(...)"}`, a bash-unsafe local named `path` (the comment explains why — zsh ties `path` to `$PATH`; **this constraint does not apply to bash**, bash has no such tie, but keep the renamed variable anyway for readability/consistency, don't reintroduce `path` gratuitously), `${(s:.:)jqPath#.}` (split), `${key:l}` (lowercase), and `${secretKeys[(Ie)${key##*.}]}` (array membership test):

```bash
# ---------------------------------------------------------------------------
# Payload patching
# ---------------------------------------------------------------------------

# Build a jq filter from --set key=value pairs and apply it to a JSON body.
#
# Paths are relative to params.data (`coupon.id` -> params.data.coupon.id),
# because that is where a JSON-RPC action typically keeps its arguments. A
# leading `$.` addresses the document root instead (`$.params.auth.session_id`).
# Requests without a params.data resolve short paths against the root, so
# nothing invents a `data` object.
#
# Values are parsed as JSON when they are valid JSON scalars: 5 -> number,
# true -> boolean, null -> null. Anything else is a string. Quote a value to
# force a string: id='"5"'.
bruPatchBody() {
  local collection="$1" body="$2"
  shift 2

  local secretKeys
  mapfile -t secretKeys < <(bruAllSecretKeys "$collection")

  local base='.params.data'
  if [[ "$(jq -r 'try (.params.data | type) catch "missing"' <<< "$body")" != "object" ]]; then
    base=''
  fi

  local pair key rawValue jqPath jqValue
  for pair in "$@"; do
    if [[ "$pair" != *=* ]]; then
      echo "👩‍💻 --set needs key=value, got: $pair" >&2
      return 1
    fi

    key="${pair%%=*}"
    rawValue="${pair#*=}"

    if [[ "$key" == '$.'* ]]; then
      jqPath=".${key#\$.}"
    elif [[ -n "$base" ]]; then
      jqPath="${base}.${key}"
    else
      jqPath=".${key}"
    fi

    if jq -e 'type == "number" or type == "boolean" or type == "null" or type == "object" or type == "array"' <<< "$rawValue" >/dev/null 2>&1; then
      jqValue="$rawValue"
    else
      jqValue="$(jq -Rn --args '$ARGS.positional[0]' -- "$rawValue")"
    fi

    local jqPathParts
    local jqPathStripped="${jqPath#.}"
    IFS='.' read -ra jqPathParts <<< "$jqPathStripped"
    body="$(jq --argjson val "$jqValue" --args 'setpath($ARGS.positional; $val)' -- "${jqPathParts[@]}" <<< "$body" 2>/dev/null)" || {
      echo "👩‍💻 could not set '$key' (bad path?)" >&2
      return 1
    }

    local keyLower="${key,,}"
    local keyTail="${key##*.}"
    local isSecret=0
    if [[ "$keyLower" == *password* || "$keyLower" == *passwd* || "$keyLower" == *secret* \
       || "$keyLower" == *token* || "$keyLower" == *api_key* || "$keyLower" == *apikey* \
       || "$keyLower" == *session_id* ]]; then
      isSecret=1
    else
      local sk
      for sk in "${secretKeys[@]}"; do
        [[ "$sk" == "$keyTail" ]] && { isSecret=1; break; }
      done
    fi

    if (( isSecret )); then
      echo "👩‍💻 set ${jqPath#.} = <hidden>" >&2
    else
      echo "👩‍💻 set ${jqPath#.} = $jqValue" >&2
    fi
  done

  printf '%s\n' "$body"
}
```

Note: the zsh `(#i)*(password|passwd|secret|token|api_key|apikey|session_id)*` single case-insensitive glob-alternation became an explicit `||`-chained `[[ ]]` over a lowercased key — same set of matches, no `shopt -s nocasematch` needed since the lowering happens explicitly first.

- [ ] **Step 2: Port `bruBlockDepthAwkFunc`, `bruExtractBlock`, `bruTempRequest`**

`bruBlockDepthAwkFunc` (`lib/bru-run.zsh:675-693`) is a `typeset -g -r` string holding raw awk source — this is not zsh syntax at all (it's a shell string containing an awk program), so it ports with only the declaration changed. `bruExtractBlock`/`bruTempRequest` (`lib/bru-run.zsh:709-767`) use `${request:t:r}` (basename without extension):

```bash
# Shared awk function: how deep is brace nesting after scanning one line,
# not counting braces inside a quoted JSON string (e.g. "note": "wrap {this}
# value"). Used by both bruExtractBlock (read-only) and bruTempRequest
# (rewrite) so the string-awareness only has to be gotten right once — a
# naive gsub-count of every { and } was the bug fixed in #7/#5.
declare -r bruBlockDepthAwkFunc='
  function depthAfterLine(s,    i, c, prev) {
    inStr = 0
    prev = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (inStr) {
        if (c == "\"" && prev != "\\") inStr = 0
        prev = (c == "\\" && prev == "\\") ? "" : c
        continue
      }
      if (c == "\"") { inStr = 1; prev = ""; continue }
      if (c == "{") depth++
      else if (c == "}") depth--
    }
  }
'

# Print the inner lines of a `<blockName> { ... }` block from a .bru file —
# the block's own indentation stripped, closing brace excluded. Prints
# nothing (and fails) when the block isn't found. Read-only: never touches
# the file.
#
# Only the indent level the block's first content line has is removed from
# every inner line — not every leading whitespace character, and not the
# open line's own indent (a `docs {` at column 0 tells us nothing about how
# far in its content is indented; the standard .bru style indents block
# content 2 spaces regardless of the block-open line's own column). A
# blanket strip would flatten any indentation an author wrote on purpose
# inside the block (a nested list, an indented example) — the bug this
# replaced: the old bruDocs stripped a hardcoded 2 spaces, preserving
# anything past that; a naive `sed 's/^[ \t]*//'` strips everything.
bruExtractBlock() {
  local file="$1" blockName="$2"
  [[ -f "$file" ]] || return 1

  awk -v blockName="$blockName" "$bruBlockDepthAwkFunc"'
    BEGIN { inBlock = 0; depth = 0; baseIndent = -1 }
    !inBlock && $0 ~ ("^[ \t]*" blockName "[ \t]*\\{") { inBlock = 1; depth = 1; next }
    inBlock {
      depthAfterLine($0)
      if (depth <= 0) { inBlock = 0; next }
      if (baseIndent < 0 && $0 !~ /^[ \t]*$/) {
        match($0, /^[ \t]*/)
        baseIndent = RLENGTH
      }
      if (baseIndent >= 0 && $0 ~ ("^[ \t]{" baseIndent "}")) {
        print substr($0, baseIndent + 1)
      } else {
        print
      }
    }
  ' "$file"
}

# Rewrite a request's body:json block into a temp .bru inside the collection,
# so relative paths and collection-level scripts keep working. Prints its path.
bruTempRequest() {
  local collection="$1" request="$2" newBody="$3"

  local dir="$collection/.bru-cli-tmp"
  mkdir -p "$dir" || return 1
  local requestBase="${request##*/}"
  requestBase="${requestBase%.*}"
  local tmp="$dir/${requestBase}-$$.bru"

  local bodyFile="$dir/body-$$.json"
  printf '%s\n' "$newBody" > "$bodyFile" || return 1

  awk -v bodyFile="$bodyFile" "$bruBlockDepthAwkFunc"'
    BEGIN { inBody = 0; depth = 0 }
    !inBody && /^[ \t]*body:json[ \t]*\{/ {
      print "body:json {"
      while ((getline line < bodyFile) > 0) print "  " line
      close(bodyFile)
      inBody = 1
      depth = 1
      next
    }
    inBody {
      depthAfterLine($0)
      if (depth <= 0) { print "}"; inBody = 0 }
      next
    }
    { print }
  ' "$collection/$request" > "$tmp" || { rm -f "$bodyFile"; return 1; }

  rm -f "$bodyFile"

  printf '%s\n' "${tmp#$collection/}"
}
```

- [ ] **Step 3: Manual test — payload patching**

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/refactor-4-bru-run-bash-port
cat examples/pompom-time/bruno/requests/create.bru
bash -c '
  source lib/bru-run.sh
  body="$(bruExtractBlock examples/pompom-time/bruno/requests/create.bru body:json)"
  echo "extracted body:"
  echo "$body"
  echo "---"
  bruPatchBody examples/pompom-time examples/pompom-time/bruno/requests/create.bru "$body" 2>&1
'
```

Compare against running the identical commands with the current zsh version (`git show main:lib/bru-run.zsh` piped to a temp file and sourced with `zsh`, or just check out `main` in a second terminal) — the extracted body and the patched output should be byte-identical.

Also test the secret-masking path specifically, since that's the branch most likely to have a subtle regex bug from the `(#i)` port:
```bash
bash -c '
  source lib/bru-run.sh
  body="$(bruExtractBlock examples/pompom-time/bruno/requests/create.bru body:json)"
  bruPatchBody examples/pompom-time examples/pompom-time/bruno/requests/create.bru "$body" "apiToken=abc123" 2>&1 >/dev/null
'
```
Expected: stderr shows `👩‍💻 set apiToken = <hidden>` (or similar path), not the literal value `abc123` — confirms the case-insensitive "token" substring match still masks correctly.

- [ ] **Step 4: Grep diff for moz/app-api, then commit**

```bash
git diff -- lib/bru-run.sh | grep -iE 'moz|app-api'
```

Expected: no output.

```bash
git add lib/bru-run.sh
git commit -m "refactor: port payload patching to bash"
```

---

### Task 4: Request discovery and search (lines 769-824 of the zsh source)

**Files:**
- Modify: `lib/bru-run.sh` (append)

**Interfaces:**
- Consumes: `bruListRequests` (Task 2).
- Produces: `bruResolveRequest(collection, term...) -> stdout path|exit 1`. Used by Task 5 (`bruRun`) and `bruDocs` (Task 6).

- [ ] **Step 1: Port `bruResolveRequest`**

This is the other trickiest function — zsh original (`lib/bru-run.zsh:781-824`) uses `setopt local_options extended_glob`, `${(f)"$(...)"}`, 1-indexed `${matches[1]}`, `${(M)matches:#(#i)*$term*}` (case-insensitive glob-filter, the array-narrowing loop), and `${(M)all:#(#i)*$1*}`:

```bash
# ---------------------------------------------------------------------------
# Request discovery
# ---------------------------------------------------------------------------

# Resolve search terms to a request path. Every term must appear in the path
# (case-insensitive, any order), so `session lookup` finds requests/session/lookup.bru.
#
# One match  -> print it.
# Several    -> with a terminal, narrow them down in fzf; without one (an agent,
#               a script, a pipe) fzf would hang waiting on keystrokes, so print
#               the candidates to stderr and fail instead.
# None       -> print the closest paths by the first term.
bruResolveRequest() {
  local collection="$1"
  shift

  local all matches near
  mapfile -t all < <(bruListRequests "$collection")
  matches=("${all[@]}")

  local term item filtered
  shopt -s nocasematch
  for term in "$@"; do
    filtered=()
    for item in "${matches[@]}"; do
      [[ "$item" == *"$term"* ]] && filtered+=("$item")
    done
    matches=("${filtered[@]}")
  done

  if (( ${#matches[@]} == 1 )); then
    shopt -u nocasematch
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if (( ${#matches[@]} == 0 )); then
    shopt -u nocasematch
    echo "👩‍💻 no request matches: $*" >&2
    near=()
    for item in "${all[@]}"; do
      shopt -s nocasematch
      [[ "$item" == *"$1"* ]] && near+=("$item")
      shopt -u nocasematch
    done
    if (( ${#near[@]} )); then
      echo "👩‍💻 closest to '$1':" >&2
      printf '  %s\n' "${near[@]}" >&2
    fi
    return 1
  fi
  shopt -u nocasematch

  if [[ -t 0 ]] && command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "${matches[@]}" \
      | fzf --height 60% --reverse --prompt 'request > ' \
            --header "enter=select  esc=cancel  (${#matches[@]} match '$*')" \
            --preview "sed -n '1,60p' '$collection/{}'" \
            --preview-window 'right:55%:wrap'
    return $?
  fi

  echo "👩‍💻 '$*' matches ${#matches[@]} requests — narrow it down:" >&2
  printf '  %s\n' "${matches[@]}" >&2
  return 1
}
```

Note: `shopt -s nocasematch` affects `[[ ]]` pattern matching for the whole shell, not just the current function — every path through this function that returns or continues must pair each `-s` with a `-u` before returning, which is why the port re-enables/disables it around each loop rather than once at the top. This is a real behavior difference from zsh's `setopt local_options` (which is automatically function-scoped) worth flagging to the task reviewer as intentional, not an oversight.

- [ ] **Step 2: Manual test — request resolution**

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/refactor-4-bru-run-bash-port
bash -c '
  source lib/bru-run.sh
  bruResolveRequest examples/pompom-time/bruno CREATE
  echo "exit: $?"
'
```

Expected: matches `requests/create.bru` case-insensitively despite uppercase search term, prints its path, exit 0.

```bash
bash -c '
  source lib/bru-run.sh
  bruResolveRequest examples/pompom-time/bruno nonexistent
  echo "exit: $?"
'
```

Expected: stderr `👩‍💻 no request matches: nonexistent`, exit 1, no crash from the `nocasematch` toggling.

- [ ] **Step 3: Grep diff for moz/app-api, then commit**

```bash
git diff -- lib/bru-run.sh | grep -iE 'moz|app-api'
```

Expected: no output.

```bash
git add lib/bru-run.sh
git commit -m "refactor: port request search/discovery to bash"
```

---

### Task 5: Main run function and discovery commands (lines 826-1156 of the zsh source)

**Files:**
- Modify: `lib/bru-run.sh` (append — this completes the file)

**Interfaces:**
- Consumes: everything from Tasks 1-4 (`bruListEnvNames`, `bruList`/`bruDocs` internally, `bruResolveRequest`, `bruPickRequest`, `bruPickEnv`, `bruExtractBlock`, `bruAllSecretKeys` via `bruPatchBody`, `bruTempRequest`, `bruWithEnvLock`, `bruCaptureVars`).
- Produces: `bruRun(collection, envHelper, protectedEnvsCsv, chainedVarsFile, arg...)`, `bruList(collection, term...)`, `bruDocs(collection, arg...)`. These three are what `bin/bru-run` (Task 6) calls directly.

- [ ] **Step 1: Port `bruRun`**

The largest function — zsh original (`lib/bru-run.zsh:830-1067`) uses `local -a bruArgs=() sets=()`, 1-indexed `${terms[1]}`, `${protectedEnvs[(Ie)$env]}` (array membership test, same pattern as Task 3's secretKeys check):

```bash
bruRun() {
  local collection="$1" envHelper="$2" protectedEnvsCsv="$3" chainedVarsFile="$4"
  shift 4

  if [[ ! -f "$collection/bruno.json" ]]; then
    echo "👩‍💻 no bruno.json in $collection" >&2
    return 1
  fi

  if [[ "$1" == "--envs" ]]; then
    echo "👩‍💻 environments in $collection"
    bruListEnvNames "$collection" | sed 's/^/  /'
    return 0
  fi

  if [[ "$1" == "--list" ]]; then
    shift
    bruList "$collection" "$@"
    return $?
  fi

  if [[ "$1" == "--docs" ]]; then
    shift
    bruDocs "$collection" "$@"
    return $?
  fi

  local bruArgs=() sets=()
  local show=0 env="" arg wantEnv=0 wantSet=0 wantData=0 dataJson="" confirm=0
  for arg in "$@"; do
    if (( wantEnv )); then
      env="$arg"
      wantEnv=0
    elif (( wantSet )); then
      sets+=("$arg")
      wantSet=0
    elif (( wantData )); then
      dataJson="$arg"
      wantData=0
    elif [[ "$arg" == "--show" ]]; then
      show=1
    elif [[ "$arg" == "--env" || "$arg" == "--local" ]]; then
      wantEnv=1
    elif [[ "$arg" == "--set" ]]; then
      wantSet=1
    elif [[ "$arg" == "--data" ]]; then
      wantData=1
    elif [[ "$arg" == "--confirm" ]]; then
      confirm=1
    else
      bruArgs+=("$arg")
    fi
  done

  set -- "${bruArgs[@]}"

  local request

  local terms=()
  while [[ -n "$1" && "$1" != -* ]]; do
    terms+=("$1")
    shift
  done
  bruArgs=("$@")

  if (( ${#terms[@]} == 1 )) && [[ -f "$collection/${terms[0]}" ]]; then
    request="${terms[0]}"
  elif (( ${#terms[@]} )); then
    request="$(bruResolveRequest "$collection" "${terms[@]}")" || return 1
    [[ -z "$request" ]] && { echo "👩‍💻 cancelled" >&2; return 1; }
    echo "👩‍💻 matched request: $request"
    show=1
  fi

  if [[ -z "$request" ]]; then
    if ! command -v fzf >/dev/null 2>&1; then
      echo "👩‍💻 fzf not installed — pass a request path, or: brew install fzf" >&2
      return 1
    fi
    request="$(bruPickRequest "$collection")" || return 1
    [[ -z "$request" ]] && { echo "👩‍💻 cancelled" >&2; return 1; }
    show=1
  fi

  if [[ ! -f "$collection/$request" ]]; then
    echo "👩‍💻 request not found: $request" >&2
    return 1
  fi

  local tmpRequest=""
  if (( ${#sets[@]} )) || [[ -n "$dataJson" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "👩‍💻 --set/--data need jq — brew install jq" >&2
      return 1
    fi

    [[ -d "$collection/.bru-cli-tmp" ]] && \
      find "$collection/.bru-cli-tmp" -maxdepth 1 -type f -delete 2>/dev/null

    local body
    body="$(bruExtractBlock "$collection/$request" body:json)"
    if [[ -z "${body//[[:space:]]/}" ]]; then
      echo "👩‍💻 no body:json block in $request" >&2
      return 1
    fi

    local guidToken="__BRU_TMPL_GUID__"
    local guidLiteral='{{$guid}}'
    body="${body//$guidLiteral/$guidToken}"

    if ! jq -e . <<< "$body" >/dev/null 2>&1; then
      echo "👩‍💻 body:json in $request is not valid JSON — cannot patch" >&2
      return 1
    fi

    if [[ -n "$dataJson" ]]; then
      body="$(jq --argjson patch "$dataJson" \
                 'if (.params.data | type) == "object"
                  then .params.data *= $patch
                  else . *= $patch end' <<< "$body")" || {
        echo "👩‍💻 --data is not valid JSON" >&2
        return 1
      }
      echo "👩‍💻 merged --data into params.data" >&2
    fi

    if (( ${#sets[@]} )); then
      body="$(bruPatchBody "$collection" "$body" "${sets[@]}")" || return 1
    fi

    body="${body//$guidToken/$guidLiteral}"

    tmpRequest="$(bruTempRequest "$collection" "$request" "$body")" || {
      echo "👩‍💻 could not build patched request" >&2
      return 1
    }
    request="$tmpRequest"
    show=1
  fi

  if [[ -z "$env" ]]; then
    if command -v fzf >/dev/null 2>&1; then
      env="$(bruPickEnv "$collection")" || return 1
      [[ -z "$env" ]] && { echo "👩‍💻 cancelled" >&2; return 1; }
    fi
  fi

  if [[ -n "$env" && -n "$protectedEnvsCsv" ]]; then
    local protectedEnvs
    IFS=',' read -ra protectedEnvs <<< "$protectedEnvsCsv"
    local isProtected=0 pe
    for pe in "${protectedEnvs[@]}"; do
      [[ "$pe" == "$env" ]] && { isProtected=1; break; }
    done
    if (( isProtected )) && (( ! confirm )); then
      echo "👩‍💻 '$env' is a protected environment — pass --confirm to run against it" >&2
      return 1
    fi
  fi

  local envFile=""
  if [[ -n "$env" ]]; then
    envFile="$envHelper/$env.bru"
    if [[ -f "$envFile" ]]; then
      echo "👩‍💻 using project env: $env ($envFile)"
      bruArgs+=(--env-file "$envFile")
    elif [[ -f "$collection/environments/$env.bru" ]]; then
      echo "👩‍💻 using collection env: $env (secrets will be empty)"
      bruArgs+=(--env "$env")
      envFile=""
    else
      bruEnsureEnvFile "$collection" "$envHelper" "$env"
      return 1
    fi
  fi

  echo "👩‍💻 bru run $request ${bruArgs[*]}"

  local outBase out exitCode
  outBase="$(mktemp -t bru-response)"
  out="${outBase}.json"
  rm -f "$outBase"

  exitCode=0
  ( cd "$collection" && bru run "$request" "${bruArgs[@]}" --output "$out" ) || exitCode=$?

  if [[ -s "$out" ]] && command -v jq >/dev/null 2>&1; then
    [[ -n "$envFile" && -f "$envFile" ]] && \
      bruWithEnvLock "$envFile" bruCaptureVars "$out" "$envFile" "$chainedVarsFile"

    if (( show )); then
      echo
      echo "👩‍💻 response body"
      jq '.[0].results[-1].response.data' "$out"
    fi
  elif (( show )) && [[ -s "$out" ]]; then
    echo
    echo "👩‍💻 response body"
    cat "$out"
  fi

  rm -f "$out"
  [[ -n "$tmpRequest" ]] && rm -f "$collection/$tmpRequest"
  return $exitCode
}
```

Note the two 1-indexed → 0-indexed fixes that are easy to miss: `${terms[1]}` → `${terms[0]}` (single-term exact-path check) and `${matches[1]}` was already handled in Task 4. Flag both explicitly to the reviewer as deliberate index-base fixes, not typos.

- [ ] **Step 2: Port `bruList` and `bruDocs`**

`bruList` (`lib/bru-run.zsh:1079-1126`) uses `setopt local_options extended_glob`, `${(f)"$(...)"}`, `(#i)*$term*` glob matching, `${(o)rows[@]}` (sorted array expansion). `bruDocs` (`lib/bru-run.zsh:1130-1156`) has no zsh-isms beyond declaration syntax:

```bash
# ---------------------------------------------------------------------------
# Discovery helpers
# ---------------------------------------------------------------------------

# List every request as "json-rpc method  ->  path". Optional terms filter the
# list the same way bruResolveRequest does: every term must appear in the path
# or in the method, any order, case insensitive.
#
# This exists so an agent can ask the collection what it holds with one command,
# instead of a find plus a grep over every file.
bruList() {
  local collection="$1"
  shift

  local rows=()
  local f method width=0
  local files
  mapfile -t files < <(bruListRequests "$collection")

  local term keep
  for f in "${files[@]}"; do
    [[ -z "$f" ]] && continue
    method="$(grep -m1 -E '"method"[[:space:]]*:' "$collection/$f" \
              | sed -E 's/.*"method"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"

    if [[ -z "$method" ]]; then
      method="$(grep -m1 -E '^(get|post|put|patch|delete|head|options)[[:space:]]*\{' \
                "$collection/$f" | sed -E 's/[[:space:]]*\{.*//' | tr 'a-z' 'A-Z')"
      [[ -z "$method" ]] && method="?"
    fi

    keep=1
    shopt -s nocasematch
    for term in "$@"; do
      if [[ "$f" != *"$term"* && "$method" != *"$term"* ]]; then
        keep=0
        break
      fi
    done
    shopt -u nocasematch
    (( keep )) || continue

    (( ${#method} > width )) && width=${#method}
    rows+=("$method|$f")
  done

  if (( ! ${#rows[@]} )); then
    echo "👩‍💻 no request matches: $*" >&2
    return 1
  fi

  echo "👩‍💻 ${#rows[@]} requests in $collection"
  local row
  while IFS= read -r row; do
    printf '  %-*s  %s\n' "$width" "${row%%|*}" "${row#*|}"
  done < <(printf '%s\n' "${rows[@]}" | sort)
}

# Print the docs block of one request. Takes a path or search terms, same as a
# normal run. Reads the file only — nothing is sent anywhere.
bruDocs() {
  local collection="$1"
  shift

  if (( ! $# )); then
    echo "👩‍💻 --docs needs a request path or search terms" >&2
    return 1
  fi

  local request
  if (( $# == 1 )) && [[ -f "$collection/$1" ]]; then
    request="$1"
  else
    request="$(bruResolveRequest "$collection" "$@")" || return 1
    [[ -z "$request" ]] && { echo "👩‍💻 cancelled" >&2; return 1; }
  fi

  echo "👩‍💻 $request"

  local method
  method="$(grep -m1 -E '"method"[[:space:]]*:' "$collection/$request" \
            | sed -E 's/.*"method"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  [[ -n "$method" ]] && echo "👩‍💻 method: $method"
  echo

  bruExtractBlock "$collection/$request" docs
}
```

Note: `${(o)rows[@]}` (zsh's in-place sorted array expansion) became a `sort` piped through the loop, since bash has no array-expansion-time sort — the ordering only matters for display, and `sort` on `"method|path"` strings sorts by method first (matching the zsh `(o)` default ascending-string-sort behavior), which is the same output order the original produces.

- [ ] **Step 3: Manual test — full engine, no `bru` binary required**

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/refactor-4-bru-run-bash-port
bash -c '
  source lib/bru-run.sh
  bruList examples/pompom-time/bruno
  echo "==="
  bruDocs examples/pompom-time/bruno create
  echo "==="
  bruRun examples/pompom-time/bruno "$HOME/.bru-run/pompom-time" "" "" --envs
'
```

Compare against the same three commands run through the current `main` branch's `zsh bin/bru-run` from inside `examples/pompom-time` (`../../bin/bru-run --list`, `../../bin/bru-run --docs create`, `../../bin/bru-run --envs`) — output should match line for line except any path differences from running via `source` directly vs. the real entrypoint.

If `bru` (the real Bruno CLI) is installed, also test a full run:
```bash
bash -c '
  source lib/bru-run.sh
  bruRun examples/pompom-time/bruno "$HOME/.bru-run/pompom-time" "" "" list --env dev --show
'
```

- [ ] **Step 4: Grep diff for moz/app-api, then commit**

```bash
git diff -- lib/bru-run.sh | grep -iE 'moz|app-api'
```

Expected: no output.

```bash
git add lib/bru-run.sh
git commit -m "refactor: port main run function and discovery commands to bash"
```

---

### Task 6: bin/bru-run, version guard, delete lib/bru-run.zsh, documentation

**Files:**
- Modify: `bin/bru-run`
- Delete: `lib/bru-run.zsh`
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `bruResolveProject`, `bruFieldsOf`, `bruRun` (all from Tasks 1-5, now complete in `lib/bru-run.sh`).
- Produces: nothing further — this is the final task.

- [ ] **Step 1: Rewrite `bin/bru-run`**

Current file uses `#!/usr/bin/env zsh`, `${0:A:h}`, and `local -a names=()` inside the `init` block's array-building loop. Full replacement:

```bash
#!/usr/bin/env bash
#
# bru-run — run Bruno collection requests from any project.
#
# See lib/bru-run.sh for the full flag reference. This entrypoint only
# resolves which project to run against, then hands off to bruRun.

set -e

if (( BASH_VERSINFO[0] < 4 )); then
  echo "👩‍💻 bru-run needs bash 4.0+ (found ${BASH_VERSION})." >&2
  echo "👩‍💻 macOS ships bash 3.2 by default — install a newer one with:" >&2
  echo "👩‍💻   brew install bash" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/bru-run.sh"

# `bru-run --help` / `-h` — print usage and exit. Checked before init and
# before any project resolution, so it works with no .bru-run.yml present.
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  cat <<'EOF'
bru-run — run Bruno collection requests from any project

USAGE
  bru-run <request> [--env <name>] [--show] [--confirm]
  bru-run --list | --docs <request> | --envs
  bru-run --set key=value [--set key2=value2 ...] <request> ...
  bru-run --data '{"...json..."}' <request> ...
  bru-run --project <namespace> [--branch <name>] <request> ...
  bru-run init

DISCOVERY
  --list                list all requests in the collection
  --docs <request>      show a request's docs block
  --envs                list environment names

RUN
  --env <name>          environment to run against
  --show                print the response body
  --confirm              required to run a protected env (see protected_envs)

EDIT THE PAYLOAD (before sending — never touches the saved .bru file)
  --set key=value        change one field; key is a path into params.data
                          ("$.foo" addresses the document root), repeatable
  --data '{"a":1}'       merge a whole JSON object into params.data

CROSS-PROJECT
  --project <namespace>  run against another project's collection
  --branch <name>        use that git worktree's own .bru-run.yml

SETUP
  init                    write a .bru-run.yml in the current directory

More: README.md, skill/SKILL.md
EOF
  exit 0
fi

# `bru-run init` — write a .bru-run.yml in the current directory.
if [[ "$1" == "init" ]]; then
  if [[ -f "$PWD/.bru-run.yml" ]]; then
    echo "👩‍💻 .bru-run.yml already exists here" >&2
    exit 1
  fi

  echo -n "namespace: "
  read -r namespace
  if [[ -z "$namespace" ]]; then
    echo "👩‍💻 namespace can't be empty" >&2
    exit 1
  fi

  echo -n "collection path (relative to this directory) [./bruno]: "
  read -r collection
  collection="${collection:-./bruno}"

  echo -n "protected environments, comma-separated, e.g. prod (leave empty for none): "
  read -r protectedEnvsInput

  {
    echo "namespace: $namespace"
    echo "collection: $collection"
    echo "env_helper: ~/.bru-run/$namespace"
    if [[ -n "$protectedEnvsInput" ]]; then
      names=()
      IFS=',' read -ra names <<< "$protectedEnvsInput"
      trimmedNames=()
      for n in "${names[@]}"; do
        trimmed="${n## }"
        trimmed="${trimmed%% }"
        [[ -n "$trimmed" ]] && trimmedNames+=("$trimmed")
      done
      joined="$(printf '%s, ' "${trimmedNames[@]}")"
      joined="${joined%, }"
      echo "protected_envs: [${joined}]"
    fi
  } > "$PWD/.bru-run.yml"

  echo "👩‍💻 wrote $PWD/.bru-run.yml"
  exit 0
fi

# --project <name> and --branch <name> both take themselves out of the
# positional args before resolution; everything else passes straight
# through to bruRun.
projectName=""
branchName=""
args=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--project" ]]; then
    projectName="$2"
    shift 2
  elif [[ "$1" == "--branch" ]]; then
    branchName="$2"
    shift 2
  else
    args+=("$1")
    shift
  fi
done

resolved="$(bruResolveProject "$projectName" "$branchName")" || exit 1
bruFieldsOf "$resolved"

bruRun "$collection" "$envHelper" "$protectedEnvs" "$chainedVarsFile" "${args[@]}"
```

Note the `init` block's join uses the same `printf '%s, ' ... | strip trailing`, pattern as Task 2 Step 4's corrected join — for the same reason (`IFS` join only uses the first character, and the original zsh `${(j:, :)trimmedNames}` needs the two-character `, ` separator preserved).

Also note: `(( BASH_VERSINFO[0] < 4 ))` runs before `set -e` would matter here, but this check must be the very first executable line after `set -e` — it exists specifically to fail cleanly on a bash 3.2 system that would otherwise hit a hard parse error the moment it reaches `declare -A` or `${var,,}` syntax later in `lib/bru-run.sh`.

- [ ] **Step 2: Delete `lib/bru-run.zsh`**

```bash
git rm lib/bru-run.zsh
```

- [ ] **Step 3: Update README.md**

Read the current "Requirements" section first:
```bash
sed -n '1,20p' README.md
```

Replace the zsh requirement bullet (the one starting "**zsh** — the CLI is written in zsh...") with:

```markdown
- **bash 4.0+** — the CLI is written in bash, not POSIX `sh`. Linux ships
  bash 4+ by default on essentially every mainstream distro. **macOS does
  not** — Apple has frozen macOS's system bash at 3.2 since 2007 (licensing,
  not neglect), so macOS users need `brew install bash` first. Check your
  version with `bash --version`; anything below 4.0 will fail with a clear
  error pointing back here.
```

Remove the "Removing this dependency is tracked as a follow-up: issue #4" sentence that followed the old zsh bullet — issue #4 is what this PR closes.

- [ ] **Step 4: Update CLAUDE.md**

Replace the entire "## Language: zsh, not bash" section with:

```markdown
## Language: bash 4.0+, not zsh or POSIX sh

`bin/bru-run` and `lib/bru-run.sh` are bash, targeting 4.0+ specifically —
native associative arrays (`declare -A`) are used in exactly one place
(`bruLoadChainedVarsFile`/`bruCaptureVars`, driving `chained_vars`), and
every other function also uses bash 4+ syntax (`${var,,}`, `mapfile`) with
no 3.2-compatible equivalent worth writing for a single call site. Don't
"helpfully" downgrade syntax to run on 3.2 — this was a deliberate choice,
made and documented in
[docs/superpowers/specs/2026-08-26-bru-run-bash-port-design.md](docs/superpowers/specs/2026-08-26-bru-run-bash-port-design.md).

**This has a real cost on macOS.** Apple has shipped bash 3.2 by default
since 2007 (GPLv3 licensing, not neglect) and never updates it. Every macOS
user — whether or not they have zsh — needs `brew install bash` before
`bru-run` will run. `bin/bru-run` checks `BASH_VERSINFO[0]` at startup and
fails with an install hint rather than letting 3.2 hit a confusing parse
error on unfamiliar syntax.

Previously this project used zsh; that dependency was removed in
[issue #4](https://github.com/nathpaiva/bru-run/issues/4) because zsh
doesn't ship by default on most Linux distros. The lesson from that
migration: check what a target platform actually ships before picking a
version floor — this repo has now hit that gap twice, once per shell.
```

- [ ] **Step 5: Manual test — full side-by-side comparison against `main`**

This is the integration checkpoint for the whole port. Run every command below against **both** the new bash version (this branch) and the current zsh version (`main` branch, in a second terminal or by checking it out separately), and confirm matching output:

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/refactor-4-bru-run-bash-port
bash --version | head -1   # confirm 4.0+ is what's actually running this

cd examples/pompom-time
../../bin/bru-run --help
../../bin/bru-run -h
../../bin/bru-run --list
../../bin/bru-run --list create
../../bin/bru-run --docs create
../../bin/bru-run --envs
../../bin/bru-run init   # in a scratch dir, not here — don't overwrite the example's .bru-run.yml
```

For the version guard specifically, simulate bash 3.2 by forcing the check to fail (don't actually need bash 3.2 installed — read the guard code and confirm the condition is correct, or temporarily edit `BASH_VERSINFO[0] < 4` to `< 99` and confirm the error message and exit code, then revert):

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/refactor-4-bru-run-bash-port
sed -i.bak 's/BASH_VERSINFO\[0\] < 4/BASH_VERSINFO[0] < 99/' bin/bru-run
./bin/bru-run --list
echo "exit: $?"
mv bin/bru-run.bak bin/bru-run
```

Expected: the Homebrew install message prints to stderr, exit code 1.

If `bru` is installed, also run a full request against `dev` and confirm the response body prints and `chained_vars` capture writes to the env file (check `~/.bru-run/pompom-time/dev.bru` before/after for any TSV-declared keys changing).

- [ ] **Step 6: Grep diff for moz/app-api across every changed file, then commit**

```bash
git diff -- bin/bru-run README.md CLAUDE.md | grep -iE 'moz|app-api'
```

Expected: no output.

```bash
git add bin/bru-run README.md CLAUDE.md
git rm lib/bru-run.zsh 2>/dev/null || true
git status
git commit -m "refactor: port bin/bru-run to bash, remove zsh engine, update docs"
```

(the `git rm` may already be staged from Step 2 — `git status` before committing confirms exactly what's included; the commit should contain the modified `bin/bru-run`, `README.md`, `CLAUDE.md`, and the deletion of `lib/bru-run.zsh` together)

---

## Self-Review Notes

**Spec coverage:** Single new file replacing `lib/bru-run.zsh` entirely (Tasks 1-5 build it, Task 6 deletes the old one) ✓. `bin/bru-run` shebang + version guard ✓ (Task 6, Step 1). Target bash 4.0+ with associative arrays used only at the `chained_vars` site ✓ (Task 2, Step 4). Homebrew-on-macOS cost documented in README and CLAUDE.md ✓ (Task 6, Steps 3-4). Manual side-by-side testing against `examples/pompom-time`, no automated suite ✓ (every task's test step, consolidated final pass in Task 6 Step 5). Syntax mapping table from the spec is reproduced and extended with entries the spec didn't enumerate but the actual code needed (`${var:h}`, `${var:r}`, `print -r --`, array membership test, 1-vs-0 indexing, `mapfile` empty-input caveat) — these came from reading the real source, not invented. Fallback-to-3.2 "considered, not done" — reflected in Task 2 Step 4's comment and CLAUDE.md's rewrite, not built.

**Placeholder scan:** none — every step has literal code, not descriptions of code.

**Type consistency:** function names and signatures preserved exactly from the zsh source across all tasks (verified against the read-through of `lib/bru-run.zsh` line by line) — `bruRun(collection, envHelper, protectedEnvsCsv, chainedVarsFile, ...)`, `bruFieldsOf(resolved)`, etc. all match what `bin/bru-run` (Task 6) calls. The one intentionally-flagged deviation from a literal port is the `bruCaptureVars`/`bruLoadChainedVarsFile` `(kv)` iteration becoming key-then-lookup (Task 2, Step 4) — same inputs/outputs, different internal mechanism, called out explicitly so a reviewer doesn't mistake it for a bug.

**Known trap flagged for implementers:** the `IFS=', '` join pattern looks correct but silently joins with `,` alone (IFS array-join only uses its first character) — flagged in both Task 2 Step 4 and Task 6 Step 1, with the correct `printf '%s, ' ... | strip trailing ", "` pattern given as the fix in both places.
