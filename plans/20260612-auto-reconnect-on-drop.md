---
status: in_progress
created: 2026-06-12
approved_at: "2026-06-12T09:41:30.582Z"
updated: "2026-06-12T09:42:28.858Z"
started_at: "2026-06-12T09:42:28.858Z"
---
# Feature: Auto-reconnect on port-forward drop (Settings toggle, default OFF)

Date: 2026-06-12
Status: Draft
Effort: M

## Problem

When an established (`.ready`) port-forward drops — the `kubectl` child dies, or
the health check sees the local port closed — the forward is marked `.failed` and
the user must reconnect manually (via the row's play button or the notification's
"Reconnect" action). Some forwards should come back automatically. We want a single
**global** Settings toggle that, when enabled, auto-reconnects dropped forwards. It
must be **disabled by default**, and a reconnect that needs re-authentication
(password / SSO) must **wait for the user**, not abort.

## Decision

Add a global `autoReconnect` flag (persisted in `config.json`, default `false`).
When ON, a drop triggers a **bounded** reconnect loop instead of going straight to
`.failed`:

- Both drop-detection paths funnel through one private `handleDrop(_:reason:)`.
- `handleDrop` → if `autoReconnect` is OFF: current behavior (`.failed` + notify).
  If ON: `startReconnect` (silent — no drop notification).
