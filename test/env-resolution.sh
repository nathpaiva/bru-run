#!/usr/bin/env bash
#
# Regression tests for env resolution — bruEnsureEnvFile and bruSecretKeys.
#
# Two bugs have landed in this area: #34 (worktree config) and #43 (--env
# never bootstrapping the secrets file). The smoke test never touches env
# resolution, so this fills that gap. Offline: no `bru` binary, no network.
#
# Run: bash test/env-resolution.sh   (also `npm test`)

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bru-run.sh
source "$here/lib/bru-run.sh"

pass=0
fail=0

# Assert helpers — call as: if <test>; then ok "desc"; else ng "desc" "detail"; fi
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() { printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

# Portable "octal mode of a path" — Linux (CI) vs macOS.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# --- scratch collection --------------------------------------------------------

WORK="$(mktemp -d -t 'bru-env-test.XXXXXX')"
trap 'rm -rf "$WORK"' EXIT

COL="$WORK/collection"
mkdir -p "$COL/environments"

# multi-line vars:secret (the form Bruno's serializer writes)
printf 'vars {\n  base_url: https://x.invalid\n}\n\nvars:secret [\n  api_key\n]\n' \
  > "$COL/environments/dev.bru"

# no secrets at all
printf 'vars {\n  base_url: https://x.invalid\n}\n' \
  > "$COL/environments/plain.bru"

# single-line vars:secret — a hand-edited file
printf 'vars {\n  base_url: https://x.invalid\n}\n\nvars:secret [a, b]\n' \
  > "$COL/environments/single.bru"

# CRLF line endings — a hand-edited file from Windows or a bad editor
printf 'vars:secret [\r\n  api_key\r\n]\r\n' \
  > "$COL/environments/crlf.bru"

# vars:secret present but empty — parses to zero keys
printf 'vars {\n  base_url: https://x.invalid\n}\n\nvars:secret [\n]\n' \
  > "$COL/environments/empty.bru"

# multi-line with commas — the shape Bruno's serializer writes for 2+ keys
printf 'vars:secret [\n  api_key,\n  token\n]\n' \
  > "$COL/environments/multi.bru"

# unclosed vars:secret block — a hand-edited file missing the closing ]
printf 'vars:secret [\n  api_key\n\nvars {\n  base_url: https://x.invalid\n}\n' \
  > "$COL/environments/unclosed.bru"

# a secret disabled Bruno-style (~ prefix) alongside an active one
printf 'vars:secret [\n  ~token\n  api_key\n]\n' \
  > "$COL/environments/disabled.bru"

# --- bruSecretKeys -----------------------------------------------------------

got="$(bruSecretKeys "$COL/environments/dev.bru")"
if [[ "$got" == "api_key" ]]; then
  ok "bruSecretKeys: multi-line block -> api_key"
else
  ng "bruSecretKeys: multi-line block -> api_key" "got: '$got'"
fi

got="$(bruSecretKeys "$COL/environments/single.bru")"
if [[ "$got" == $'a\nb' ]]; then
  ok "bruSecretKeys: single-line [a, b] -> a, b"
else
  ng "bruSecretKeys: single-line [a, b] -> a, b" "got: '$got'"
fi

got="$(bruSecretKeys "$COL/environments/crlf.bru")"
if [[ "$got" == "api_key" ]]; then
  ok "bruSecretKeys: CRLF file -> api_key with no carriage return"
else
  ng "bruSecretKeys: CRLF file -> api_key with no carriage return" "got: $(printf '%q' "$got")"
fi

got="$(bruSecretKeys "$COL/environments/multi.bru")"
if [[ "$got" == $'api_key\ntoken' ]]; then
  ok "bruSecretKeys: multi-line with commas -> api_key, token"
else
  ng "bruSecretKeys: multi-line with commas -> api_key, token" "got: '$got'"
fi

got="$(bruSecretKeys "$COL/environments/unclosed.bru")"; rc=$?
if [[ -z "$got" && $rc -eq 2 ]]; then
  ok "bruSecretKeys: unclosed block -> no keys, exit 2 (not the rest of the file)"
else
  ng "bruSecretKeys: unclosed block -> no keys, exit 2 (not the rest of the file)" "rc=$rc, got: '$got'"
fi

got="$(bruSecretKeys "$COL/environments/disabled.bru")"
if [[ "$got" == $'~token\napi_key' ]]; then
  ok "bruSecretKeys: keeps a ~-disabled key as-is (stub must not re-enable it)"
else
  ng "bruSecretKeys: keeps a ~-disabled key as-is (stub must not re-enable it)" "got: '$got'"
fi

got="$(bruAllSecretKeys "$COL" 2>/dev/null)"
warn="$(bruAllSecretKeys "$COL" 2>&1 1>/dev/null)"
if [[ "$got" == $'a\napi_key\nb\ntoken' ]]; then
  ok "bruAllSecretKeys: strips ~ for masking, union across every env file"
else
  ng "bruAllSecretKeys: strips ~ for masking, union across every env file" "got: '$got'"
fi
if [[ "$warn" == *"unreadable"* ]]; then
  ok "bruAllSecretKeys: warns when a file's vars:secret could not be read"
else
  ng "bruAllSecretKeys: warns when a file's vars:secret could not be read" "warn: '$warn'"
fi

# --- bruEnsureEnvFile ------------------------------------------------------------

# Fresh $BRU_RUN_SECRETS_ROOT per case, created world-listable (the umask
# default this fix has to tighten).
new_root() {
  export BRU_RUN_SECRETS_ROOT="$WORK/secrets-$1"
  rm -rf "$BRU_RUN_SECRETS_ROOT"
  mkdir -p "$BRU_RUN_SECRETS_ROOT"
  chmod 755 "$BRU_RUN_SECRETS_ROOT"
  HELPER="$BRU_RUN_SECRETS_ROOT/ns"
}

new_root bootstrap
rc=0; bruEnsureEnvFile "$COL" "$HELPER" "dev" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 && -f "$HELPER/dev.bru" ]]; then
  ok "bruEnsureEnvFile: secret + no helper -> stub written, return 1"
