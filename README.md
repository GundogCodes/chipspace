# Chipspace

A small, local-only Mac storage inspector with a hardware-inspired interface.

Folders become chips on a proportional storage board. Select one to see its purpose, size, and removal consequences. Review recognized caches and optional downloads, move selected items to Trash, or explicitly confirm permanent deletion. Manage Xcode simulator runtimes and devices through Apple's tools in the same UI.

The visual design takes inspiration from compact music hardware: warm gray panels, a precise grid, monospace labels, and orange controls. This is an independent project, not affiliated with Teenage Engineering or Apple.

## Run

Download **Chipspace-macOS.zip** from [Releases](../../releases/latest), unzip, and double-click **Chipspace.app**. You can move it to Applications.

- macOS **12 Monterey or later**.
- Universal binary: **Apple silicon and Intel**.
- No Python, Node, Homebrew, or Xcode needed to run the app. Xcode is needed only for simulator management.
- A chip icon in the menu bar opens the dashboard or quits the local server.
- Click **Scan this Mac** for the first scan. Files are never removed by scanning.

The personal build is ad-hoc signed, not Apple-notarized. Depending on how you transfer/download it, macOS may require reviewing it under **System Settings → Privacy & Security → Open Anyway** before the first launch. Do not disable Gatekeeper or System Integrity Protection.

## What it does

- Measures common System Data contributors: app caches/support, Xcode, simulator assets, package caches, local models, logs, and system working directories.
- Shows disk usage and free space separately from mapped folder allocation.
- Avoids double-counting parents and children in the board.
- Supports search, size sorting, category filters, and inspecting nested measured folders.
- Explains known locations; unknown data stays inspection-only.
- Records scan/cleanup activity locally and compares complete measurements with the previous scan.
- Makes incomplete reads explicit. Each scan scope has a timeout.

**This is not an exact reconstruction of Apple's System Data category.** Some measured folders belong to other categories. APFS clones/snapshots and permissions affect totals; measured size is not guaranteed recoverable space. Other users and custom model/cache locations can be outside the scan. The board has a RAM-inspired appearance but represents **disk storage**.

## Cleanup behavior

The server chooses eligible paths from its own current inventory. The browser cannot submit an arbitrary deletion path. A cleanup review remeasures the exact folder and creates a short-lived, single-use confirmation ticket.

Before cleanup, quit the owning app, model server, updater, builds, or tests. Confirm this in the UI and type `TRASH` or `DELETE`. Direct cleanup is limited to an explicit policy; it refuses symlink ancestors, changed directory identities, unexpected ownership, and mount-point roots. Recursive deletion does not cross mount points. These checks do not make files universally disposable or eliminate races with other processes: stop the app first.

Moving an item to Trash is reversible but does **not** free storage immediately. Chipspace never empties your existing Trash. Permanent deletion has no undo. An Ollama store action removes **all** local models, including custom imports; back those up first. For individual Ollama models, use Ollama's own controls.

Protected system assets are never deleted as raw files. Simulator cleanup uses `xcrun simctl` with a specific UUID from live inventory. Runtime removal disables dependent devices until reinstallation; device removal destroys that device's test data. A running simulator blocks its deletion; runtime removal requires shutting down all simulated devices.

## Privacy and access

There are no accounts, cloud services, telemetry, remote fonts, or uploads. The server binds only to `127.0.0.1` on a randomly assigned port. API calls require a per-launch bearer token; unexpected Host/Origin headers are rejected. Tokens are not embedded in static assets. Browser state uses session storage, and API responses are not cacheable. This protects against ordinary cross-origin requests, not malicious software already running as your Mac user.

Reports, activity, and current measurements live in:

```text
~/Library/Application Support/Chipspace/
```

They contain local folder names. Review before sharing. For fuller coverage, add Chipspace in **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen it. Some system directories remain protected. Run as your normal user, without `sudo`.

## Build from source

Requires Xcode with the macOS SDK and Swift compiler:

```sh
./build.command
open Chipspace.app
```

The build compiles both architectures with a macOS 12 deployment target, merges them into one executable, copies the UI/scanner, and ad-hoc signs the app. The app uses AppKit, Network.framework, Foundation, and bundled macOS command-line utilities. No package install is needed.

## Verification

Run the native safety tests using disposable temporary fixtures:

```sh
Chipspace.app/Contents/MacOS/Chipspace --self-test
```

The tests cover allowed/protected paths, symlinks, changed identities, preserving targets behind internal symlinks, missing confirmation, confirmed deletion, and ticket replay rejection.

Optional HTTP tests use Python 3 **for development only**:

```sh
python3 Tests/api_checks.py "$HOME/Library/Application Support/Chipspace/connection.json"
```

These test authentication, Host/Origin isolation, traversal rejection, invalid IDs/actions, and protected locations without deleting personal data. JavaScript geometry tests run with `node Tests/board_checks.cjs` (development only).

The application has been exercised on an Apple silicon Mac. The Intel slice and macOS 12 deployment target are built and inspected, but have not been physically tested on every older macOS release or Intel hardware.

## Layout

- `Source/Chipspace.swift` — native app, localhost server, scan state, and guarded cleanup.
- `Source/engine.command` — read-only scan/report engine used by the app (also retains its standalone Terminal workflow).
- `Web/` — dependency-free browser UI.
- `Tests/` — boundary and geometry checks.
- `build.command` — universal app build.

Private scan reports and machine-specific data are excluded from the repository and release archive.
