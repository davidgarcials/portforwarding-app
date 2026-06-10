---
status: in_progress
approved_at: "2026-06-10T09:01:43.141Z"
updated: "2026-06-10T09:09:59.616Z"
started_at: "2026-06-10T09:09:59.616Z"
---
# Feature: Header App Menu (gear button → dropdown)

Date: 2026-06-10
Status: Approved

## Problem

App-level / meta actions are scattered or missing in the menu bar dropdown
(`MenuBarView`). Today the gear button opens Settings directly, Quit is a
standalone button at the bottom, and there is no way to reach the repository,
release notes, or trigger an on-demand update check. We want a single,
professional "app menu" surfaced from the existing gear button.

## Decision

Turn the existing header gear button into a SwiftUI `Menu` trigger. Left-clicking
the gear opens a grouped dropdown instead of opening Settings directly. Settings
and Quit become items inside this menu. No second menu-bar icon is added — the
change is integrated into the existing `MenuBarExtra` / `MenuBarView`.

**Menu structure (grouped into sections with dividers):**

| Original item | Professional name | Action |
|---|---|---|
| Link al repo | **View on GitHub** | `NSWorkspace.shared.open(updateChecker.repoURL)` |
| Change log | **Release Notes** | `NSWorkspace.shared.open(updateChecker.releasesURL)` |
| Check updates | **Check for Updates…** | `Task { await updateChecker.checkForUpdate() }` |
| Settings | **Settings…** | `NSApp.activate(...)` + `openWindow(id: "settings")` |
| Quit | **Quit Port Forwarding** | `manager.disconnectAll()` + `NSApplication.shared.terminate(nil)` |

```
[gear ▾]
  Resources
    View on GitHub
    Release Notes
  ──────────────
    Check for Updates…
  ──────────────
    Settings…
  ──────────────
    Quit Port Forwarding
```

- "Change log" points to the GitHub **Releases** page (no CHANGELOG file to maintain).
- The standalone bottom Quit button is **removed** (Quit now lives in the gear menu).

## Alternatives Considered

- **Second menu-bar icon (separate status item):** a dedicated "•••" icon next to
  the network icon. Rejected — user wants it integrated into the existing menu.
- **New "•••" button alongside the gear:** add a second header button. Rejected —
  user wants the existing gear button itself to open the menu.
- **Inline "More" section (always-expanded rows at the bottom):** rejected — not a
  "button that opens a menu", and it makes the dropdown taller.
- **Local bundled CHANGELOG.md shown in-app:** rejected (YAGNI) — release notes
  already live on the GitHub Releases page.

## Architecture Context

- SwiftUI `MenuBarExtra` (`.window` style) → content view `MenuBarView`
  (`PortForwardingApp.swift:25`).
- `MenuBarView.headerSection` (`MenuBarView.swift:39-55`) holds the title, connected
  count, and the gear `Button` that today calls `openWindow(id:"settings")`.
- Standalone Quit lives in `bottomSection` (`MenuBarView.swift:110-117`).
- `UpdateChecker` (Domain, in `PortForwardingLib`) owns the GitHub `repo` slug and
  `checkForUpdate()` (`UpdateChecker.swift:23,31,50`) — single source of truth for
  repo URLs. View layer is NOT unit-testable; Domain is, via custom `TestRunner`
  (`make test`).

## Research Findings

- Target macOS 14 (`Package.swift` `.macOS(.v14)`) — all APIs below available.
- `.menuStyle(.borderlessButton)` is **deprecated** (macOS 11–27). Use Apple's
  documented replacement: `.menuStyle(.button)` + `.buttonStyle(.borderless)`.
- `.menuIndicator(.hidden)` hides the disclosure chevron → gear stays an icon.
- `Section("Title") { … }` inside `Menu` renders visible grouped sections (macOS).
- URL opening uses SwiftUI `@Environment(\.openURL)` (no `NSWorkspace` dependency).
- `UpdateChecker` is `@MainActor`; tests construct it inside `await MainActor.run { … }`
  (matches existing async tests). URL props follow the existing `URL(string:)!` style
  (`UpdateChecker.swift:87`).

## Security Considerations

- None — opens only fixed `https://github.com/<repo>` URLs from the compiled-in
  slug. No user input, no auth, no data exposure.

## Performance Considerations

