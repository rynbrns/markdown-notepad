# CI cost and local fallback

GitHub-hosted macOS runners bill at the 10x multiplier on private repositories.
The account that owns this repository has a hard Actions budget, so a failing or
duplicated macOS job can block every open pull request. Treat macOS minutes as a
scarce resource.

## Trigger policy

`CI` (`.github/workflows/ci.yml`) runs on:

| Event | Linux core job | macOS app + UI job |
| --- | --- | --- |
| Pull request opened or updated | yes | yes |
| Push to `main` | yes | yes |
| Manual dispatch (`workflow_dispatch`) | yes | yes |
| Push to any other branch | no | no |

A push to a feature branch starts no run by itself. Push the branch and open (or
update) a pull request; the `pull_request` event is the single run for that
commit. If you need a Linux-only check before opening a pull request, run the
commands below locally, or use `workflow_dispatch` and accept that it also runs
macOS.

`concurrency.group` is keyed on the commit SHA (`pull_request.head.sha` for pull
requests, otherwise `github.sha`) with `cancel-in-progress: true`. If a push and
a pull-request event ever describe the same commit, only one run survives.

The `Release` workflow still runs only on `v*` tags or manual dispatch. It is not
part of the pull-request path.

## Cost accounting

Measured on 2026-10-22 before this policy:

- 93 workflow runs in 112 minutes.
- 89 completed macOS jobs = 132.9 runner-minutes.
- At the 10x macOS multiplier that is about **1,329 billable minutes**, enough
  to exhaust the budget while several pull requests were still open.

The old `CI` definition ran the XCUITest suite twice per macOS job: once as the
single `test08AppIconInDockAndFinder` evidence step and again as the full suite.
Both invoked `xcodebuild test` and built the same app. The evidence step is now
gone; `test08AppIconInDockAndFinder` is part of the full suite, and a follow-up
step asserts it actually passed in the single run.

The temporary `RYA-16 UI probe` workflow (`.github/workflows/rya16-ui-probe.yml`,
commit `b2dfbe8` on `feature/rya-16-blank-window`) ran the same macOS build on
every push to that branch. That commit was force-pushed out of the branch tip,
but GitHub still listed the workflow as active. It is disabled and must not be
reintroduced. Use the `CI` artifacts from a pull request instead of a second
workflow.

## What the jobs prove

- `linux-core` (`ubuntu-latest`, `swift:6.2`): `MarkdownCore` has no UI imports
  and `swift test` passes on Linux.
- `macos-app` (`macos-14`, 20-minute timeout): `swift test` passes on Darwin,
  XcodeGen regenerates the project, the arm64 Debug build succeeds, the icon and
  document-type verifiers pass, and the full XCUITest smoke + screenshot suite
  runs exactly once.
- `macos-ui-test-artifacts`: `TestResults.xcresult`, `xcodebuild-test.log`,
  `document-type-verification.md`, and `app/.ui-screenshots`.

## Local fallback (no GitHub minutes)

### Linux core checks

Requires a Swift 6.x toolchain (tested with Swift 6.2):

```bash
./scripts/check-core-imports.sh
swift test
```

### macOS build and UI checks

Requires macOS 14+, Xcode 15.4+, and `brew install xcodegen`. Run from the
repository root.

```bash
swift test
xcodegen generate --spec app/project.yml

xcodebuild \
  -project app/MarkdownNotepad.xcodeproj \
  -scheme MarkdownNotepad \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath app/.derivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

app="$(find app/.derivedData/Build/Products/Debug -maxdepth 1 -type d -name 'MarkdownNotepad.app' -print -quit)"
./scripts/verify-app-icon.sh "$app"
./scripts/verify-document-types.sh "$app" || true
```

The `|| true` on the document-type check is only for a local run on a machine
where Launch Services has not registered the app yet; CI does not ignore that
failure.

Run the full UI suite locally exactly as CI does:

```bash
rm -rf app/TestResults.xcresult
SCREENSHOT_DIR="$PWD/app/.ui-screenshots" \
ICON_EVIDENCE_APP="$PWD/app/.derivedData/Build/Products/Debug/MarkdownNotepad.app" \
xcodebuild test \
  -project app/MarkdownNotepad.xcodeproj \
  -scheme MarkdownNotepad \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath app/.derivedData \
  -resultBundlePath app/TestResults.xcresult \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee app/xcodebuild-test.log

grep -q "test08AppIconInDockAndFinder.*passed" app/xcodebuild-test.log
```

A single test can be narrowed locally with `-only-testing`, for example:

```bash
xcodebuild test ... \
  -only-testing:MarkdownNotepadUITests/MarkdownNotepadUITests/test08AppIconInDockAndFinder
```

Inspect artifacts locally:

```bash
xcrun xcresulttool get test-results summary --path app/TestResults.xcresult
open app/TestResults.xcresult
ls app/.ui-screenshots
```

## Rules

- Do not add a second macOS workflow for a feature branch.
- Do not push a probe workflow to get UI evidence; use the pull-request run.
- Keep macOS work on pull requests, `main`, and manual dispatch only.
- Keep one `xcodebuild test` invocation per macOS job.
- Keep `timeout-minutes` at 10 for Linux and 20 for macOS unless a measured need
  is recorded here.
