#!/usr/bin/env bash
# bru-run engine
#
# `bru` only runs from a collection root, so each helper cd's there in a
# subshell (parentheses) — the caller's current directory is never changed.
#
# Usage (via the bru-run entrypoint in bin/):
#   bru-run                             -> pick request + env with fzf
#   bru-run --env dev                   -> pick request, env already set
#   bru-run <request.bru> --env dev     -> run directly, no prompt
#   bru-run session lookup --env dev    -> search terms instead of a path
#   bru-run <request.bru> --show        -> run directly + print body
#   bru-run --envs                      -> list environments
#   bru-run --project <name> ...        -> resolve project from the global
#                                          registry instead of the cwd
#
# Reading the collection without calling anything:
#   bru-run --list                      -> every request as "method  path"
#   bru-run --list coupon               -> same list, filtered by terms
#   bru-run --docs session lookup       -> the docs block of one request
# Both exist so an agent can ask what a collection holds with one command,
# instead of a find plus a grep over every file.
#
# Payload overrides (the saved .bru is never modified — a patched copy runs):
#   --set coupon.id=affiliate-50        -> paths are relative to params.data
#   --set '$.params.auth.session_id=x'  -> $. addresses the document root
#   --set a.b=1 --set c=true            -> repeatable, any number of keys
#   --data '{"coupon":{"id":"x"}}'      -> merge a JSON object into params.data
# Types follow JSON: 5 is a number, true a boolean, null null, anything else a
# string. Force a string with id='"5"'. Overriding implies --show.
#
# Search terms: every term must appear in the request path, any order, case
# insensitive. One match runs it. Several open fzf pre-filtered — except with
# no terminal attached (agents, scripts, pipes), where fzf would hang, so the
# candidates are listed and the call fails. That is what makes the search
# usable non-interactively without breaking the interactive picker.
#
# Picking a request interactively always prints the response body — asking
# for it by choosing it. --show is only needed when passing a path directly.
#
# --env <name> resolves to <env_helper>/<name>.bru when that file exists, and
# to the collection's own environments/<name>.bru otherwise. The helper file
# wins whenever a collection declares secrets as `vars:secret` — those values
# live outside the versioned collection, in a project's own env_helper
# directory (see bruEnsureEnvFile below). (--local is kept as an alias for
# --env.)
#
# `bru run --verbose` does NOT print the response body (CLI 3.5.2), so the
# body is pulled out of a temp --output json with jq.
#
# A project can list environment names under `protected_envs:` in its own
# .bru-run.yml. Calling one of those with --env needs --confirm as well, or
# bruRun fails before doing anything. This is the only enforcement of
# environment safety in the code — a project with no protected_envs key has
# none.

# ---------------------------------------------------------------------------
# Project + env resolution
# ---------------------------------------------------------------------------

export BRU_RUN_CONFIG_DIR="${BRU_RUN_CONFIG_DIR:-$HOME/.config/bru-run}"
export BRU_RUN_REGISTRY="$BRU_RUN_CONFIG_DIR/projects.yml"
export BRU_RUN_SECRETS_ROOT="${BRU_RUN_SECRETS_ROOT:-$HOME/.bru-run}"

# Escape ERE metacharacters in a string so it can be spliced into a grep -E
# or awk pattern as a literal match. namespace comes from --project or a
# project's own .bru-run.yml — both arbitrary strings, so `.` in a namespace
# like "foo.bar" must not act as "any char" and match "fooxbar" instead.
bruEscapeRegex() {
  local s="$1"
  local metaChars=('\' '^' '$' '.' '[' ']' '|' '(' ')' '*' '+' '?' '{' '}')
  local c
  for c in "${metaChars[@]}"; do
    s="${s//"$c"/\\$c}"
  done
  printf '%s\n' "$s"
}

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

# The tab-delimited field order bruLoadProjectConfig/bruResolveProject print
# in — the single source of truth both bruFieldsOf (below) and any future
# reader has to match. Adding a field means adding it here, in the printf
# above, and nowhere else.
bruResolvedFields=(namespace collection envHelper protectedEnvs chainedVarsFile)

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
    printf -v "$field" '%s' "${values[$i]}"
  done
}

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