- None — UI wiring only. "Check for Updates…" reuses the throttled `checkForUpdate()`
  (guards on `isChecking`), invoked only on explicit click.

## Steps

### Step 1: Derive repo URLs on UpdateChecker (single source of truth)
- **Test:** `Sources/TestRunner/main.swift` — assert `repoURL`/`releasesURL` build the
  correct GitHub URLs. Append before the final results summary, in the flat
  `testAsync` style.
- **Implement:** `Sources/Domain/UpdateChecker.swift` — two public computed props from
  the existing private `repo`.
- **Code:**
  ```swift
  // UpdateChecker.swift — add near currentVersion
  public var repoURL: URL {
      URL(string: "https://github.com/\(repo)")!
  }

  public var releasesURL: URL {
      repoURL.appendingPathComponent("releases")
  }
  ```
  ```swift
  // TestRunner/main.swift — new section before the summary
  print("\n=== UpdateChecker URL Tests ===")

  await testAsync("repoURL builds the GitHub repo URL from the slug") {
      let absolute = await MainActor.run { UpdateChecker(repo: "owner/name").repoURL.absoluteString }
      assertEqual(absolute, "https://github.com/owner/name")
  }

  await testAsync("releasesURL points to the GitHub releases page") {
      let absolute = await MainActor.run { UpdateChecker(repo: "owner/name").releasesURL.absoluteString }
      assertEqual(absolute, "https://github.com/owner/name/releases")
  }
  ```
- **Validation:** `make test` — new tests green, existing tests still pass.

### Step 2: Gear button → grouped Menu; remove bottom Quit
- **Test:** none — SwiftUI view layer is not unit-testable (`App` target excluded from
  `PortForwardingLib`). Verified via `make run`.
- **Implement:** `Sources/App/MenuBarView.swift` —
  1. Add `@Environment(\.openURL) private var openURL`.
  2. Replace the gear `Button` (`headerSection`, lines 45-51) with the `Menu` below.
  3. Delete `bottomSection` (lines 110-117) and the dangling `Divider()` preceding it
     in `body` (line 33).
- **Code:**
  ```swift
  // Replaces the gear Button in headerSection
  Menu {
      Section("Resources") {
          Button("View on GitHub") { openURL(updateChecker.repoURL) }
          Button("Release Notes") { openURL(updateChecker.releasesURL) }
      }
      Divider()
      Button("Check for Updates…") {
          Task { await updateChecker.checkForUpdate() }
      }
      Divider()
      Button("Settings…") {
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: "settings")
      }
      Divider()
      Button("Quit Port Forwarding") {
          manager.disconnectAll()
          NSApplication.shared.terminate(nil)
      }
  } label: {
      Image(systemName: "gear")
  }
  .menuStyle(.button)
  .buttonStyle(.borderless)
  .menuIndicator(.hidden)
  ```
- **Depends on:** Step 1 (`repoURL` / `releasesURL`).
- **Visual — requires human verification:** gear keeps its borderless icon look (no
  bezel, no chevron); menu opens on left-click; section header + dividers read
  cleanly; bottom Quit button gone and dropdown bottom edge looks right.
- **Validation:** `make run` — click gear, exercise each item.

## Acceptance Criteria

- [x] Clicking the header gear opens a menu (no longer opens Settings directly).
- [x] Menu shows, grouped in sections: **View on GitHub**, **Release Notes**,
      **Check for Updates…**, **Settings…**, **Quit Port Forwarding**.
- [x] View on GitHub → `https://github.com/davidgarcials/portforwarding-app`; Release
      Notes → `…/releases`.
- [x] Check for Updates… triggers `checkForUpdate()` (banner appears if an update exists).
- [x] Settings… opens the Settings window; Quit disconnects all and terminates.
- [x] Standalone bottom Quit button removed.
- [x] `make test` green (new `repoURL`/`releasesURL` tests pass).

## Out of Scope (YAGNI)

- No "You're up to date" confirmation toast for "Check for Updates…" — the existing
  `UpdateBannerView` appears only when an update is found. Deferred deliberately.

## Checklist (non-TDD cleanup)

- [ ] `swift build` clean — no deprecation warnings from menu styling.
- [ ] No leftover references to the old gear `Button` / `bottomSection`.
- [ ] README/SPEC updated only if they document the menu layout (verify; likely no change).
