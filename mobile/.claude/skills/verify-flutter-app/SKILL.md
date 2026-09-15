---
name: verify-flutter-app
description: >-
  Verify JustClick POS Flutter changes by driving the LIVE running app instead of writing tests.
  Use this whenever you need to confirm a feature works, check that a screen renders correctly,
  reproduce a bug, or sanity-check an edit — on the iOS simulator, macOS desktop, or Chrome web.
  Trigger on requests like "run the app", "coba di simulator", "check it renders", "does this
  work", "screenshot the screen", "verify this change", or any time you finish an edit and would
  otherwise reach for a widget/integration test. Per this project's testing policy we do NOT
  write widget/integration/E2E tests per feature — this live-verification loop replaces them.
  Covers the dart MCP flow (iOS sim / macOS) and Playwright flow (Chrome web).
---

# Verify JustClick POS in the live app

This skill captures how to verify a Flutter change by running the actual app and inspecting it,
rather than writing a test. It exists because of the project testing policy
([.claude/rules/testing-policy.md](../../rules/testing-policy.md)): per-feature widget/integration/E2E
tests were too token-expensive, so live verification via MCP tools is the default. Unit tests for
pure data logic are still written; this skill is about everything you'd otherwise cover with a
widget or E2E test.

## Pick the platform from the user's instruction — don't assume

The user tells you which platform per task. If they haven't said, ask. Rough guide:
- **macOS desktop** — fastest iteration, best for the ≥900dp split layout. No icon caveats.
- **iOS simulator** — when the change is iOS-specific or the user asks for iPhone.
- **Chrome web** — when the change targets web; driven with Playwright (see the web section).

`list_devices` returns the concrete IDs. For JustClick POS the usual set is an iOS sim UUID, `macos`,
and `chrome`.

---

## Simulator / macOS workflow (dart MCP)

Prefer the `dart` MCP tools over raw shell — that's what this server is for. The happy path:

### 1. Launch
- `mcp__dart__list_devices` → get the device ID you need.
- `mcp__dart__list_running_apps` → if the app is already up, reuse its DTD URI instead of relaunching.
- `mcp__dart__launch_app({ root: "/Users/daniryckidinata/project/nti_pos", device: "<id>" })`
  → returns `{ dtdUri, pid }`. Keep **both**: `dtdUri` for the daemon, `pid` for logs. First iOS
  build takes ~15s (Xcode build); macOS is faster.
- **If you need to tap/type/scroll** (drive a flow, not just look), launch with
  `target: "lib/main_driver.dart"` instead. That entrypoint already exists and calls
  `enableFlutterDriverExtension()`; the default `lib/main.dart` does **not**, so `flutter_driver`
  taps fail against it with "driver extension is not enabled". Relaunch with the driver target the
  moment you realise you need interaction — don't fight the plain entrypoint.

### 2. Connect the daemon — REQUIRED before inspecting
`mcp__dart__connect_dart_tooling_daemon({ uri: "<dtdUri from launch>" })`.
`get_runtime_errors` and `get_widget_tree` **fail without this**. If you lose the connection,
request a fresh URI (from `list_running_apps`) and reconnect — don't reuse a stale one.

### 3. Verify — the three checks
Run these together; they answer "did it work" without any test file:
- `mcp__dart__get_runtime_errors` → expect "No runtime errors found." Any exception here is your bug.
- `mcp__dart__get_widget_tree({ summaryOnly: true })` → confirms which screen is mounted and its
  structure. **This output is large** (~90KB on the POS page) and gets saved to a file. Don't read
  the whole thing — `grep` it for the user-code widgets you care about:

  ```bash
  grep -oE '"(LoginPage|PosPage|MainShell|GridView|NavigationBar|ProductCard|CartPanel)"' <saved-file> | sort | uniq -c
  ```

- **Screenshot for visual truth** — the widget tree can't tell you it *looks* right. The dart MCP
  has no iOS screenshot tool, so use simctl, then Read the PNG:

  ```bash
  xcrun simctl io <device-id> screenshot <scratchpad>/sim.png
  ```

  For macOS, use `screencapture`. Reading the image is what catches things a test never would —
  e.g. a product falling back to its icon because its Unsplash URL rotted.

### 4. Drive interactions (only when launched with the driver target)
`mcp__dart__flutter_driver` taps/types/scrolls. Two rules learned the hard way:
- **Find real targets first.** Get the widget tree, then select by what's actually there — a nav
  label with `finderType: "ByText"`, a widget's `runtimeType` with `"ByType"`, a `ValueKey` with
  `"ByValueKey"`. Don't guess selectors.
