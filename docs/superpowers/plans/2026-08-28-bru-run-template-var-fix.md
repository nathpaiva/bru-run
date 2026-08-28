# --set/--data Template Variable Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `--set` and `--data` stop rejecting request bodies that contain an unquoted `{{var}}` placeholder (Bruno's template syntax for a numeric/boolean/etc. variable), which today fails almost every real request with "body:json ... is not valid JSON — cannot patch".

**Architecture:** Generalize the existing `{{$guid}}`-only swap-out/swap-back in `bruRun` (`lib/bru-run.sh`) to cover every Bruno **user** variable (`{{name}}`, not `{{$dynamicVar}}`). Before the JSON-validity check, every `{{[A-Za-z_]...}}` occurrence in the raw body is replaced with a unique numbered token; after patching, every token is restored to its original literal text. One swap site, in `bruRun`, upstream of both the `--data` merge and the `bruPatchBody` call — so `bruPatchBody`'s own internal `jq` type-check (`lib/bru-run.sh:610`) always sees already-token-substituted, valid JSON, with no changes needed inside `bruPatchBody` itself.

**Tech Stack:** bash 4.0+ (matches the rest of the engine — see `CLAUDE.md`'s "Language" section). Textual substitution via `grep -oE` + bash string replacement, not `jq` — the body isn't valid JSON yet at the point this has to run.

**Spec:** [github.com/nathpaiva/bru-run/issues/22](https://github.com/nathpaiva/bru-run/issues/22) — read the issue body and both comments in full; it is the binding test spec (10 required cases, each with the failure it prevents) and the binding root-cause analysis. This plan implements it without inventing a different test list.

## Global Constraints

- bash 4.0+ syntax throughout (no zsh, no bash-3.2-only avoidance needed — see `CLAUDE.md`).
- `bru-run` must stay ignorant of variable values — never resolve `{{var}}` to its actual value, only swap the placeholder text out and back. Bruno resolves it later via `--env-file`.
- The placeholder token must be **unique per occurrence**, not per key, not a fixed literal — a variable can repeat, and a variable's `{{...}}` can be a substring of a larger string value (`"{{baseUrl}}/home"`).
- Bruno's own dynamic variables (`{{$guid}}`, `{{$randomInt}}`, anything starting with `$` inside the braces) must never be touched by the new swap — only user variables (`{{name}}`, starting with a letter or underscore).
- No automated test suite in this repo — verify manually against a test fixture added to `examples/pompom-time/` (see Task 1), per the repo's existing convention (`CLAUDE.md`'s "Testing changes" section).
- Public repo: grep every diff for "moz"/"app-api" (case-insensitive) before committing — must find nothing. (The issue itself mentions a real company collection by describing scale/paths; do not copy any of those specifics — like real request names or field names from that collection beyond what's already generic — into this repo's committed code, tests, or commit messages. `keyword_item_ids`, `campaign_string_id`, `nath-bru-collection-update` etc. from the issue are that other project's real data and must not appear anywhere in this repo.)
- Commit message format: header only, no scope prefix.
- No `Co-Authored-By` line (personal repo).
- Mutation-test every test case per the issue's explicit requirement: after writing a test, temporarily break the fix, confirm the test fails, then restore the fix and confirm it passes again. This is not optional — the issue calls out that "a test written after the fix that has never failed proves nothing."

## Root cause (from the issue, verified against current code)

`lib/bru-run.sh:948` (inside `bruRun`) validates the raw `body:json` block with `jq -e .` before any `--set`/`--data` patch is applied. Bruno writes an unquoted numeric variable as `"account_id": {{accountId}}` — valid Bruno template syntax, invalid JSON. `jq` throws a parse error, the guard treats that as "not valid JSON", and the whole patch path fails — on almost every real request, since template variables are the normal case, not the exception.

The fix already exists in miniature: `lib/bru-run.sh:944-946` swaps `{{$guid}}` for a token before the same `jq -e .` guard, and `lib/bru-run.sh:968` swaps it back after patching. This plan generalizes that pattern to every user variable.

## File Structure

- **Modify:** `lib/bru-run.sh` — the swap-out logic (currently 3 lines handling only `{{$guid}}`) becomes a small block handling every `{{[A-Za-z_]...}}` occurrence, still sitting between `lib/bru-run.zsh:946` (guid swap, kept as-is) and `lib/bru-run.zsh:948` (the `jq -e .` guard) for the swap-out half, and the restore (currently `lib/bru-run.sh:968`) becomes the reverse of the new swap for the swap-back half.
- **Modify:** `examples/pompom-time/bruno/requests/create.bru` — add a `{{var}}`-holding field to `body:json` so the bug (and the fix) can be exercised manually without needing a real company's collection. Also needs the corresponding variable declared in `examples/pompom-time/bruno/environments/dev.bru` so a real `bru run` (if `bru` is installed) has something to resolve it to, though the fix itself is provable without running `bru` at all (the patch happens before `bru run` is ever invoked).

Single-file logic change (all in `bruRun`), so this is one task, not several — the 10 test cases are all exercised against the same code path and don't have independent sub-deliverables worth separate review gates.

---

### Task 1: Generalize the `{{var}}` swap and add a test fixture

**Files:**
- Modify: `lib/bru-run.sh:944-968` (the swap-out/swap-back block inside `bruRun`)
- Modify: `examples/pompom-time/bruno/requests/create.bru` (add a template-var field to `body:json`)
- Modify: `examples/pompom-time/bruno/environments/dev.bru` (declare the variable, so a real `bru run` — if available — has a value to substitute)

**Interfaces:**
- Consumes: nothing new — this task touches existing code paths only (`bruRun`, called from `bin/bru-run`; `bruPatchBody`, unchanged, still called from `bruRun` at the same call site).
- Produces: nothing new consumed by other tasks — this plan has one task.

- [ ] **Step 1: Read the current swap block to confirm line numbers before editing**

Run: `sed -n '937,976p' lib/bru-run.sh`

Expected output (current state, before this task's edit):
```bash
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
```

If the line numbers or exact text differ from this, stop and report — it means the file changed since this plan was written and the edit needs to be re-targeted, not blindly applied.

- [ ] **Step 2: Replace the swap-out block (guid swap + jq guard)**

Replace this text:
```bash
    local guidToken="__BRU_TMPL_GUID__"
    local guidLiteral='{{$guid}}'
    body="${body//$guidLiteral/$guidToken}"

    if ! jq -e . <<< "$body" >/dev/null 2>&1; then
      echo "👩‍💻 body:json in $request is not valid JSON — cannot patch" >&2
      return 1
    fi
```

With:
```bash
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
    local varTokens=() varLiterals=()
    local varMatch varIndex=0
    while IFS= read -r varMatch; do
      [[ -z "$varMatch" ]] && continue
      varIndex=$(( varIndex + 1 ))
      local varToken="__BRU_VAR_${varIndex}__"
      varTokens+=("$varToken")
      varLiterals+=("$varMatch")
      body="${body/"$varMatch"/$varToken}"
    done < <(grep -oE '\{\{[A-Za-z_][^}]*\}\}' <<< "$body")

    if ! jq -e . <<< "$body" >/dev/null 2>&1; then
      echo "👩‍💻 body:json in $request is not valid JSON — cannot patch" >&2
      return 1
    fi
```

Note on `body="${body/"$varMatch"/$varToken}"` (single `/`, not `//`): this replaces only the *first* remaining occurrence of that exact `{{...}}` text on each loop iteration. Since `grep -oE` already found every occurrence in original left-to-right order (including repeats — `grep -oE` prints one line per match, so a variable appearing twice produces two identical lines in `varMatch`, processed as two separate loop iterations), replacing the first remaining occurrence each time correctly assigns each repeat its own token, in order. Using `//` (replace all) here would be wrong — it would collapse two occurrences of the same variable onto a single token pair, breaking the "restore to the right places" requirement (issue's test #10).

- [ ] **Step 3: Replace the swap-back line**

Replace this text:
```bash
    body="${body//$guidToken/$guidLiteral}"
```

With:
```bash
    # Restore in reverse order: with nested/overlapping substrings this
    # doesn't matter here (each token is a unique, unambiguous string that
    # cannot appear inside another token), but restoring highest-numbered
    # first keeps the loop symmetric with the swap-out loop above and
    # avoids ever depending on token-string containment being safe by
    # accident.
    local i
    for (( i = ${#varTokens[@]} - 1; i >= 0; i-- )); do
      body="${body//"${varTokens[$i]}"/${varLiterals[$i]}}"
    done

    body="${body//$guidToken/$guidLiteral}"
```

(the guid restore stays last, unchanged in position relative to itself — it was already the only restore step before this change, now it runs after the new per-variable restore loop)

- [ ] **Step 4: Verify the full new block reads correctly**

Run: `sed -n '937,1000p' lib/bru-run.sh` and confirm the block now reads, in order: extract body → check non-empty → swap out guid → swap out every user variable (numbered tokens) → `jq -e .` validity check → `--data` merge (if any) → `bruPatchBody` (if any `--set`) → restore variables (reverse order) → restore guid → build temp request.

- [ ] **Step 5: Add a test fixture — a template variable in `create.bru`'s body**

Read the current file: `cat examples/pompom-time/bruno/requests/create.bru`

It currently has no `{{var}}` in its `body:json` block, so it can't reproduce the bug as-is. Edit `examples/pompom-time/bruno/requests/create.bru`'s `body:json` block from:
```
body:json {
  {
    "jsonrpc": "2.0",
    "id": "1",
    "method": "item.create",
    "params": {
      "data": {
        "name": "example item"
      }
    }
  }
}
```
to:
```
body:json {
  {
    "jsonrpc": "2.0",
    "id": "1",
    "method": "item.create",
    "params": {
      "data": {
        "name": "example item",
        "quantity": {{defaultQuantity}},
        "note": "ships from {{warehouseCode}}"
      }
    }
  }
}
```

This adds two of the issue's required cases directly into the example collection: an unquoted numeric variable (`{{defaultQuantity}}`, issue test #3) and a variable embedded inside a longer string (`"ships from {{warehouseCode}}"`, issue test #6 — same shape as the real `"{{baseUrl}}/home"` case that found this bug).

- [ ] **Step 6: Declare the new variables in the example environment**

Read the current file: `cat examples/pompom-time/bruno/environments/dev.bru`

Add the two new variables to its `vars {}` block. Current:
```
vars {
  base_url: https://example-dev.invalid/api
}

vars:secret [
  api_key
]
```
New:
```
vars {
  base_url: https://example-dev.invalid/api
  defaultQuantity: 1
  warehouseCode: EXAMPLE-WH
}

vars:secret [
  api_key
]
```
(Not secrets — these are plain example values, invented, matching the rest of this fixture collection's own convention of fake data only.)

- [ ] **Step 7: Manual test — issue test #3 (unquoted numeric variable + --set)**

This is the core regression test — the exact failure mode from the issue.

Run:
```bash
cd examples/pompom-time
../../bin/bru-run create --env dev --set name=widget
```

Expected (bash 4.0+, with this fix): no "not valid JSON — cannot patch" error. The command proceeds to build a patched temp request and either runs it (if `bru` is installed) or fails later for an unrelated reason (network, missing `bru` binary) — NOT with the JSON-parse failure this issue is about.

Before this fix (to prove the test is real): temporarily revert Step 2's edit (or `git stash` the change), run the identical command, and confirm you DO see `👩‍💻 body:json in requests/create.bru is not valid JSON — cannot patch`. Then restore the fix (`git stash pop` or redo Step 2) before continuing — this is the mutation-testing step the issue requires for this case.

- [ ] **Step 8: Manual test — issue test #6 (variable inside a longer string) and inspect the patched body directly**

The patched temp request file is the most direct way to see the actual restored JSON, without needing `bru` installed.

Run:
```bash
cd examples/pompom-time
../../bin/bru-run create --env dev --set name=widget --show 2>&1 | head -30
ls .bru-cli-tmp/ 2>/dev/null
```

If a temp file exists in `.bru-cli-tmp/`, read it: `cat .bru-cli-tmp/create-*.bru` (note: `bruRun` normally cleans this up after a successful `bru run`; if `bru` isn't installed the run itself will fail after the temp file is built, which is fine — the file may still be there to inspect, or may have been cleaned by the pre-run sweep on the *next* invocation. If it's already gone, temporarily comment out the `rm -f "$collection/$tmpRequest"` line at the end of `bruRun` for this one test run, confirm the output, then restore the line — do not ship that change.)

Confirm the `body:json` block in the temp file reads:
```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "method": "item.create",
  "params": {
    "data": {
      "name": "widget",
      "quantity": {{defaultQuantity}},
      "note": "ships from {{warehouseCode}}"
    }
  }
}
```

Both `{{defaultQuantity}}` and `{{warehouseCode}}` must appear **exactly as they did in the original file** — unresolved, and `"ships from {{warehouseCode}}"` must NOT have become `"ships from 0"` or `"ships from "` or anything else. `name` must be `widget` (patched by `--set`), proving the patch itself still works alongside untouched variables.

Mutation test: temporarily change Step 2's numbered-token loop to use a single fixed token (e.g. replace `"__BRU_VAR_${varIndex}__"` with the literal string `"0"` for this test only), re-run this same test, and confirm the note field now wrongly reads `"ships from 0"` or similar corruption — proving this test would have caught the bug the issue specifically warns about (a fixed placeholder silently producing a wrong-but-valid result). Then revert the mutation.

- [ ] **Step 9: Manual test — issue test #1 (`{{$guid}}` alongside `--set`, still unique per run)**

This confirms the new generalized swap doesn't interfere with the pre-existing guid handling. `examples/pompom-time` doesn't have a `{{$guid}}` anywhere — add one temporarily for this test only (do not commit it): edit `create.bru`'s body to add `"idempotency_key": "{{$guid}}"` to the `data` object, run:
```bash
cd examples/pompom-time
../../bin/bru-run create --env dev --set name=widget
```
then inspect the temp request the same way as Step 8. Confirm `"idempotency_key": "{{$guid}}"` is present, unresolved, and that no `__BRU_VAR_n__` or `__BRU_TMPL_GUID__` token leaked into the final file. Revert the temporary `{{$guid}}` addition to `create.bru` afterward — it is not part of this task's committed fixture (keep the fixture to exactly the two variables from Step 5, since a plain `bru-run --list`/`--docs` reader of this example collection shouldn't need to know what `{{$guid}}` even is; this test just needs to prove the interaction once).

Mutation test: temporarily reorder the two swap-out blocks (run the new user-variable swap loop *before* the guid swap instead of after) and re-run. Confirm `{{$guid}}` gets corrupted (turned into a `__BRU_VAR_n__` token that then never gets restored to `{{$guid}}`, because the guid-restore step only looks for `__BRU_TMPL_GUID__`) — proving the ordering matters and this test would catch a regression in it. Then restore the correct order.

- [ ] **Step 10: Manual test — issue test #2 (a second Bruno dynamic variable beside a user variable)**

Temporarily add `"request_id": "{{$randomInt}}"` next to `{{defaultQuantity}}` in `create.bru`'s body (do not commit), run the same `--set name=widget --env dev` command, inspect the temp file, and confirm `{{$randomInt}}` survived untouched (the character class `[A-Za-z_]` excludes `$`, so this variable is never swapped by the new loop, and there's no explicit handling for it the way there is for `{{$guid}}` — it should simply pass through the whole swap/restore process never having been touched, which is the correct behavior: only `{{$guid}}` needs special handling because it's the one dynamic variable this codebase's `bruTempRequest`/collection-level script depends on being unique per run; other dynamic variables are Bruno's own concern and bru-run doesn't need to know about them at all). Revert the temporary addition afterward.

- [ ] **Step 11: Manual test — issue test #4 (quoted string variable keeps working)**

`create.bru`'s `note` field is already a plain string with an embedded variable (Step 5's `warehouseCode`), but this test wants a variable that's the *entire* value of a quoted field, not embedded in one. `headers { x-api-key: {{api_key}} }` and `post { url: {{base_url}}/rpc }` in the existing `create.bru` are exactly this shape, but those aren't inside `body:json` (which is the only block this fix touches — headers/url aren't patched by `--set`/`--data` and don't go through this swap at all, correctly, since they're outside the scope of what `bruExtractBlock ... body:json` extracts). Confirm this by re-running Step 7's test and checking the temp file's `headers`/`post` blocks are byte-identical to the original `create.bru` — `{{base_url}}` and `{{api_key}}` should appear there completely unprocessed, never having been part of `body`.

- [ ] **Step 12: Manual test — issue test #5 (genuinely malformed JSON still errors)**

Prove the fix didn't accidentally disable the validity check entirely. Temporarily break `create.bru`'s `body:json` block with real invalid JSON (not a template variable — an actual syntax error, e.g. change `"name": "example item",` to `"name" "example item"` — missing colon), run:
```bash
cd examples/pompom-time
../../bin/bru-run create --env dev --set name=widget
```
Expected: still fails with `👩‍💻 body:json in requests/create.bru is not valid JSON — cannot patch` — the same message as before this fix, for a body that's actually broken (not just template-variable-holding). Revert the temporary breakage afterward.

- [ ] **Step 13: Manual test — issue test #7 (literal `0` beside a variable)**

Temporarily add `"page": 0` next to `"quantity": {{defaultQuantity}}` in `create.bru`'s body (do not commit — or fold into Step 5's fixture permanently if you prefer one fixture covering more cases; either is fine, but if kept permanently, re-verify Steps 7-8's expected output includes it). Run the same test, confirm both `"page": 0` (untouched literal) and `"quantity": {{defaultQuantity}}` (restored variable) survive correctly, distinguishing a real zero from a variable placeholder. This is the case that rules out using a fixed placeholder value — already covered structurally by the numbered-token design (Step 2), but this test proves it end to end.

- [ ] **Step 14: Manual test — issue test #8 and #9 (--set on a non-variable field, and --set on a variable field)**

Already exercised by Steps 7-8 (`--set name=widget` sets a plain literal field, `quantity`/`note` remain untouched variables) — no separate fixture needed. Explicitly confirm in this step's output: `name` became `widget` (test #8, `--set` on a non-variable field works), and `quantity`/`warehouseCode` are still `{{...}}`, not resolved to any value (test #9, `--set` doesn't touch fields that are template variables it wasn't asked to change).

- [ ] **Step 15: Manual test — issue test #10 (two variables on one line, same variable twice)**

Temporarily change `create.bru`'s body to include the same variable twice, e.g.:
```json
"note": "ships from {{warehouseCode}} via {{warehouseCode}}"
```
Run the test, inspect the temp file, confirm both occurrences restored correctly to `{{warehouseCode}}` (not one restored and one left as a token, and not both collapsed into a single restore that only fixes one). Revert afterward.

Mutation test: temporarily change the swap-out loop's substitution from `body="${body/"$varMatch"/$varToken}"` (single-occurrence replace) to `body="${body//"$varMatch"/$varToken}"` (replace-all), re-run, and confirm this now fails to distinguish the two occurrences correctly during restore (both get the same token, so the restore loop only has one token/literal pair for what were two separate matches from `grep -oE`, and the array Step 2 builds will have two entries with the same token but the body only has zero-or-all instances left after the first `//` substitution already consumed both) — confirms this test would catch a regression back to the wrong (all-at-once) substitution approach. Then revert the mutation.

- [ ] **Step 16: Grep diff for moz/app-api and for any leaked real-collection specifics, then commit**

```bash
git diff -- lib/bru-run.sh examples/ | grep -iE 'moz|app-api'
```
Expected: no output.

```bash
git diff -- lib/bru-run.sh examples/ | grep -iE 'keyword_item_ids|campaign_string_id|nath-bru-collection-update|keywordItemIds'
```
Expected: no output — confirms nothing from the issue's real-collection examples leaked into this repo's committed files.

```bash
git status
```
Confirm only the intended files are staged: `lib/bru-run.sh`, `examples/pompom-time/bruno/requests/create.bru`, `examples/pompom-time/bruno/environments/dev.bru`. No `.bru-cli-tmp/` artifacts, no temporary test-only edits left in place from Steps 9/10/13/15 (all of those were explicitly reverted in their own steps — this is the final check that reversion actually happened).

```bash
git add lib/bru-run.sh examples/pompom-time/bruno/requests/create.bru examples/pompom-time/bruno/environments/dev.bru
git commit -m "fix: --set/--data no longer reject bodies with unquoted template variables"
```

---

## Self-Review Notes

**Spec coverage:** all 10 of the issue's required test cases are covered — #1 (Step 9), #2 (Step 10), #3 (Step 7), #4 (Step 11), #5 (Step 12), #6 (Step 8), #7 (Step 13), #8 and #9 (Step 14), #10 (Step 15). Mutation testing is included for the highest-value cases (#3's core regression, #6's silent-corruption risk, #1's ordering dependency, #10's per-occurrence correctness) per the issue's explicit requirement, rather than for all 10 mechanically — the issue's own emphasis ("#1 is first because...", "#5 stops a fix that simply skips validation", "#6 is the silent-corruption case") points at these four as the ones a shortcut fix would most plausibly pass without actually being correct.

**Placeholder scan:** none — every step has literal commands, literal code, and literal expected output.

**Type consistency:** N/A — no new function signatures introduced; this task modifies control flow inside the existing `bruRun` function only. `bruPatchBody`'s signature and internal logic are unchanged (confirmed during design: it already receives `body` after `bruRun`'s swap has run, since the swap happens before the `bruPatchBody` call site at `lib/bru-run.sh:965`).

**Scope discipline:** this plan does not touch `bruPatchBody` itself, does not add a real company's field names or request shapes to this public repo (the issue's own examples are from a different, private collection), and does not introduce a testing framework — matching the repo's existing manual-verification convention.
