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

# --- report -----------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
