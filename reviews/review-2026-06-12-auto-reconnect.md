---
date: "2026-06-12"
author: "david.garcia"
reviewers: "Multi-Agent (security, performance, architecture, simplicity, silent-failure, test-quality, data-safety)"
branch: "feat/auto-reconnect-on-drop"
target_ref: "feat/auto-reconnect-on-drop @ post-review fixes"
confidence_threshold: "70"
validated: "true"
status: "open"
---
# Code Review: Auto-reconnect on port-forward drop

**Target:** Branch `feat/auto-reconnect-on-drop` (diff vs `main`)
**Reviewers:** 7 agnostic agents (no Swift-specific reviewer in roster). Findings validated against source by the orchestrator; false positives and pre-existing/out-of-scope items separated out.

## Summary
- **P1 fixed:** 1 (reconnect stuck in `.starting` on cancel-during-sleep)
- **P2/P3 fixed:** 2 (0-attempt range trap; over-tolerant config decode masking corruption)
- **Validated false positives:** 1 (`Task {}` actor isolation)
- **Pre-existing / out-of-scope (deferred, not introduced by this diff):** 4
- **Tests:** 74 passing (added toggle-off-during-reconnect; strengthened round-trip)

---

## P1 - Fixed (was a real, reachable bug)

### [BUG-1] Reconnect stuck in `.starting` when cancelled during the retry sleep
**File:** `Sources/Domain/ForwardManager.swift` (startReconnect)
**Confidence:** 92 (raised by 5 of 7 reviewers)
**Issue:** The cancellation teardown (`.stopped`) lived only after `await connect()`. A task cancelled while in `try? await Task.sleep` returns at the earlier `if Task.isCancelled` guard, skipping teardown. Manual `disconnect()` masked this (it sets `.stopped` itself), but **toggling auto-reconnect OFF** (`cancelAllReconnects`) does not — so a mid-sleep reconnect would leave the forward showing "Connecting…" forever.
**Fix:** Moved teardown into a `defer` that runs on every exit and tears down when `Task.isCancelled`. Added regression test `autoReconnect toggled OFF during reconnect stops the forward`.

---

## P2/P3 - Fixed

### [BUG-2] `1...maxReconnectAttempts` traps when attempts == 0
**File:** `Sources/Domain/ForwardManager.swift` (startReconnect loop)
**Confidence:** 90
**Issue:** `1...0` is an invalid `ClosedRange` → runtime trap if `maxReconnectAttempts` is ever injected as 0.
**Fix:** `0..<maxReconnectAttempts` (identical iteration count for N≥1, safe empty range for 0).

### [DATA-1] Over-tolerant config decode masks corruption in `workspacePaths`
**File:** `Sources/Domain/ConfigStore.swift` (AppConfig.init(from:))
**Confidence:** 88
**Issue:** Using `decodeIfPresent ?? []` for `workspacePaths` meant genuine corruption (missing/garbage) silently became an empty list instead of surfacing.
**Fix:** Only `autoReconnect` is tolerant now; `workspacePaths` is required again (`decode`). Migration safety for legacy files (which always have `workspacePaths`) is unchanged and still tested.

---

## Validated False Positives (no change)

### [TYPE-1] "reconnect `Task {}` is not `@MainActor`-isolated → data race"
**Confidence of dismissal:** high.
A `Task {}` created inside a `@MainActor` method inherits main-actor isolation. This matches the existing `connectAllTask`/`healthCheckTask` pattern and is confirmed by the passing concurrency tests. No change; staying consistent with the codebase.

---

## Pre-existing / Out-of-Scope (deferred — NOT introduced by this feature)

These are real observations but predate this branch; fixing them is separate scope.

| Ref | File | Issue | Note |
|-----|------|-------|------|
| PERF-1 | `ForwardManager.runHealthCheck` + `PortChecker` | Synchronous TCP probe on the MainActor every 10s (O(N) forwards × 1s timeout) can stutter the UI | Pre-existing health-check design |
| SEC-1 | `ProcessRunner.handleTermination` → `.failed(reason)` | kubectl stderr embedded verbatim in UI state could surface credential/token fragments | Pre-existing; consider truncating/sanitising the reason string |
| SILENT-1 | `ConfigStore.saveAppConfig` (`try?`) | Persistence write errors silently dropped (now also affects the toggle) | Pre-existing pattern; needs a UI surface to fix properly |
| PERF-2 | `startReconnect` | No exponential backoff between attempts | Enhancement; bounded loop already terminates at `.failed` (no infinite cycling — terminal state has no runner → no further callbacks) |

### Possible follow-up tests (coverage gaps, non-blocking)
- Health-check-driven drop path with auto-reconnect ON (needs a real/fakeable port probe).
- Reconnect-after-successful-reconnect (second drop).
- `KubectlCredentialRefresher.refresh()` has no timeout — a hung `kubectl cluster-info` keeps a reconnect task suspended (cancellation can't interrupt an untimed continuation). Pre-existing; would warrant a process-level timeout.

## Recommended Actions
1. **Done:** P1 + P2/P3 fixes committed with a regression test.
2. **Consider (separate change):** sanitise kubectl stderr before showing it in the UI (SEC-1); add a timeout to the credential refresh; move the health-check TCP probe off the MainActor (PERF-1).
