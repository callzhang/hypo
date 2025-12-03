# Repository Guidelines

**Project**: Hypo - Cross-Platform Clipboard Sync  
**Version**: 1.0.1 (Production Release)  
**Status**: Production-ready, all critical issues resolved  
**Last Updated**: December 2, 2025

## Project Structure & Module Organization
- `macos/`: Swift 6/SwiftUI client; shared logic under `Sources`, unit suites in `Tests/HypoAppTests`.
- `android/`: Kotlin 1.9.22 Compose app with Gradle wrapper (`android/gradlew`); feature code in `app/src/main`, tests in `app/src/test`.
- `backend/`: Rust 1.83+ relay server; request handlers in `src/handlers`, integration specs in `backend/tests`.
- `scripts/`: automation helpers such as `build-android.sh`, `build-macos.sh`, `build-all.sh`, `run-transport-regression.sh`, `setup-android-sdk.sh`.
- `tests/transport/*.json`: transport and crypto fixtures consumed by macOS and Android regression suites.
- `docs/`: comprehensive documentation (PRD, technical specs, user guides, changelog).
- `.github/workflows/`: CI/CD pipelines for automated builds, testing, and releases.

## Build, Test, and Development Commands

### Quick Build (All Platforms)
- **All platforms**: `./scripts/build-all.sh` - builds both Android and macOS apps

### macOS
- **Development build**: `./scripts/build-macos.sh` (default, debug)
- **Release build**: `./scripts/build-macos.sh release`
- **Clean build**: `./scripts/build-macos.sh clean`
- **Run tests**: `swift test` or `swift test --filter TransportMetricsAggregatorTests` for focused runs
- **Output**: `macos/HypoApp.app` bundle

### Android
- **Debug APK**: `./scripts/build-android.sh` (default, ~47MB)
- **Release APK**: `./scripts/build-android.sh release` (~15-20MB, optimized)
- **Both APKs**: `./scripts/build-android.sh both`
- **Clean build**: `./scripts/build-android.sh clean`
- **Run tests**: `cd android && ./gradlew testDebugUnitTest` runs JVM unit tests
- **Output**: `android/app/build/outputs/apk/{debug,release}/app-{debug,release}.apk`

### Backend
- **Run locally**: `cd backend && cargo run` brings up the relay
- **Run tests**: `cargo test` covers unit + integration (requires Redis from `docker compose up redis`)
- **Test with all features**: `cargo test --all-features --locked`
- **Production**: Deployed to Fly.io at https://hypo.fly.dev

### Cross-Platform
- **Transport regression**: `./scripts/run-transport-regression.sh` executes the shared transport metrics suite
- **Requirements**: `JAVA_HOME` and `ANDROID_SDK_ROOT` must be set

## Coding Style & Naming Conventions
- Swift: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` members; rely on Xcode “Editor → Structure → Re-Indent” before committing.
- Kotlin: Android Studio defaults, `UpperCamelCase` composables, resource files in `snake_case`; keep imports sorted via “Optimize Imports”.
- Rust: enforce `cargo fmt` and `cargo clippy -- -D warnings`; functions stay `snake_case`, structs `CamelCase`, modules grouped under `backend/src`.

## Testing Guidelines
- Uphold coverage targets (≥80% clients, ≥90% backend) tracked in `README.md`.
- Mirror fixture names when adding transport tests and store new data in `tests/transport`.
- macOS tests live in `HypoAppTests`; Android tests should follow `*Test` naming; backend integration tests use `cargo test --test integration_test`.
- Capture command output when running the regression script and attach snippets to reviews.
- **Backend tests**: All 33 unit tests must pass before merging (`cargo test --all-features --locked`).
- **CI/CD**: Automated testing via GitHub Actions on all pull requests.

## Commit & Pull Request Guidelines
- Follow Conventional Commits as seen in history (`feat(android): …`, `fix: …`, `docs: …`); keep subjects imperative and ≤72 chars.
- Squash exploratory commits and link tasks or issues in the PR body.
- Each PR must describe behaviour changes, list platforms touched, and note the commands executed (builds, tests, scripts).
- Exclude secrets or generated artifacts (`HypoApp.app`, `*.apk`, `target/`, `.build/`) from commits and update docs when behaviour shifts.
- **Documentation updates**: When merging feature docs into main docs (e.g., `docs/features/*.md` → `docs/prd.md`), delete the source file after merge.
- **Version updates**: Update version numbers in all relevant files (Info.plist, build.gradle.kts, Cargo.toml, docs) when releasing.

## Security & Configuration Tips
- Copy secrets from `.env.example` and keep production values in the shared vault; never commit Fly.io or signing credentials.
- Regenerate TLS fingerprints with `backend/scripts/cert_fingerprint.sh` after certificate updates.
- Prefer the repo-scoped Android SDK (`.android-sdk`) to keep builds reproducible; ensure QR pairing flows respect signed entitlements during macOS testing.
- **GitHub Secrets**: Store sensitive values (e.g., `SENTRY_AUTH_TOKEN`) in GitHub repository secrets, not in code or config files.
- **macOS Key Storage**: Uses encrypted file-based storage (`~/Library/Application Support/Hypo/`) instead of Keychain for better Notarization compatibility.

## Documentation Structure
- **Core Docs**: `docs/prd.md` (Product Requirements), `docs/technical.md` (Technical Spec), `docs/protocol.md` (Protocol Spec)
- **User Docs**: `docs/USER_GUIDE.md` (includes installation guide), `docs/TROUBLESHOOTING.md`
- **Project Status**: `changelog.md` (version history and project status summary), `docs/status.md` (sprint progress)
- **Feature Docs**: Consolidated into PRD (e.g., SMS sync is now in `docs/prd.md` section 4.5)
- **Archive**: Resolved bugs and historical reports in `docs/archive/`

## CI/CD & Release Process
- **Automated Builds**: GitHub Actions workflows in `.github/workflows/`
  - `release.yml`: Automated builds and releases for Android and macOS
  - `backend-deploy.yml`: Backend deployment to Fly.io
- **Release Workflow**: Triggered by creating a git tag (e.g., `v1.0.1`)
  - Builds release APK (Android) and app bundle (macOS)
  - Creates GitHub release with artifacts
  - Artifacts: `Hypo-{version}.zip` (macOS), `Hypo.{version}.apk` (Android)
- **Test Branches**: Use `test/**` branch naming to skip release creation in CI
- **Version Management**: Update version in `backend/Cargo.toml`, `android/app/build.gradle.kts`, `macos/HypoApp.app/Contents/Info.plist` before tagging
