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

# ---------------------------------------------------------------------------
# Chained variables
# ---------------------------------------------------------------------------

# Read a chained-vars map file into stdout. One pair per line:
# the variable name, a tab, then the jq expression. Blank lines
# and `#` comments are skipped. The expression keeps every space inside it, so
# only the first whitespace run counts as the separator.
bruLoadChainedVarsFile() {
  local mapFile="$1"
  local line key expr

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line#"${line%%[![:space:]]*}"}" == '#'* ]] && continue

    key="${line%%[[:space:]]*}"
    expr="${line#"$key"}"
    expr="${expr#"${expr%%[![:space:]]*}"}"
    [[ -z "$key" || -z "$expr" ]] && continue

    printf '%s\n' "$key"$'\t'"$expr"
  done < "$mapFile"
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

  # Build map from either the file or the shell variable
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
    savedJoined="$(printf '%s, ' "${saved[@]}")"
    savedJoined="${savedJoined%, }"
    echo "👩‍💻 saved to env '${envBase}': ${savedJoined}"
  fi
  return 0
}