- `startReconnect` retries up to `maxReconnectAttempts` (default **5**) with
  `reconnectDelay` (default **3s**) between attempts. Each attempt calls the existing
  `connect(_:)`, which already does the credential-refresh / re-auth flow. On
  success → `.ready` (silent). On exhaustion → `.failed("Reconnect failed after N
  attempts")` **and** notify (fall back to today's behavior).
- The toggle lives in the Settings window, bound to `manager.autoReconnect`.

**Auth-wait guarantee (Boss requirement):** the credential wait happens *inside*
`connect()` → `CredentialRefresher.refresh()`, which `await`s `kubectl cluster-info`
to terminate with **no timeout**. The retry loop `await`s the *whole* `connect()`
before counting an attempt, so waiting for the user to type a password neither
consumes a retry nor gets aborted by our timer.

## Alternatives Considered

- **Unbounded retry (forever, backoff):** rejected — masks permanent failures and
  churns `kubectl` processes for a genuinely-down service. Boss chose bounded.
- **Per-forward toggle:** rejected — request is "an option in Settings" (singular);
  a global flag is simpler and matches the ask. (Per-forward stays future YAGNI.)
- **New `.reconnecting` ForwardState case:** rejected — would ripple into four
  exhaustive `switch`es (`ForwardSettingsRow`, `ForwardRowView`: color + action).
  Reusing `.starting`/`.authenticating` keeps the change minimal; UX still reads
  "Connecting…" / "Authenticating…" during a reconnect.
- **Notify on every drop even while auto-reconnecting:** rejected — Boss chose to
  silence drop notifications during retries; notify only on final give-up.

## Architecture Context

- `ForwardManager` (`@MainActor ObservableObject`, `Sources/Domain/ForwardManager.swift`)
  is the source of truth: `@Published states: [UUID: ForwardState]`, `runners`,
  health-check loop. Two drop-detection sites today:
  1. `attemptConnect` installs `runner.onTerminatedAfterReady` (~L169) → `.failed` + notify.
  2. `runHealthCheck` `.ready && !portOpen` branch (~L298) → `.failed` + notify.
- `connect(_:)` (~L140) already: sets `.starting`, attempts, on credential error sets
  `.authenticating` → `refresh()` → retries once. Reused as-is by the reconnect loop.
- `ConfigStore.AppConfig` (`Sources/Domain/ConfigStore.swift`) holds `version` +
  `workspacePaths`; `saveAppConfig` is called from `addWorkspace`/`removeWorkspace`.
- `CredentialRefresher.refresh()` runs `kubectl cluster-info`, untimed `await` → waits
  for the user to authenticate.
- Tests: custom `Sources/TestRunner/main.swift` (`make test`), flat `test()`/`testAsync()`;
  mocks `MockNotifier`, `MockRunnerFactory`/`MockProcessRunner`, `FailingMockRunner`,
  `SequentialMockRunnerFactory`, `MockCredentialRefresher`. SwiftUI views are NOT
  unit-testable (App target excluded from `PortForwardingLib`).

## Research Findings

- Default property values do NOT make synthesized `Codable` keys optional — adding a
  required `autoReconnect` would make existing 2-key `config.json` files fail to
  decode, and `loadAppConfigOrDefault()` would then return an empty config → **lost
  workspacePaths**. A tolerant `init(from:)` (`decodeIfPresent ?? false`) is required.
- Swift property observers (`didSet`) do **not** fire for assignments inside `init`,
  so initializing `autoReconnect` from config in `init` won't trigger a premature save.
- Existing `Task`-in-property analogues (`healthCheckTask`, `connectAllTask`) capture
  `self` strongly; bounded reconnect tasks self-clear via `defer`, so no leak.
- Both drop paths can fire for the same drop (process death + next health tick). A
  `guard reconnectTasks[id] == nil` in `startReconnect` dedupes; setting `.starting`
  up-front also makes the health check ignore the forward (`.starting` → `break`).

## Security Considerations

- None — no new input surface, no auth/secrets handled by us; re-auth is delegated to
  `kubectl`'s existing exec-credential flow.

## Performance Considerations

- Bounded loop caps process churn: ≤ `maxReconnectAttempts` (5) reconnect attempts per
  drop, `reconnectDelay` (3s) apart. Idle cost zero (tasks exist only during a drop).
- Health-check loop unchanged (10s); reconnects-in-flight are `.starting`/`.authenticating`
  and skipped by the health check, so no double-driving.

## Steps

### Step 1: `AppConfig.autoReconnect` with migration-safe decode
- **Test:** `Sources/TestRunner/main.swift` (ConfigStore section) — defaults to `false`;
  round-trips `true` through save/load; **legacy JSON without the key decodes to
  `false` and keeps `workspacePaths`**.
- **Implement:** `Sources/Domain/ConfigStore.swift` — add stored prop + tolerant decode.
- **Code:**
  ```swift
  public struct AppConfig: Codable {
      public var version: Int
      public var workspacePaths: [String]
      public var autoReconnect: Bool

      public init(version: Int = 1, workspacePaths: [String] = [], autoReconnect: Bool = false) {
          self.version = version
          self.workspacePaths = workspacePaths
          self.autoReconnect = autoReconnect
      }

      private enum CodingKeys: String, CodingKey { case version, workspacePaths, autoReconnect }

      // Tolerant: existing config.json predates `autoReconnect`. Missing key → false,
      // so we never fail to load and lose workspacePaths.
      public init(from decoder: Decoder) throws {
          let c = try decoder.container(keyedBy: CodingKeys.self)
          version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
          workspacePaths = try c.decodeIfPresent([String].self, forKey: .workspacePaths) ?? []
          autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
      }
  }
  ```
  ```swift
  test("legacy config without autoReconnect decodes to false and keeps workspacePaths") {
      let legacy = #"{"version":1,"workspacePaths":["/tmp/ws1","/tmp/ws2"]}"#
      let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
      assertEqual(cfg.autoReconnect, false)
      assertEqual(cfg.workspacePaths.count, 2)
  }
  ```
- **Constraint (compat):** must not break the existing "AppConfig save and load round-trip"
  / "returns empty when no file" tests.
- **Validation:** `make test`.

### Step 2: `ForwardManager.autoReconnect` — published, persisted, injectable knobs
- **Test:** `Sources/TestRunner/main.swift` — setting `autoReconnect` persists to
  `config.json`; a manager built over a config with `autoReconnect:true` initializes ON.
- **Implement:** `Sources/Domain/ForwardManager.swift` — new props, `init` wiring,
  `saveAppConfig` update. (`maxReconnectAttempts`/`reconnectDelay` added here, used in Step 3.)
- **Code:**
  ```swift
  @Published public var autoReconnect: Bool {
      didSet {
          saveAppConfig()
          if !autoReconnect { cancelAllReconnects() }   // stop retrying when turned off
      }
  }
  private let maxReconnectAttempts: Int
  private let reconnectDelay: TimeInterval
  private var reconnectTasks: [UUID: Task<Void, Never>] = [:]

  public init(
      configStore: ConfigStore,
      runnerFactory: ProcessRunnerFactory = DefaultProcessRunnerFactory(),
      credentialRefresher: CredentialRefreshing = KubectlCredentialRefresher(),
      notifier: PortDropNotifying? = nil,
      healthCheckInterval: TimeInterval = 10,
      maxReconnectAttempts: Int = 5,
      reconnectDelay: TimeInterval = 3
  ) {
      self.configStore = configStore
      // ... existing assignments ...
      self.maxReconnectAttempts = maxReconnectAttempts
      self.reconnectDelay = reconnectDelay
      self.autoReconnect = configStore.loadAppConfigOrDefault().autoReconnect  // no didSet in init
      self.workspaces = configStore.loadAllWorkspaces()
      // ... rest unchanged ...
  }

  private func saveAppConfig() {
      let config = AppConfig(workspacePaths: workspaces.map(\.path), autoReconnect: autoReconnect)
      try? configStore.saveAppConfig(config)
  }

  private func cancelAllReconnects() {
      for (_, task) in reconnectTasks { task.cancel() }
  }
  ```
- **Depends on:** Step 1.
- **Validation:** `make test`.

### Step 3: Unify drop handling + bounded auto-reconnect loop
- **Test:** `Sources/TestRunner/main.swift` (new "Auto-Reconnect Tests" section):
  - ON: drop via `onTerminatedAfterReady` → reconnect succeeds → `.ready`, notified **0**.
  - ON: every attempt fails → `.failed("Reconnect failed after N attempts")`, notified **1**.
  - ON: attempt hits credential error, refresh succeeds → ends `.ready`, `refreshCalled`,
    notified **0** (proves reconnect goes through the auth/wait flow).
  - OFF path is already covered by the existing "Notifies when process terminates after
    ready" test (autoReconnect defaults false) — keep it green.
- **Implement:** refactor both drop sites to `handleDrop`; add `startReconnect`.
- **Code:**
  ```swift
  // attemptConnect — replace the body of onTerminatedAfterReady:
  runner.onTerminatedAfterReady = { [weak self] code, reason in
      Task { @MainActor [weak self] in
          self?.handleDrop(forward, reason: "Disconnected (exit \(code)): \(reason)")
      }
  }

  // runHealthCheck — replace the `.ready` branch body:
  case .ready:
      if !portOpen { handleDrop(fwd, reason: "Connection lost") }

  private func handleDrop(_ forward: PortForward, reason: String) {
      runners[forward.id]?.stop()
      runners[forward.id] = nil
      guard autoReconnect else {
          states[forward.id] = .failed(reason)
          notifier?.sendPortDropped(forward: forward)
          return
      }
      startReconnect(forward)
  }

  private func startReconnect(_ forward: PortForward) {
      guard reconnectTasks[forward.id] == nil else { return }   // dedupe double drop-signals
      states[forward.id] = .starting                            // UI + health check skip it
      reconnectTasks[forward.id] = Task { @MainActor in
          defer { reconnectTasks[forward.id] = nil }
          for _ in 1...maxReconnectAttempts {
              if Task.isCancelled { return }
              try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
              if Task.isCancelled { return }
              await connect(forward)                            // waits for user auth inside
              if Task.isCancelled {                             // manual disconnect / toggle-off won
                  runners[forward.id]?.stop()
                  runners[forward.id] = nil
                  states[forward.id] = .stopped
                  return
              }
              if states[forward.id] == .ready { return }
          }
          states[forward.id] = .failed("Reconnect failed after \(maxReconnectAttempts) attempts")
          notifier?.sendPortDropped(forward: forward)
      }
  }
  ```
- **Constraint (auth-wait):** do NOT add a timeout around `await connect(forward)` — the
  credential wait must be allowed to run as long as the user needs.
- **Depends on:** Step 2.
- **Validation:** `make test`.

### Step 4: Manual disconnect cancels an in-flight reconnect
- **Test:** `Sources/TestRunner/main.swift` — with a `BlockingMockRunner`, a `disconnect`
  during an in-flight reconnect attempt ends the forward in `.stopped` (not `.ready`/`.failed`).
- **Implement:** cancel the reconnect task at the top of `disconnect`; add the test mock.
- **Code:**
  ```swift
  public func disconnect(_ forward: PortForward) {
      reconnectTasks[forward.id]?.cancel()
      reconnectTasks[forward.id] = nil
      runners[forward.id]?.stop()
      runners[forward.id] = nil
      states[forward.id] = .stopped
  }
  ```
  ```swift
  // TestRunner mock: blocks startAndAwaitReady until stop() simulates kubectl termination.
  final class BlockingMockRunner: ProcessRunning {
      var onTerminatedAfterReady: ((Int32, String) -> Void)?
      private var continuation: CheckedContinuation<Void, Error>?
      func startAndAwaitReady() async throws {
          try await withCheckedThrowingContinuation { self.continuation = $0 }
      }
      func stop() {
          continuation?.resume(throwing: ProcessRunnerError.processExited(code: 15, output: "terminated"))
          continuation = nil
      }
  }
  ```
- **Note:** `disconnectAll`, `removeWorkspace`, `deleteForward` already route through
  `disconnect`, so they inherit cancellation. `cancelAllReconnects` (Step 2) covers toggle-off.
- **Depends on:** Step 3.
- **Validation:** `make test`.

### Step 5: Settings toggle
- **Test:** none — SwiftUI view layer is not unit-testable. Verified via `make run`.
- **Implement:** `Sources/App/SettingsView.swift` — add a general-settings row between the
  top toolbar and the workspace list, bound to `manager.autoReconnect`.
- **Code:**
  ```swift
  // In body, between `toolbar`/`Divider()` and `workspaceList`:
  generalSettings
  Divider()

  private var generalSettings: some View {
      HStack {
          Toggle("Automatically reconnect dropped forwards", isOn: $manager.autoReconnect)
              .toggleStyle(.checkbox)
              .help("When a connected forward drops, retry it automatically (waits for re-authentication).")
          Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
  }
  ```
- **Visual — requires human verification:** toggle renders as a native checkbox, is OFF
  on first launch, flips state, and the choice survives an app relaunch (persisted).
- **Depends on:** Step 2.
- **Validation:** `make run` — toggle ON, kill a forward's `kubectl` (or `kill <pid>`),
  confirm it auto-reconnects without a drop notification; toggle OFF, confirm a drop
  goes straight to `.failed` + notification.

## Acceptance Criteria

- [x] Settings window shows an "Automatically reconnect dropped forwards" toggle, **OFF by default**.
- [x] The setting persists in `config.json` and reloads on launch; existing configs (no key) load fine.
- [x] OFF: a dropped forward goes to `.failed` and sends one drop notification (unchanged).
- [x] ON: a dropped `.ready` forward auto-reconnects to `.ready` with no drop notification.
- [x] ON: a reconnect needing re-auth waits for the user (no abort, no wasted retry).
- [x] ON + unrecoverable: after N (5) attempts → `.failed("Reconnect failed after N attempts")` + one notification.
- [x] Manually disconnecting (or toggling the setting OFF) during a reconnect stops it cleanly.
- [x] `make test` green (new + existing tests).

## Out of Scope (YAGNI)

- **Initial-connection-failure retries** — auto-reconnect only fires on drops of an
  established (`.ready`) forward, matching "cuando *caiga* una conexión". A forward that
  never connected still goes to `.failed` via the normal `connect()` path.
- **Per-forward auto-reconnect** — global toggle only.
- **Configurable attempts/delay in the UI** — fixed defaults (5 × 3s), injectable only for tests.
- **Exponential backoff** — fixed delay is sufficient for the bounded loop.

## Checklist (non-TDD cleanup)

- [ ] `swift build` clean — no new warnings.
- [ ] `SPEC.md` — move "Auto-reconnect on tunnel drop" out of *Out of Scope (YAGNI)* and
      document the bounded-retry + Settings-toggle behavior under *Connection Orchestration*.
- [ ] `README.md` — mention the auto-reconnect setting if features are listed (verify).
- [ ] Version bump → **1.9.0** in `Resources/Info.plist` (`CFBundleShortVersionString` +
      `CFBundleVersion`); `UpdateChecker.currentVersion` reads it automatically.
