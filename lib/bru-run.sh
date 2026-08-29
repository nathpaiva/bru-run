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

# Find a project's main .bru-run.yml: --project <name> forces a registry
# lookup; otherwise walk up from cwd. Warns when the two disagree. Prints
# the config file path — no loading, no registering.
bruFindMainConfig() {
  local projectName="$1"
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

  printf '%s\n' "$mainConfigFile"
}

# Resolve which project to run against. --branch <name> swaps in that
# worktree's own .bru-run.yml instead of the main one — see
# bruResolveWorktreeConfig. Registers the *main* project either way — never
# the worktree's config — so the registry always answers a later --project
# with the main checkout, not whichever worktree was resolved last. Prints
# "namespace\tcollection\tenvHelper\tprotectedEnvs\tchainedVarsFile" on
# success.
bruResolveProject() {
  local projectName="$1" branchName="$2"
  local mainConfigFile

  mainConfigFile="$(bruFindMainConfig "$projectName")" || return 1

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
    # Both paths are already known here, so print the copy command ready to
    # paste instead of only naming the problem. Copying is left to the caller:
    # a run command should not write files into a worktree on its own.
    echo "👩‍💻 no .bru-run.yml at .claude/worktrees/${worktreeSlug}" >&2
    echo "" >&2
    echo "run this to copy it from the main checkout:" >&2
    echo "  cp ${mainConfigFile} \\" >&2
    echo "     ${worktreeConfigFile}" >&2
    return 1
  fi

  printf '%s\n' "$worktreeConfigFile"
}

# List the worktrees a project has, and whether each one can be used with
# --branch. A worktree without its own .bru-run.yml is listed too, marked
# as missing, because that is exactly the one the user needs to fix.
bruListWorktrees() {
  local projectName="$1"
  local mainConfigFile

  mainConfigFile="$(bruFindMainConfig "$projectName")" || return 1

  local mainResolved namespace
  mainResolved="$(bruLoadProjectConfig "$mainConfigFile")" || return 1
  namespace="${mainResolved%%$'\t'*}"
  # Same as a run: seeing a project by walking up from $PWD is what makes
  # it reachable by name later, so --branches has to register it too.
  bruRegisterProject "$namespace" "$mainConfigFile"

  local rootDir="${mainConfigFile%/*}"
  local worktreeDir="$rootDir/.claude/worktrees"

  if [[ ! -d "$worktreeDir" ]]; then
    echo "👩‍💻 no worktrees for $namespace — nothing at $worktreeDir" >&2
    return 1
  fi

  # Widest name first, so the ✓/✗ column lines up.
  local entry name width=0
  local names=()
  for entry in "$worktreeDir"/*/; do
    [[ -d "$entry" ]] || continue
    name="${entry%/}"
    name="${name##*/}"
    names+=("$name")
    (( ${#name} > width )) && width=${#name}
  done

  if (( ${#names[@]} == 0 )); then
    echo "👩‍💻 no worktrees for $namespace — nothing at $worktreeDir" >&2
    return 1
  fi

  echo "👩‍💻 worktrees for $namespace"
  local missing=0
  for name in "${names[@]}"; do
    if [[ -f "$worktreeDir/$name/.bru-run.yml" ]]; then
      printf '  %-*s  ✓ has .bru-run.yml\n' "$width" "$name"
    else
      printf '  %-*s  ✗ missing\n' "$width" "$name"
      missing=1
    fi
  done

  if (( missing )); then
    echo ""
    echo "a worktree marked ✗ needs its own config before --branch can use it:"
    echo "  cp ${mainConfigFile} \\"
    echo "     ${worktreeDir}/<name>/.bru-run.yml"
  fi

  return 0
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

# ---------------------------------------------------------------------------
# Main run function
# ---------------------------------------------------------------------------

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

    # Bruno's own dynamic variables ({{$guid}}, {{$randomInt}}, ...) always
    # start with $ inside the braces — swapped out first and separately so
    # the user-variable swap below (which matches any {{name}}) can never
    # claim one of these. If the user-variable swap ran first on an
    # unswapped {{$guid}}, the $ is outside its character class so {{$guid}}
    # would survive untouched by *that* swap — but running guid first keeps
    # the two swaps independent and easy to reason about, matching the
    # order this code already used before this fix.
    local guidToken="__BRU_TMPL_GUID__"
    local guidLiteral='{{$guid}}'
    body="${body//$guidLiteral/$guidToken}"

    # Bruno writes unquoted template variables for non-string values
    # ("account_id": {{accountId}}), which is valid Bruno syntax and
    # invalid JSON — jq -e . below would reject the body before any patch
    # ever runs, on almost every real request, since template variables are
    # the normal case. bru-run never resolves a variable's value (Bruno
    # does that later via --env-file), so each {{name}} is swapped for a
    # unique numbered token just long enough to pass the JSON check and
    # survive the jq-based patch, then swapped back to its original literal
    # text below. Numbered per occurrence, not per key: the same variable
    # can appear twice, and a variable can be a substring of a larger
    # string ("{{baseUrl}}/home"), so a shared or fixed-value placeholder
    # (e.g. "0") would either mis-restore a repeated variable or collide
    # with a genuine literal already in the body.
    #
    # The token itself must be all-digits, not a __BRU_VAR_N__-style name:
    # an unquoted template variable ("quantity": {{defaultQuantity}}) has
    # no surrounding quotes to swap back in, so the token lands unquoted in
    # the body too — and jq only accepts a bare, unquoted value that looks
    # like a JSON number. A named token there ("quantity": __BRU_VAR_1__)
    # still fails jq -e . with "Invalid numeric literal", which is the
    # exact failure this fix exists to remove. The 9-digit prefix makes the
    # token unlikely to collide with small real numbers already in the
    # body (page numbers, counts) while staying a valid JSON number in
    # both the quoted and unquoted position — but "unlikely" isn't a
    # guarantee, so the loop below extends the token further whenever it
    # does collide with something already in the body.
    local varTokens=() varLiterals=()
    local varMatch varIndex=0
    while IFS= read -r varMatch; do
      [[ -z "$varMatch" ]] && continue
      varIndex=$(( varIndex + 1 ))
      local varToken="90000000${varIndex}1"
      # The 9-digit prefix keeps the token away from small real numbers,
      # but a body can still contain that exact digit run already — a real
      # numeric id, or the same digits inside a longer string. The // in
      # the restore loop below is replace-all, so any such collision would
      # corrupt that literal into a {{var}} placeholder. Extend the token
      # with another leading 9 until it provably doesn't occur anywhere in
      # the body yet.
      while [[ "$body" == *"$varToken"* ]]; do
        varToken="9${varToken}"
      done
      varTokens+=("$varToken")
      varLiterals+=("$varMatch")
      body="${body/"$varMatch"/$varToken}"
    done < <(grep -oE '\{\{[A-Za-z_][^}]*\}\}' <<< "$body")

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

    # Restore in reverse order — required, not stylistic: token(i) can be a
    # literal substring of token(j) whenever i < j shares the same decimal
    # prefix (e.g. token(1)="9000000011" is a substring of
    # token(11)="90000000111"). Restoring low-numbered tokens first would
    # let a later substring match land inside an already-restored
    # higher-numbered token's replacement text, corrupting it. Reverse
    # order (highest first) means once a token is restored, no remaining
    # un-restored token's text can appear inside it.
    local i
    for (( i = ${#varTokens[@]} - 1; i >= 0; i-- )); do
      body="${body//"${varTokens[$i]}"/${varLiterals[$i]}}"
    done

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
