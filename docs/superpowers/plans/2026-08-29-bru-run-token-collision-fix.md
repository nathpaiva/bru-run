# Token Collision Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `--set`/`--data` no longer silently corrupt a value that happens to contain a swap token's digits — the fix detects the collision and aborts with a clear error instead of restoring the wrong content.

**Architecture:** Count each swap token's occurrence in `$body` right after swap-out (always 1 per token, by construction) and again right before the restore loop (after `--data` merge and `bruPatchBody` have both run). If any count increased, a patched-in value collided with that token — abort loudly. If all counts match, restore proceeds exactly as before.

**Tech Stack:** bash 4.0+ (matches the rest of `lib/bru-run.sh`).

**Spec:** [github.com/nathpaiva/bru-run/issues/24](https://github.com/nathpaiva/bru-run/issues/24) — read it in full, it's the binding spec: root cause, exact reproduction (tokens `9000000011`/`9000000021` from `examples/pompom-time`'s fixture, a `--set` value of `order-9000000011`), and the fix idea this plan implements (scan values with the same guard, or — the approach chosen here — detect the collision after the fact and fail safely, since scanning a value before it exists isn't possible without restructuring the patch order).

## Global Constraints

- bash 4.0+ syntax throughout (this repo dropped zsh in issue #4 — see `CLAUDE.md`).
- Never silently produce a wrong result — abort with a clear stderr message instead, matching the existing pattern (`bruPatchBody`'s "could not set '$key' (bad path?)").
- No automated test suite — verify manually against `examples/pompom-time/`, per `CLAUDE.md`'s "Testing changes" section.
- Public repo: grep every diff for "moz"/"app-api" (case-insensitive) before committing — must find nothing. This issue's own reproduction has no company-specific data, so no additional scrubbing concern like issue #22 had.
- Commit message: header only, no scope prefix.
- No `Co-Authored-By` line (personal repo).
- **Before opening the PR, remove `docs/superpowers/` from this branch** (both the plan file this task creates and any spec file, if one exists) — Nath explicitly had this directory removed from the repo on the #4 and #22 branches; it should not be reintroduced. This plan file itself is scratch-during-development, not a shipped artifact.

## Root cause (from the issue, verified against current code)

`lib/bru-run.sh:1061-1080` (inside `bruRun`) swaps each `{{var}}` for a unique numbered token, with a collision-avoidance loop (`lib/bru-run.sh:1074-1076`) that extends the token until it doesn't already occur in `$body`. But that check runs **before** `--data` (line 1087-1096) and `bruPatchBody` (line 1098-1099) — the code that actually inserts the user's `--set`/`--data` values into the body. If a user's value happens to contain a token's exact digits (a realistic case: any 10+ digit id, trace id, or millisecond timestamp), the value lands in the body holding those digits, and the restore loop (`lib/bru-run.sh:1110-1113`, using `//` — global replace) then corrupts that inserted value into the wrong `{{var}}` literal. The user's actual typed value never reaches the request — silent corruption, the same class of bug issues #22/#23 already fixed once, in a different spot.

## File Structure

- **Modify:** `lib/bru-run.sh:1098-1113` (inside `bruRun` — between the `bruPatchBody` call and the restore loop, add the post-patch collision check; no changes needed to the swap-out logic itself, which is already correct for the pre-patch case).
- **Modify:** `examples/pompom-time/bruno/requests/create.bru` — no fixture change needed; the issue's own reproduction already uses this collection's existing tokens/fixture from #22/#23. Confirm this during Task 1 rather than assuming — if the tokens have shifted (e.g. a third variable was added since), the reproduction command needs the current token values, not the issue's literal numbers.

Single-function change, one task — same shape as #22/#23's plan.

---

### Task 1: Detect post-patch token collisions and abort safely

**Files:**
- Modify: `lib/bru-run.sh:1098-1113` (inside `bruRun`)

**Interfaces:**
- Consumes: `varTokens`/`varLiterals` arrays and `body` variable, both already in scope from the existing swap-out code (`lib/bru-run.sh:1061-1080`) — no signature changes, this task only adds logic between two existing points in the same function.
- Produces: nothing new consumed elsewhere — `bruRun`'s external behavior is unchanged except for the new failure mode (abort on collision) this task adds.

- [ ] **Step 1: Confirm the current token values from the fixture before writing any test commands**

The issue's reproduction cites specific token digits (`9000000011`, `9000000021`) based on `examples/pompom-time/bruno/requests/create.bru`'s state at the time #23 was written. Confirm these are still current:

Run:
```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/fix-24-bru-run-token-collision
cat examples/pompom-time/bruno/requests/create.bru
```

Expected: `body:json` block contains `"quantity": {{defaultQuantity}}` and `"note": "ships from {{warehouseCode}}"`, in that order (this order determines which variable gets which token — `grep -oE` finds matches left to right, and `{{defaultQuantity}}` appears first in the file, so it's assigned index 1, token `9000000011`; `{{warehouseCode}}` is index 2, token `9000000021`, matching the token format `90000000${varIndex}1` from `lib/bru-run.sh:1066`).

If the file has changed and the variables are in a different order or there's a third variable, recompute the expected token values using the same formula (`90000000${varIndex}1`, where `varIndex` is 1-based position among `{{[A-Za-z_]...}}` matches in the body) before proceeding to Step 4's test — do not use the issue's literal numbers blindly if the fixture has moved on.

- [ ] **Step 2: Read the current code to confirm exact insertion point**

Run:
```bash
sed -n '1096,1116p' lib/bru-run.sh
```

Expected output (current state, before this task's edit):
```bash
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
```

If the line numbers or exact text differ from this, stop and report — it means the file changed since this plan was written and the edit needs to be re-targeted, not blindly applied.

The insertion point is between the `bruPatchBody` call (ends line 1100) and the "Restore in reverse order" comment (starts line 1102).

- [ ] **Step 3: Also capture each token's pre-patch occurrence count, right after swap-out**

The new post-patch check needs a baseline to compare against. Read the swap-out loop first:

```bash
sed -n '1061,1080p' lib/bru-run.sh
```

Expected (unchanged by this task):
```bash
    local varTokens=() varLiterals=()
    local varMatch varIndex=0
    while IFS= read -r varMatch; do
      [[ -z "$varMatch" ]] && continue
      varIndex=$(( varIndex + 1 ))
      local varToken="90000000${varIndex}1"
      # ... (collision-avoidance while loop, unchanged) ...
      while [[ "$body" == *"$varToken"* ]]; do
        varToken="9${varToken}"
      done
      varTokens+=("$varToken")
      varLiterals+=("$varMatch")
      body="${body/"$varMatch"/$varToken}"
    done < <(grep -oE '\{\{[A-Za-z_][^}]*\}\}' <<< "$body")
```

Each token is used exactly once in the single-occurrence swap-out (`body="${body/"$varMatch"/$varToken}"` — note the single `/`, not `//`), so immediately after this loop finishes, every token in `varTokens` occurs in `body` exactly once, by construction. This means the "pre-patch count" doesn't need to be measured — it's always 1 per token, a known constant. The new code in Step 4 only needs to measure the **post-patch** count and compare it against the constant 1, not against a captured baseline. This simplifies the fix: no new state needs to be threaded through the `jq -e .` validation or the `--data` merge — only a post-patch check right before the restore loop.

- [ ] **Step 4: Insert the collision-detection check between `bruPatchBody` and the restore loop**

Replace this text (from Step 2's read):
```bash
    if (( ${#sets[@]} )); then
      body="$(bruPatchBody "$collection" "$body" "${sets[@]}")" || return 1
    fi

    # Restore in reverse order — required, not stylistic: token(i) can be a
```

With:
```bash
    if (( ${#sets[@]} )); then
      body="$(bruPatchBody "$collection" "$body" "${sets[@]}")" || return 1
    fi

    # Each token was unique against $body at swap-out time (see the
    # collision-avoidance loop above), so it occurred exactly once right
    # after the swap. --data and bruPatchBody insert the user's actual
    # --set/--data values into the body — if a value happens to contain a
    # token's exact digits (a realistic case: any 10+ digit id, trace id,
    # or millisecond timestamp), that occurrence count goes up. The
    # restore loop below is a global replace with no way to tell "the
    # token in its original position" from "the same digits that landed
    # inside a value by coincidence" — so if the count changed, restoring
    # now would silently corrupt the user's own value into a {{var}}
    # literal instead of leaving it as typed. Abort instead of guessing:
    # matches this codebase's existing philosophy (bruPatchBody itself
    # fails loudly with "could not set (bad path?)" rather than silently
    # doing the wrong thing).
    local tokenIndex
    for (( tokenIndex = 0; tokenIndex < ${#varTokens[@]}; tokenIndex++ )); do
      local checkToken="${varTokens[$tokenIndex]}"
      local strippedBody="${body//"$checkToken"/}"
      local occurrences=$(( (${#body} - ${#strippedBody}) / ${#checkToken} ))
      if (( occurrences > 1 )); then
        echo "👩‍💻 a --set/--data value collides with an internal token — try a different value (this is rare: it means the value contains the exact digits $checkToken)" >&2
        return 1
      fi
    done

    # Restore in reverse order — required, not stylistic: token(i) can be a
```

Note the occurrence-counting technique: `${#body} - ${#strippedBody}` gives the total number of characters removed by stripping every occurrence of `$checkToken` out of `$body`; dividing by the token's own length gives the occurrence count. This is pure bash string-length arithmetic — no `grep -o | wc -l` subprocess needed, and it correctly counts overlapping-adjacent occurrences the same way `${body//pattern/}` (bash's own replace-all) does, so the count is consistent with what the restore loop's `//` would actually match.

- [ ] **Step 5: Verify the full new block reads correctly**

Run: `sed -n '1085,1125p' lib/bru-run.sh` and confirm the block now reads, in order: `--data` merge (if any) → `bruPatchBody` (if any `--set`) → new collision-detection loop (abort if any token's count increased) → existing reverse-order restore loop → guid restore.

- [ ] **Step 6: Manual test — the issue's exact reproduction (regression test)**

Run:
```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/fix-24-bru-run-token-collision/examples/pompom-time
../../bin/bru-run create --env dev --set name=order-9000000011
```

(Using `9000000011` — confirm this matches Step 1's determination of `{{defaultQuantity}}`'s actual current token; adjust the value if the fixture has changed.)

Expected (with this fix): the command aborts with the new collision message:
```
👩‍💻 set params.data.name = "order-9000000011"
👩‍💻 a --set/--data value collides with an internal token — try a different value (this is rare: it means the value contains the exact digits 9000000011)
```
(exact wording may vary slightly depending on `bruPatchBody`'s own stderr line ordering — the key confirmation is the collision message appears and the command exits non-zero, NOT that it silently succeeds with a corrupted body)

Verify exit code: `echo $?` should print `1`.

Before this fix (to prove the test is real): temporarily revert Step 4's edit (`git stash` the change), run the identical command, and inspect what actually happens — per the issue, the corrupted output should show `"name": "order-{{defaultQuantity}}"` in the patched body (inspect via the temp file in `.bru-cli-tmp/`, same technique as #22/#23's testing — temporarily comment out the `rm -f "$collection/$tmpRequest"` cleanup line in `bruRun` for this one test, then revert it). Confirm the corruption reproduces exactly as the issue describes, then `git stash pop` to restore the fix and re-run the Step 6 command, confirming it now aborts cleanly instead. This is the mutation test for this fix — issue #22 established the norm in this repo that "a test written after the fix that has never failed proves nothing," and it applies here too even though issue #24 doesn't say so explicitly.

- [ ] **Step 7: Manual test — the happy path still works (no collision)**

Confirm the fix doesn't false-positive on ordinary, non-colliding `--set` values:

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/fix-24-bru-run-token-collision/examples/pompom-time
../../bin/bru-run create --env dev --set name=widget
```

Expected: no collision error — proceeds exactly as it did after #23's fix (no "not valid JSON" error, no collision abort; fails later only on DNS if `bru` is installed and attempts the network call, or builds the temp request successfully). Inspect the temp file (same technique as above) and confirm `name` is `widget`, and `quantity`/`note` still hold their unresolved `{{defaultQuantity}}`/`{{warehouseCode}}` placeholders, matching #22/#23's already-verified behavior — this fix must not regress that.

- [ ] **Step 8: Manual test — a --data value that collides (not just --set)**

The issue's reproduction uses `--set`, but the vulnerability is in `bruRun`'s shared post-patch body, which both `--data` and `bruPatchBody` write into. Confirm `--data` triggers the same protection:

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/fix-24-bru-run-token-collision/examples/pompom-time
../../bin/bru-run create --env dev --data '{"orderRef": "9000000011"}'
```

Expected: same collision abort as Step 6, confirming the check covers both patch paths (it's positioned after both `--data` and `bruPatchBody` have run, so it should — this step proves it rather than assumes it).

- [ ] **Step 9: Manual test — a value containing token digits as a substring, not an exact match**

The issue notes "a 10-digit number in a value is not rare" — confirm the check also catches a token embedded inside a longer value, not just an exact match:

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/fix-24-bru-run-token-collision/examples/pompom-time
../../bin/bru-run create --env dev --set name=trace-9000000011-end
```

Expected: collision abort, same as Step 6 — the occurrence-counting check (Step 4) counts substring occurrences, not just exact-value matches, so this should already work without any special-casing. Confirms the fix handles the "substring inside a longer string" case the same way #22/#23's original collision guard already did for the pre-patch case.

- [ ] **Step 10: Grep diff for moz/app-api, then commit**

```bash
cd /Users/nathpaiva/www/labs/bru-run/.claude/worktrees/fix-24-bru-run-token-collision
git diff -- lib/bru-run.sh | grep -iE 'moz|app-api'
```
Expected: no output.

```bash
git status
```
Confirm only `lib/bru-run.sh` is modified (no leftover temporary edits from Steps 6-9's mutation testing — all of those used `git stash`/manual revert, which should leave a clean tree once popped/reverted).

```bash
git add lib/bru-run.sh
git commit -m "fix: detect and reject --set/--data values that collide with internal tokens"
```

---

## Self-Review Notes

**Spec coverage:** issue #24's root cause (guard only scans pre-patch body) ✅ addressed by moving the check to run post-patch. Issue's own reproduction (tokens `9000000011`/`9000000021`, `--set name=order-9000000011`) ✅ is the primary regression test (Step 6). Issue's "Idea for a fix" (scan --set/--data values with the same while loop) — this plan takes a different but equivalent-in-outcome approach: rather than scanning values before they're known (which would require restructuring when `bruPatchBody` runs relative to token generation, a much larger change), it detects the resulting collision after the fact and aborts. This is a deliberate design choice already approved by the user during brainstorming, not a plan defect — documented in the Architecture section and the code comment in Step 4.

**Placeholder scan:** none — every step has literal commands, literal code, literal expected output.

**Type consistency:** N/A — no new function signatures; this task adds a few lines of logic inside the existing `bruRun` function, reusing the `varTokens`/`body` variables already in scope from the swap-out code earlier in the same function.

**Scope discipline:** single-function fix, no new files, no automated test framework introduced, no changes to `bruPatchBody` or the swap-out logic (both already correct for what they do — only the gap between patch and restore needed a new check). Matches the size and shape of the #22/#23 fix.
