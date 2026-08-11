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
function bruEscapeRegex() {
  local s="$1"
  local -a metaChars=(\\ '^' '$' '.' '[' ']' '|' '(' ')' '*' '+' '?' '{' '}')
  local c
  for c in "${metaChars[@]}"; do
    s="${s//$c/\\$c}"
  done
  print -r -- "$s"
}

# Walk up from $PWD looking for .bru-run.yml, the way git finds .git. Prints
# the absolute path to the file it finds, or nothing if it hits /.
function bruFindProjectConfig() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.bru-run.yml" ]]; then
      print -r -- "$dir/.bru-run.yml"
      return 0
    fi
    dir="${dir:h}"
  done
  return 1
}

# Read one flat top-level key out of a .bru-run.yml. The file's shape is
# fixed and shallow (namespace / collection / env_helper), so a small grep
# does the job without adding a YAML parser dependency.
function bruReadConfigKey() {
  local configFile="$1" key="$2"
  grep -m1 -E "^${key}:" "$configFile" | sed -E "s/^${key}:[[:space:]]*//" | sed -E "s/[[:space:]]+#.*$//"
}

# Read the optional `protected_envs: [a, b]` key — a one-line flow list of
# environment names that need --confirm before bruRun will call them. Prints
# a comma-separated list, or nothing if the key is absent.
function bruReadProtectedEnvs() {
  local configFile="$1"
  local raw
  raw="$(bruReadConfigKey "$configFile" protected_envs)"
  [[ -z "$raw" ]] && return 0

  # strip [ ], split on commas, trim spaces around each name
  raw="${raw#\[}"
  raw="${raw%\]}"
  local -a names
  names=( ${(s:,:)raw} )
  local n trimmed
  local -a trimmedNames=()
  for n in "${names[@]}"; do
    trimmed="${n## }"
    trimmed="${trimmed%% }"
    [[ -n "$trimmed" ]] && trimmedNames+=("$trimmed")
  done
  print -r -- "${(j:,:)trimmedNames}"
}