- **Do NOT pass `timeout`.** The MCP tool has a bug where the integer `timeout` triggers
  `type 'int' is not a subtype of type 'String?'` and the whole call fails. Omit it and the tap
  works; the driver has its own default wait.

  ```
  mcp__dart__flutter_driver({ command: "tap", finderType: "ByText", text: "Dashboard" })
  ```

  After each interaction, re-run the step-3 checks (runtime errors + screenshot) to confirm the
  result. For text entry use `command: "enter_text"` with `text`; for lists `scrollIntoView`.

### 5. Iterate after an edit
`mcp__dart__hot_reload({ clearRuntimeErrors: true })` applies code changes while keeping app state
(note: `const` globals and some top-level changes need `hot_restart`). Then re-run the three checks.

### 6. Logs when something's off
`mcp__dart__get_app_logs({ pid: <pid>, maxLines: 40 })` — the flutter run event stream (build
progress, `app.started`, prints). Reach for this when launch or a reload behaves unexpectedly.

### 7. Clean up
Leave the app running if the user is mid-iteration. When done, `mcp__dart__stop_app` (or leave it
and tell the user the pid).

### iOS icon caveat
`launch_app` uses `flutter run`, which can't pass `--no-tree-shake-icons`. Standard `Icons.*`
render fine, but the `_outlined` / `_rounded` variants can tofu on the iOS sim. If you see tofu
boxes where icons should be, that's the tree-shake issue — verify on macOS, or use the documented
`flutter build ios --no-tree-shake-icons` + `simctl install` pattern from CLAUDE.md. Emoji never
render on the iOS sim regardless — that's why the app uses Material icons via `iconFromKey`.

---

## Web workflow (Playwright / Chrome)

Web is the channel the app gets demoed on (static bundle + ngrok), so verify here whenever the
change could affect it.

### Serve

```bash
flutter build web --release
(cd build/web && python3 -m http.server 8899)
```

Then `browser_navigate({ url: 'http://localhost:8899/index.html' })`.

### Three things that will mislead you

1. **The service worker serves the previous build.** Your fix will look like it did nothing. Always
   clear it before judging a change — this is the single biggest time-waster on this path:
   ```js
   const r = await navigator.serviceWorker.getRegistrations(); for (const x of r) await x.unregister();
   const k = await caches.keys(); for (const c of k) await caches.delete(c);
   ```
   Then `page.reload()`. (Serving each build on a *fresh port* also side-steps stale state.)
2. **Release builds hide the error.** Flutter's release `ErrorWidget` is a blank box, so a crash
   renders as a plain white page with no console error. When you hit white, re-run with
   `flutter run -d web-server --web-port=8900` and read the exception in
   `browser_console_messages({ level: 'debug', all: true })` — debug builds log the full Dart stack.
3. **`browser_snapshot` is nearly useless here.** Flutter renders to canvas, so the accessibility
   tree is just an "Enable accessibility" button. Use `browser_take_screenshot` as the source of
   truth and read it back with the `Read` tool.

### Driving a canvas app

There are no DOM elements to click, so `browser_click` by ref/selector does not work. Use
`browser_run_code_unsafe` with `page.mouse.click(x, y)`, reading coordinates off a screenshot:

```js
async (page) => {
  await page.setViewportSize({ width: 1280, height: 900 });   // ≥900dp = split layout
  for (const [x, y] of [[527,403],[640,403],[753,403],[527,486]]) {  // PIN 1234, centred pad
    await page.mouse.click(x, y); await page.waitForTimeout(200);
  }
  await page.waitForTimeout(4000);
  await page.screenshot({ path: '.playwright-mcp/step.png' });
}
```

Coordinates shift with viewport width (the login pad is centred), so re-screenshot after a resize
rather than reusing numbers.

### Always check both sides of the breakpoint

Layout-dependent bugs hide on one side only. The double-pop crash in `CheckoutSheet._placeOrder`
(see CLAUDE.md Gotchas) passed at 480px and blanked the app at 1280px. When a change touches
navigation, sheets, or layout, run the flow at **both** ~480px and ~1280px.

### Worth exercising end to end

Login (PIN `1234`) → catalog loads with photos → add item → Takeaway (skips the table picker) →
Checkout → Place Order → success receipt → reload the page → Orders tab still lists the order.
That last step is the one that proves IndexedDB persistence, which is the whole point of the web
data path.

---

## What this replaces (and what it doesn't)

- **Replaces:** writing widget tests and integration/E2E tests to prove a feature works. Do that
  work here, live, instead.
- **Does NOT replace:** unit tests for pure data logic (models, repositories, formatters, cart
  math) — still write those; they're cheap and need no simulator. And do NOT delete the existing
  regression guards (`router_stability_test`, `product_card_layout_test`, `migration_test`,
  `app_e2e_test`). If you fix a recurrence-prone bug and think a small regression test is warranted,
  ask the user first — don't generate one reflexively.
