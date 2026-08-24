# Contributing to TidyMac

Thanks for taking the time. Bug reports, hardware compatibility reports and pull
requests are all welcome.

## Getting set up

The `.xcodeproj` is generated from `project.yml` and is **not** committed, so
generate it after cloning:

```bash
brew install xcodegen
xcodegen generate
open TidyMac.xcodeproj
```

Re-run `xcodegen generate` whenever you add or remove a source file, or edit
`project.yml`. Do not commit the generated project.

## Before you open a pull request

- Build cleanly: `xcodebuild -project TidyMac.xcodeproj -scheme TidyMac -configuration Release build`
- Keep the change scoped to one thing. A PR that fixes a bug *and* restyles a
  view is two PRs.
- Use conventional commit subjects (`fix:`, `feat:`, `refactor:`, `docs:`).

## House style

- **Colors and spacing come from `Views/Components/Theme.swift`.** The app has
  one accent color and a deliberate surface hierarchy; hard-coded colors break
  it in either light or dark mode. Add a token rather than a literal.
- **Comments explain *why*, not *what*.** The existing code documents the
  reasoning behind non-obvious choices — why `Navigation` is separate from
  `AppState`, why the Trash scan includes hidden files. Match that.
- **Anything destructive needs a warning path.** If you add a cleanup category
  that can remove something the user still wants, give it a `warning` string and
  leave it unselected by default. This is the single most important rule in the
  codebase.

## Working on privileged code

`Services/Privileged/` and `Sources/smc-helper/` run as root. Changes there get
extra scrutiny, and for good reason:

- Never pass unvalidated user input into `AdminRunner`. Everything that reaches
  it must be a path or argument the app constructed itself.
- Fan RPM targets must stay clamped to the range the hardware reports. Do not
  add a code path that bypasses `FanControlEngine.clamp`.
- If you change what the helper does, say so explicitly in the PR description.

## Hardware compatibility

TidyMac is developed on Apple Silicon. Intel Macs expose different SMC keys for
fans and sensors, and those paths are largely untested. If you have an Intel Mac
and the Fans or Sensors sections misbehave, an issue with your model identifier
(`sysctl hw.model`) and what you saw is genuinely useful.

## Cutting a release

Releases are built, signed and notarized by the `Release` workflow when a
`vX.Y.Z` tag is pushed. The tag is the source of truth for the version — the
build injects it into `MARKETING_VERSION`, and the job fails if the bundle
disagrees.

That job needs five repository secrets, all belonging to the same Apple team as
the signing certificate:

| Secret | What it is |
|---|---|
| `APPLE_TEAM_ID` | Developer team ID |
| `MACOS_CERT_P12` | base64 of the exported Developer ID Application identity |
| `MACOS_CERT_PASSWORD` | password set when exporting that `.p12` |
| `APPLE_ID` | Apple ID that owns the team |
| `APPLE_APP_PASSWORD` | app-specific password from appleid.apple.com |

Two constraints in the build exist purely because notarization enforces them,
and quietly break it if changed:

- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` is `NO` for Release. Xcode otherwise adds
  `com.apple.security.get-task-allow`, and Apple rejects any binary requesting
  it. Debug keeps the injection so debugging still works.
- The step that embeds `smc-helper` re-signs it with the build's own identity.
  Signing it ad-hoc there would leave a correctly signed app wrapped around an
  unsigned binary, which notarization also rejects.

## Reporting bugs

Include your macOS version, Mac model, and what you expected versus what
happened. If it involves cleaning, say which category — and please do not paste
file listings that contain personal paths you would rather not publish.
