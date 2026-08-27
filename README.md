<div align="center">

<img src="docs/icon.png" width="128" alt="TidyMac icon">

# TidyMac

**A native macOS cleanup, monitoring and fan-control app — written in SwiftUI.**

[![Download](https://img.shields.io/github/v/release/orbitextechlab/TidyMac?label=download&color=ED8A3C)](https://github.com/orbitextechlab/TidyMac/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![CI](https://github.com/orbitextechlab/TidyMac/actions/workflows/ci.yml/badge.svg)](https://github.com/orbitextechlab/TidyMac/actions/workflows/ci.yml)

<img src="docs/screenshot-home.png" width="820" alt="TidyMac home screen">

</div>

## Install

### One command

```bash
curl -fsSL https://raw.githubusercontent.com/orbitextechlab/TidyMac/main/install.sh | bash
```

This resolves the latest release, verifies the download against the published
SHA-256 sum, installs into `/Applications`, and clears the quarantine flag
described below. It refuses to install if the checksum does not match.

Piping a script from the internet into a shell deserves a look first —
[read install.sh](install.sh) before you run it. To pin a version or install
elsewhere:

```bash
TIDYMAC_VERSION=v0.1.0 TIDYMAC_PREFIX=~/Applications \
  bash <(curl -fsSL https://raw.githubusercontent.com/orbitextechlab/TidyMac/main/install.sh)
```

### Disk image

**[Download the latest release](https://github.com/orbitextechlab/TidyMac/releases/latest)**,
open the `.dmg`, and drag TidyMac into your Applications folder. It opens on a
double-click — no right-click trick, no `xattr` incantation.

With `gh`:

```bash
gh release download --repo orbitextechlab/TidyMac --pattern '*.dmg'
hdiutil attach TidyMac-*.dmg
cp -R /Volumes/TidyMac/TidyMac.app /Applications/
hdiutil detach /Volumes/TidyMac
```

Every release also ships a `.zip` of the app bundle, which is easier to unpack in
a script than mounting a disk image, plus a `SHA256SUMS.txt` you can check with
`shasum -a 256 -c SHA256SUMS.txt`. Builds are universal — Apple Silicon and
Intel.

### Checking it really is what it claims to be

Releases from v0.2.0 on are signed with a Developer ID and notarized by Apple,
and the ticket is stapled into both the app and the disk image, so verification
works offline:

```bash
spctl --assess --type execute -vv /Applications/TidyMac.app
```

That should print `accepted` and `source=Notarized Developer ID`. Anything else
means the copy you have is not the one published here.

Releases before v0.2.0 were ad-hoc signed and are not notarized; macOS
quarantines them and reports the app as damaged until the flag is cleared with
`xattr -dr com.apple.quarantine`. Prefer a current release.

## What it does

TidyMac reclaims disk space, surfaces what your Mac is actually doing, and gives
you direct control over the fans. One window, no subscription, no telemetry.

### Cleanup

**Smart Scan** makes a single pass over every cleanup category and reports what
it found before touching anything. Nothing is ever deleted without you selecting
it first.

| Category | What it collects |
|---|---|
| User Caches | `~/Library/Caches` |
| Application Logs | `~/Library/Logs` |
| Crash Reports | Diagnostic reports left by crashed apps |
| Xcode Junk | DerivedData, device support, simulator caches |
| Developer Caches | npm / gradle / CocoaPods — re-downloaded on demand |
| Package Caches | pnpm store, pip, Homebrew, Maven, Gradle daemon, bun, uv, conda, NuGet — refetched by each tool |
| Mail Downloads | Local copies of attachments still on the mail server |
| Xcode Archives | Archives with dSYMs — needed to symbolicate shipped builds |
| iOS Backups | Device backups |
| Old Downloads | Files in `~/Downloads` untouched for 30+ days |
| Trash | Emptying deletes permanently |

Categories that can destroy something you still want carry an explicit warning
in the UI and are never selected by default.

Alongside Smart Scan there are focused tools:

- **Large Files** — ranks what is taking up the most space in Downloads, Documents
  and Desktop. The folders are fixed on purpose: "is this big thing still wanted?"
  is only a sensible question about files you put somewhere yourself. Applications
  are never listed — removing one is the Uninstaller's job, which handles the
  support files too
- **Duplicates** — groups by size first, then confirms with a streaming SHA-256, so identical-size-but-different files are not reported as duplicates
- **Space Lens** — treemap of where the space actually went
- **Uninstaller** — removes an app *and* the support files it leaves behind

**Schedule** (Settings → Schedule) repeats Smart Scan weekly or monthly. It scans
and reports; unattended cleaning stays off until you tick categories one at a
time, and only categories that always regenerate can be ticked at all. Schedules
run while TidyMac is open — a window missed while the app was closed runs once
the next time you open it, never several times over to catch up.

### Speed

- **Maintenance** — purge inactive RAM, flush the DNS cache, reindex Spotlight,
  thin local Time Machine snapshots, empty the Trash. Each task states plainly whether
  it needs administrator rights.
- **Startup Items** — see and disable what launches at login
- **Processes** — live CPU and memory per process

### Hardware

- **Fans** — read current RPM and drive fans manually or from a temperature
  ramp. Every target RPM is clamped to the range the fan itself reports, so
  TidyMac cannot ask the hardware for a speed it does not support. Every write
  is read back and verified; if another fan tool keeps overriding the commands
  TidyMac names it, and if the firmware itself refuses outside control — some
  macOS versions block fan writes entirely — TidyMac says so and returns the
  fans to automatic instead of showing controls that do nothing.
- **Sensors** — temperatures and power readings straight from the SMC

### Protection

- **Permissions** — a readable view of what TidyMac needs and why, including
  Full Disk Access
- **Every deletion passes one gate.** Each screen declares the folders it is
  entitled to touch, and `DeletionGuard` refuses anything outside them. It also
  refuses cloud sync state outright — iCloud Drive, Dropbox, OneDrive and the
  File Provider databases are never junk, whatever a scanner thinks — resolves
  symlinks and deletes through the resolved path, then re-resolves immediately
  before removing, so a path swapped mid-operation aborts rather than being
  followed somewhere else.

Cleaning moves things to the Trash. Only the Trash category deletes for real,
and a permanent, privileged delete is never silently escalated to: it is a
separate step you confirm, re-checked against the same gate.

### Menu bar

Temperature, fan speed, the fan presets and the CPU/memory/disk meters without
opening the window — plus purgeable space named rather than counted as free, the
last scan and what it found, the next scheduled run, and a Scan Now that needs no
main window.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15 or later to build
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — the `.xcodeproj` is
  generated from `project.yml` and is not committed

Developed and tested on Apple Silicon. Intel Macs use different SMC keys for
fan and sensor data; those paths are untested and reports are welcome.

## Building

```bash
git clone https://github.com/orbitextechlab/TidyMac.git
cd TidyMac
brew install xcodegen
xcodegen generate
open TidyMac.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project TidyMac.xcodeproj -scheme TidyMac -configuration Release build
```

The project is configured for **ad-hoc signing** (`CODE_SIGN_IDENTITY = "-"`) so
it builds on any machine without a Developer ID. That also means a build you
hand to someone else is not notarized, and macOS Gatekeeper will refuse to open
it on first launch — right-click the app and choose **Open** to get the override
dialog. If you have a Developer ID, set it in `project.yml` and regenerate.

## How the privileged parts work

TidyMac is **not sandboxed**. It reads the SMC through IOKit, deletes files
outside its own container, and runs a handful of system commands as root. Two
mechanisms are involved, and both are worth understanding before you trust it:

- **`AdminRunner`** wraps `osascript` with administrator privileges. macOS shows
  its own authentication dialog; TidyMac never sees your password.
- **`smc-helper`** is a small command-line tool bundled inside the app that does
  the actual SMC writes. Installing it (optional, from Settings) lets fan
  changes apply without re-authenticating every time.

Writing to the SMC is inherently low-level. The RPM clamping described above is
the safety net, but if you are uncomfortable with an app touching fan control,
simply do not use that section — everything else works without it.

## Architecture

```
Sources/
  TidyMac/
    App/          AppState, Navigation, app entry point
    Views/        One SwiftUI view per sidebar section + shared Components
    Services/
      Cleaner/    CleaningEngine, DeletionGuard, duplicates, large files, Space Lens, uninstaller
      FanControl/ Fan rules, presets, the control loop
      Monitoring/ Sensor and system metric polling
      Privileged/ AdminRunner, helper install, notifications
      Protection/ Permission checks
      SMC/        SMCKit — IOKit interface to the SMC
      Speed/      Maintenance tasks, scheduler, processes, startup items
  smc-helper/     Privileged CLI that performs SMC writes
Design/AppIcon/   Icon source (SVG + generator script)
```

Three deliberate choices worth knowing about:

- `Navigation` is a separate `ObservableObject` from `AppState`. `AppState`
  publishes metrics every couple of seconds; anything observing it rebuilds on
  every tick. The navigation shell observes only `Navigation`, so long scrolling
  lists do not hitch.
- Scanners and `DeletionGuard` are independent on purpose. A scanner decides
  what to *offer*; the guard decides what may actually be removed, and it does
  not take the scanner's word for it. Adding a scanner means declaring which
  `Scope` it is entitled to — not widening the guard.
- The design language lives in `Views/Components/Theme.swift` — warm charcoal
  surfaces, one orange accent, depth from hairline borders and glows rather than
  shadows. Use those tokens instead of hard-coding colors.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).

TidyMac deletes files and writes to hardware control registers. It ships without
warranty of any kind, as stated in the license. Read what a scan found before
you clean it.