else
  ng "bruEnsureEnvFile: secret + no helper -> stub written, return 1" "rc=$rc"
fi

if grep -q '^  api_key:$' "$HELPER/dev.bru"; then
  ok "bruEnsureEnvFile: stub line has no trailing space"
else
  ng "bruEnsureEnvFile: stub line has no trailing space" "got: '$(sed -n 2p "$HELPER/dev.bru")'"
fi

if [[ "$(mode_of "$BRU_RUN_SECRETS_ROOT")" == "700" ]]; then
  ok "bruEnsureEnvFile: \$BRU_RUN_SECRETS_ROOT is 700 after write"
else
  ng "bruEnsureEnvFile: \$BRU_RUN_SECRETS_ROOT is 700 after write" "got: $(mode_of "$BRU_RUN_SECRETS_ROOT")"
fi

if [[ "$(mode_of "$HELPER/dev.bru")" == "600" ]]; then
  ok "bruEnsureEnvFile: stub file is 600"
else
  ng "bruEnsureEnvFile: stub file is 600" "got: $(mode_of "$HELPER/dev.bru")"
fi

new_root nosecrets
rc=0; bruEnsureEnvFile "$COL" "$HELPER" "plain" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 && ! -e "$HELPER/plain.bru" ]]; then
  ok "bruEnsureEnvFile: no secrets -> return 0, no file"
else
  ng "bruEnsureEnvFile: no secrets -> return 0, no file" "rc=$rc"
fi

new_root typo
rc=0; err="$(bruEnsureEnvFile "$COL" "$HELPER" "dve" 2>&1 >/dev/null)" || rc=$?
if [[ $rc -eq 1 && "$err" == *"unknown environment"* ]]; then
  ok "bruEnsureEnvFile: typo env -> 'unknown environment', return 1"
else
  ng "bruEnsureEnvFile: typo env -> 'unknown environment', return 1" "rc=$rc, err='$err'"
fi