# Load the keys out of a .bru-run.yml, resolving `collection` and
# `env_helper` relative to the config file's own directory, and expanding a
# leading ~ in env_helper.
function bruLoadProjectConfig() {
  local configFile="$1"
  local base="${configFile:h}"

  local namespace collection envHelper protectedEnvs
  namespace="$(bruReadConfigKey "$configFile" namespace)"
  collection="$(bruReadConfigKey "$configFile" collection)"
  envHelper="$(bruReadConfigKey "$configFile" env_helper)"
  protectedEnvs="$(bruReadProtectedEnvs "$configFile")"

  [[ -z "$namespace" || -z "$collection" ]] && {
    echo "👩‍💻 $configFile is missing namespace or collection" >&2
    return 1
  }

  [[ "$collection" != /* ]] && collection="$base/$collection"
  [[ "$envHelper" == "~"* ]] && envHelper="${envHelper/#\~/$HOME}"
  [[ -z "$envHelper" ]] && envHelper="$BRU_RUN_SECRETS_ROOT/$namespace"

  print -r -- "$namespace"$'\t'"$collection"$'\t'"$envHelper"$'\t'"$protectedEnvs"
}

# Write/update one entry in the global registry so `--project <name>` can
# find this project later, from anywhere. Called every time a .bru-run.yml
# is found by walking up from cwd — no manual registration step.
#
# Locked with bruWithEnvLock: this runs on every invocation, including
# read-only ones, so two bru-run calls at the same time could otherwise both
# read the old file, both write a tmp copy, and one registration is lost.
function bruRegisterProject() {
  local namespace="$1" configFile="$2"
  mkdir -p "$BRU_RUN_CONFIG_DIR"
  touch "$BRU_RUN_REGISTRY"

  local namespacePattern
  namespacePattern="$(bruEscapeRegex "$namespace")"

  bruWithEnvLock "$BRU_RUN_REGISTRY" bruWriteRegistryEntry "$namespace" "$namespacePattern" "$configFile"
}

# Does the actual registry rewrite — split out from bruRegisterProject so it
# can run under bruWithEnvLock (which calls "$@" as a plain command).
function bruWriteRegistryEntry() {
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
function bruLookupProject() {
  local namespace="$1"
  [[ -f "$BRU_RUN_REGISTRY" ]] || return 1
  local namespacePattern
  namespacePattern="$(bruEscapeRegex "$namespace")"
  grep -m1 -E "^${namespacePattern}:" "$BRU_RUN_REGISTRY" | sed -E "s/^${namespacePattern}:[[:space:]]*//"
}

# Resolve which project to run against: --project <name> forces a registry
# lookup; otherwise walk up from cwd. Registers the project on success either
# way. Prints "namespace\tcollection\tenvHelper" on success.
function bruResolveProject() {
  local projectName="$1"
  local configFile

  if [[ -n "$projectName" ]]; then
    configFile="$(bruLookupProject "$projectName")"
    if [[ -z "$configFile" || ! -f "$configFile" ]]; then
      echo "👩‍💻 unknown project '$projectName' — run bru-run from inside it once, or check $BRU_RUN_REGISTRY" >&2
      return 1
    fi

    # cwd resolves to a different project than --project asked for — a stale
    # copy-pasted command with the wrong --project would otherwise silently
    # target the wrong project's collection and secrets with no indication.
    local cwdConfigFile
    cwdConfigFile="$(bruFindProjectConfig)"
    if [[ -n "$cwdConfigFile" && "$cwdConfigFile" != "$configFile" ]]; then
      echo "👩‍💻 warning: --project '$projectName' ($configFile) differs from this directory's own project ($cwdConfigFile)" >&2
    fi
  else
    configFile="$(bruFindProjectConfig)" || {
      echo "👩‍💻 no .bru-run.yml found above $PWD — pass --project <name>, or run 'bru-run init' here" >&2
      return 1
    }
  fi

  local resolved
  resolved="$(bruLoadProjectConfig "$configFile")" || return 1

  local namespace="${resolved%%$'\t'*}"
  bruRegisterProject "$namespace" "$configFile"

  print -r -- "$resolved"
}

# Print the names inside an environment file's vars:secret [ ... ] block, one
# per line — those are the ones whose real value has to live outside the
# versioned collection. Plain vars {} entries already carry a usable value in
# the collection itself.
function bruSecretKeys() {
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
function bruAllSecretKeys() {
  local collection="$1"
  local f
  for f in ${(f)"$( cd "$collection" && find environments -name '*.bru' 2>/dev/null | sort )"}; do
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
function bruEnsureEnvFile() {
  local collection="$1" envHelper="$2" envName="$3"
  local envFile="$envHelper/$envName.bru"

  if [[ ! -f "$collection/environments/$envName.bru" ]]; then
    echo "👩‍💻 unknown environment '$envName' — available environments:" >&2
    ( cd "$collection" && find environments -name '*.bru' -exec basename {} .bru \; | sed 's/^/  /' | sort ) >&2
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
function bruPickRequest() {
  local collection="$1"
  ( cd "$collection" && find requests -name '*.bru' | sort ) \
    | fzf --height 60% --reverse --prompt 'request > ' \
          --header 'enter=select  esc=cancel' \
          --preview "sed -n '1,60p' '$collection/{}'" \
          --preview-window 'right:55%:wrap'
}

# fzf picker for a collection's environments. Prints the chosen env name.
function bruPickEnv() {
  local collection="$1"
  ( cd "$collection" && find environments -name '*.bru' -exec basename {} .bru \; | sort ) \
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
function bruSetEnvVar() {
  local envFile="$1" key="$2" value="$3"
  [[ -z "$value" || "$value" == "null" ]] && return 1

  local line current
  line="$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*:" "$envFile")"

  if [[ -n "$line" ]]; then
    # strip everything up to the first colon, then trim spaces
    current="${line#*:}"
    current="${current## }"
    current="${current%% }"
    [[ "$current" == "$value" ]] && return 1
  fi

  # rewrite the file with awk — avoids sed's regex/quoting pitfalls in zsh
  local tmp="${envFile}.tmp$$"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    {
      # replace an existing "key: ..." line
      if (!done && $0 ~ "^[ \t]*" k "[ \t]*:") {
        match($0, /^[ \t]*/)
        print substr($0, 1, RLENGTH) k ": " v
        done = 1
        next
      }
      # otherwise insert before the closing brace of the vars block
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
function bruWithEnvLock() {
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

# Pull chained variables out of a --output json and persist them to the env
# file. A project supplies its own map of {envVarName: jq expression} via
# BRU_RUN_CHAINED_VARS (an associative array) before calling bru-run — with
# no map set, this is a no-op. Chaining is inherently specific to one API's
# response shapes, so bru-run carries no built-in map of its own.
function bruCaptureVars() {
  local out="$1" envFile="$2"
  (( ${#BRU_RUN_CHAINED_VARS[@]} == 0 )) && return 0

  local body key expr value
  local -a saved=()

  body="$(jq -c '.[0].results[-1].response.data' "$out" 2>/dev/null)"
  [[ -z "$body" || "$body" == "null" ]] && return 0

  for key expr in "${(kv)BRU_RUN_CHAINED_VARS[@]}"; do
    value="$(jq -r "$expr // empty" <<< "$body" 2>/dev/null | head -1)"
    [[ -z "$value" || "$value" == "null" ]] && continue
    bruSetEnvVar "$envFile" "$key" "$value" && saved+=("$key")
  done

  (( ${#saved[@]} )) && echo "👩‍💻 saved to env '${envFile:t:r}': ${(j:, :)saved}"
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
function bruPatchBody() {
  local collection="$1" body="$2"
  shift 2

  local -a secretKeys=( ${(f)"$(bruAllSecretKeys "$collection")"} )

  local base='.params.data'
  if [[ "$(jq -r 'try (.params.data | type) catch "missing"' <<< "$body")" != "object" ]]; then
    base=''
  fi

  # NOT `path`: zsh ties that name to $PATH, so a local `path` empties PATH
  # inside the function and every command becomes "not found".
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

    # A valid JSON value keeps its type; anything else becomes a string.
    # -Rn --args takes the value as an argument, so no quoting of a jq program
    # is needed and zsh has nothing to expand.
    if jq -e 'type == "number" or type == "boolean" or type == "null" or type == "object" or type == "array"' <<< "$rawValue" >/dev/null 2>&1; then
      jqValue="$rawValue"
    else
      jqValue="$(jq -Rn --args '$ARGS.positional[0]' -- "$rawValue")"
    fi

    # jqPath is built from a user-supplied key, so it cannot be spliced
    # straight into the jq program text — a key like "a,b" or "a;b" would
    # change the program's meaning instead of just failing. --arg passes it
    # as data; setpath addresses the path from that data instead of from
    # program syntax.
    local -a jqPathParts
    jqPathParts=( ${(s:.:)jqPath#.} )
    body="$(jq --argjson val "$jqValue" --args 'setpath($ARGS.positional; $val)' -- "${jqPathParts[@]}" <<< "$body" 2>/dev/null)" || {
      echo "👩‍💻 could not set '$key' (bad path?)" >&2
      return 1
    }
    # Never echo a secret. The value still reaches the request; only the line
    # printed here is masked, so a transcript or a screen share cannot leak it.
    if [[ "${key:l}" == *(password|passwd|secret|token|api_key|apikey|session_id)* ]] \
       || (( ${secretKeys[(Ie)${key##*.}]} )); then
      echo "👩‍💻 set ${jqPath#.} = <hidden>" >&2
    else
      echo "👩‍💻 set ${jqPath#.} = $jqValue" >&2
    fi
  done

  print -r -- "$body"
}

# Rewrite a request's body:json block into a temp .bru inside the collection,
# so relative paths and collection-level scripts keep working. Prints its path.
function bruTempRequest() {
  local collection="$1" request="$2" newBody="$3"

  local dir="$collection/.bru-cli-tmp"
  mkdir -p "$dir" || return 1
  local tmp="$dir/${request:t:r}-$$.bru"

  # The new body goes through a file: awk -v cannot carry newlines.
  local bodyFile="$dir/body-$$.json"
  print -r -- "$newBody" > "$bodyFile" || return 1

  # Replace the body:json { ... } block, matching its closing brace by depth.
  # Braces inside a quoted JSON string (e.g. "note": "wrap {this} value") do
  # not count — the line is scanned char by char, tracking in-string state
  # and \" escapes, instead of just gsub-counting every { and }.
  awk -v bodyFile="$bodyFile" '
    function depthAfterLine(s,    i, c, prev) {
      inStr = 0
      prev = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inStr) {
          if (c == "\"" && prev != "\\") inStr = 0
          # an escaped backslash ("\\") must not make the next quote look
          # escaped, so treat it as consumed rather than carried forward
          prev = (c == "\\" && prev == "\\") ? "" : c
          continue
        }
        if (c == "\"") { inStr = 1; prev = ""; continue }
        if (c == "{") depth++
        else if (c == "}") depth--
      }
    }
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

  print -r -- "${tmp#$collection/}"
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
function bruResolveRequest() {
  # (#i) needs extended_glob; local_options keeps it inside this function.
  setopt local_options extended_glob

  local collection="$1"
  shift

  local -a all matches near
  all=( ${(f)"$( cd "$collection" && find requests -name '*.bru' | sort )"} )
  matches=( "${all[@]}" )

  local term
  for term in "$@"; do
    matches=( ${(M)matches:#(#i)*$term*} )
  done

  if (( ${#matches[@]} == 1 )); then
    print -r -- "${matches[1]}"
    return 0
  fi

  if (( ${#matches[@]} == 0 )); then
    echo "👩‍💻 no request matches: $*" >&2
    near=( ${(M)all:#(#i)*$1*} )
    if (( ${#near[@]} )); then
      echo "👩‍💻 closest to '$1':" >&2
      printf '  %s\n' "${near[@]}" >&2
    fi
    return 1
  fi

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

function bruRun() {
  local collection="$1" envHelper="$2" protectedEnvsCsv="$3"
  shift 3

  if [[ ! -f "$collection/bruno.json" ]]; then
    echo "👩‍💻 no bruno.json in $collection" >&2
    return 1
  fi

  # --envs -> just list environments
  if [[ "$1" == "--envs" ]]; then
    echo "👩‍💻 environments in $collection"
    ( cd "$collection" && find environments -name '*.bru' -exec basename {} .bru \; | sed 's/^/  /' | sort )
    return 0
  fi

  # --list / --docs -> read the collection, never run anything
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

  # --show is ours, not bru's. --env/--local are both captured here so the
  # helper env can take priority over the collection's own — see below.
  local -a bruArgs=() sets=()
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

  local request i

  # Leading positional args are the request: either an exact path, or search
  # terms to resolve against the collection (`bru-run session lookup`). Flags
  # and anything after them stay as bru's own args.
  local -a terms=()
  while [[ -n "$1" && "$1" != -* ]]; do
    terms+=("$1")
    shift
  done
  bruArgs=("$@")

  if (( ${#terms[@]} == 1 )) && [[ -f "$collection/${terms[1]}" ]]; then
    request="${terms[1]}"
  elif (( ${#terms[@]} )); then
    request="$(bruResolveRequest "$collection" "${terms[@]}")" || return 1
    [[ -z "$request" ]] && { echo "👩‍💻 cancelled" >&2; return 1; }
    echo "👩‍💻 matched request: $request"
    show=1  # searched for it -> you want to see what came back
  fi

  # no request given -> pick one interactively
  if [[ -z "$request" ]]; then
    if ! command -v fzf >/dev/null 2>&1; then
      echo "👩‍💻 fzf not installed — pass a request path, or: brew install fzf" >&2
      return 1
    fi
    request="$(bruPickRequest "$collection")" || return 1
    [[ -z "$request" ]] && { echo "👩‍💻 cancelled" >&2; return 1; }
    show=1  # picked it from the menu -> you want to see the result
  fi

  if [[ ! -f "$collection/$request" ]]; then
    echo "👩‍💻 request not found: $request" >&2
    return 1
  fi

  # --set / --data -> run a patched copy, never touching the saved request.
  # {{vars}} are left alone: bru interpolates them in the temp file as usual.
  local tmpRequest=""
  if (( ${#sets[@]} )) || [[ -n "$dataJson" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "👩‍💻 --set/--data need jq — brew install jq" >&2
      return 1
    fi

    # sweep temps left behind by a run that died before its own cleanup
    [[ -d "$collection/.bru-cli-tmp" ]] && \
      find "$collection/.bru-cli-tmp" -maxdepth 1 -type f -delete 2>/dev/null

    local body
    body="$(sed -n '/^[ \t]*body:json[ \t]*{/,/^}/p' "$collection/$request" \
            | sed '1d;$d')"
    if [[ -z "${body//[[:space:]]/}" ]]; then
      echo "👩‍💻 no body:json block in $request" >&2
      return 1
    fi

    # {{$guid}} is not valid JSON — stash it, restore after jq. The literal is
    # built in a variable: inline \{ escapes would survive the substitution and
    # Bruno would stop interpolating the placeholder.
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
    show=1  # changed the payload -> you want to see what it returned
  fi

  # no env given -> pick one interactively
  if [[ -z "$env" ]]; then
    if command -v fzf >/dev/null 2>&1; then
      env="$(bruPickEnv "$collection")" || return 1
      [[ -z "$env" ]] && { echo "👩‍💻 cancelled" >&2; return 1; }
    fi
  fi

  # A project can list environments (e.g. prod) in its own .bru-run.yml as
  # protected_envs. Calling one of those needs --confirm — this is the only
  # code-level enforcement of environment safety; everything else is prose in
  # SKILL.md that an agent has to choose to follow.
  if [[ -n "$env" && -n "$protectedEnvsCsv" ]]; then
    local -a protectedEnvs=( ${(s:,:)protectedEnvsCsv} )
    if (( ${protectedEnvs[(Ie)$env]} )) && (( ! confirm )); then
      echo "👩‍💻 '$env' is a protected environment — pass --confirm to run against it" >&2
      return 1
    fi
  fi

  # Resolve the env, preferring the project's own env_helper directory over
  # the collection's own environments/. A collection may declare secrets as
  # `vars:secret` with no real value in the versioned file — the helper
  # directory is where the real value lives, outside any repo.
  local envFile=""
  if [[ -n "$env" ]]; then
    envFile="$envHelper/$env.bru"
    if [[ -f "$envFile" ]]; then
      echo "👩‍💻 using project env: $env ($envFile)"
      bruArgs+=(--env-file "$envFile")
    elif [[ -f "$collection/environments/$env.bru" ]]; then
      echo "👩‍💻 using collection env: $env (secrets will be empty)"
      bruArgs+=(--env "$env")
      envFile=""  # never write captured values into the versioned collection
    else
      bruEnsureEnvFile "$collection" "$envHelper" "$env"
      return 1
    fi
  fi

  echo "👩‍💻 bru run $request ${bruArgs[*]}"

  # Always run with --output: it is how both --show and the variable capture
  # below read the response. Each `bru run` is a fresh process, so bru.setVar()
  # dies with it and bru.setEnvVar() is in-memory only (as of CLI 3.5.2) — the
  # chained values have to be written back to the env file by us.
  local out exitCode
  out="$(mktemp -t bru-response).json"
  ( cd "$collection" && bru run "$request" "${bruArgs[@]}" --output "$out" )
  exitCode=$?

  if [[ -s "$out" ]] && command -v jq >/dev/null 2>&1; then
    [[ -n "$envFile" && -f "$envFile" ]] && \
      bruWithEnvLock "$envFile" bruCaptureVars "$out" "$envFile"

    if (( show )); then
      echo
      echo "👩‍💻 response body"
      # [-1], same as bruCaptureVars: with a folder/multi-step run the last
      # response is the one you asked about. Identical for a single request.
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
function bruList() {
  setopt local_options extended_glob

  local collection="$1"
  shift

  local -a rows=()
  local f method width=0
  # declared here, not inside the loop: zsh prints "term=''" when `local` runs
  # again on a name that already exists in the same scope.
  local term keep

  # -not -name folder.bru: that file is Bruno's folder settings, not a request.
  for f in ${(f)"$( cd "$collection" && find requests -name '*.bru' -not -name 'folder.bru' | sort )"}; do
    method="$(grep -m1 -E '"method"[[:space:]]*:' "$collection/$f" \
              | sed -E 's/.*"method"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"

    # Not every request is JSON-RPC. Fall back to the HTTP verb block.
    if [[ -z "$method" ]]; then
      method="$(grep -m1 -E '^(get|post|put|patch|delete|head|options)[[:space:]]*\{' \
                "$collection/$f" | sed -E 's/[[:space:]]*\{.*//' | tr 'a-z' 'A-Z')"
      [[ -z "$method" ]] && method="?"
    fi

    # keep the row only when every term matches the path or the method
    keep=1
    for term in "$@"; do
      if [[ "$f" != (#i)*$term* && "$method" != (#i)*$term* ]]; then
        keep=0
        break
      fi
    done
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
  for row in "${(o)rows[@]}"; do
    printf '  %-*s  %s\n' "$width" "${row%%|*}" "${row#*|}"
  done
}

# Print the docs block of one request. Takes a path or search terms, same as a
# normal run. Reads the file only — nothing is sent anywhere.
function bruDocs() {
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

  # Print the docs { ... } block, matching its closing brace by depth.
  awk '
    !inDocs && /^[ \t]*docs[ \t]*\{/ { inDocs = 1; depth = 1; next }
    inDocs {
      n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
      depth += n - m
      if (depth <= 0) { inDocs = 0; next }
      print
    }
  ' "$collection/$request" | sed 's/^  //'
}