new_root present
mkdir -p "$HELPER"
printf 'SENTINEL — do not truncate\n' > "$HELPER/dev.bru"
before="$(cat "$HELPER/dev.bru")"
rc=0; bruEnsureEnvFile "$COL" "$HELPER" "dev" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 && "$(cat "$HELPER/dev.bru")" == "$before" ]]; then
  ok "bruEnsureEnvFile: helper present -> return 0, untouched"
else
  ng "bruEnsureEnvFile: helper present -> return 0, untouched" "rc=$rc"
fi

new_root emptyblock
rc=0; bruEnsureEnvFile "$COL" "$HELPER" "empty" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 ]]; then
  ok "bruEnsureEnvFile: empty vars:secret block -> return 1 (no blank-auth run)"
else
  ng "bruEnsureEnvFile: empty vars:secret block -> return 1 (no blank-auth run)" "rc=$rc"
fi

new_root unclosedblock
rc=0; bruEnsureEnvFile "$COL" "$HELPER" "unclosed" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 && ! -e "$HELPER/unclosed.bru" ]]; then
  ok "bruEnsureEnvFile: unclosed vars:secret block -> return 1, no garbage stub"
else
  ng "bruEnsureEnvFile: unclosed vars:secret block -> return 1, no garbage stub" "rc=$rc"
fi

new_root isdir
mkdir -p "$HELPER/dev.bru"   # the helper "file" is actually a directory
err="$(bruEnsureEnvFile "$COL" "$HELPER" "dev" 2>&1 >/dev/null)"; rc=$?
if [[ $rc -eq 1 && "$err" == *"not a regular file"* ]]; then
  ok "bruEnsureEnvFile: helper path is a directory -> return 1, not silent 0"
else
  ng "bruEnsureEnvFile: helper path is a directory -> return 1, not silent 0" "rc=$rc, err='$err'"
fi

new_root retroactiveperms
# the root was created world-listable by new_root (chmod 755) above — this
# path (no secrets declared) wrote no stub before this fix, so it never
# reached the chmod 700 call.
bruEnsureEnvFile "$COL" "$HELPER" "plain" >/dev/null 2>&1
if [[ "$(mode_of "$BRU_RUN_SECRETS_ROOT")" == "700" ]]; then
  ok "bruEnsureEnvFile: tightens \$BRU_RUN_SECRETS_ROOT even on the no-secrets path"
else
  ng "bruEnsureEnvFile: tightens \$BRU_RUN_SECRETS_ROOT even on the no-secrets path" "got: $(mode_of "$BRU_RUN_SECRETS_ROOT")"
fi

# --- bruTightenSecretsRoot ----------------------------------------------------

new_root existinginstall
# Simulate an install from before this fix: the helper file is already
# filled in, so bruRun's own -f check short-circuits and bruEnsureEnvFile is
# never called for it again. bruRun calls this directly instead, every time
# --env is used, not only when a stub gets written.
mkdir -p "$HELPER"
printf 'api_key: already-filled-in\n' > "$HELPER/dev.bru"
bruTightenSecretsRoot "$HELPER"
if [[ "$(mode_of "$BRU_RUN_SECRETS_ROOT")" == "700" ]]; then
  ok "bruTightenSecretsRoot: tightens an existing install's root with no stub write"
else
  ng "bruTightenSecretsRoot: tightens an existing install's root with no stub write" "got: $(mode_of "$BRU_RUN_SECRETS_ROOT")"
fi

new_root unrelatedproject
OTHER_HELPER="$WORK/custom-helper-not-under-root"
rm -rf "$BRU_RUN_SECRETS_ROOT"   # this "project" never uses the default root
bruTightenSecretsRoot "$OTHER_HELPER"
if [[ ! -e "$BRU_RUN_SECRETS_ROOT" ]]; then
  ok "bruTightenSecretsRoot: leaves an unrelated \$BRU_RUN_SECRETS_ROOT untouched"
else
  ng "bruTightenSecretsRoot: leaves an unrelated \$BRU_RUN_SECRETS_ROOT untouched" "root now exists"
fi

# --- report -----------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
