# Repository Guidelines

## Project Structure & Module Organization
- `macos/`: Swift/SwiftUI client; shared logic under `Sources`, unit suites in `Tests/HypoAppTests`.
- `android/`: Kotlin Compose app with Gradle wrapper (`android/gradlew`); feature code in `app/src/main`, tests in `app/src/test`.
- `backend/`: Rust relay server; request handlers in `src/handlers`, integration specs in `backend/tests`.
- `scripts/`: automation helpers such as `build-android.sh`, `run-transport-regression.sh`, `setup-android-sdk.sh`.
- `tests/transport/*.json`: transport and crypto fixtures consumed by macOS and Android regression suites.

## Build, Test, and Development Commands
- macOS: `./scripts/build-macos.sh [clean]` for development; `swift test` or `swift test --filter TransportMetricsAggregatorTests` for focused runs.
- Android: `./scripts/build-android.sh [clean]` assembles `app-debug.apk`; `cd android && ./gradlew testDebugUnitTest` runs JVM unit tests.
- Backend: `cd backend && cargo run` brings up the relay; `cargo test` covers unit + integration (requires Redis from `docker compose up redis`).
- Cross-platform: `./scripts/run-transport-regression.sh` executes the shared transport metrics suite and expects `JAVA_HOME` and `ANDROID_SDK_ROOT`.

## Coding Style & Naming Conventions
- Swift: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` members; rely on Xcode “Editor → Structure → Re-Indent” before committing.
- Kotlin: Android Studio defaults, `UpperCamelCase` composables, resource files in `snake_case`; keep imports sorted via “Optimize Imports”.
- Rust: enforce `cargo fmt` and `cargo clippy -- -D warnings`; functions stay `snake_case`, structs `CamelCase`, modules grouped under `backend/src`.

## Testing Guidelines
- Uphold coverage targets (≥80% clients, ≥90% backend) tracked in `README.md`.
- Mirror fixture names when adding transport tests and store new data in `tests/transport`.
- macOS tests live in `HypoAppTests`; Android tests should follow `*Test` naming; backend integration tests use `cargo test --test integration_test`.
- Capture command output when running the regression script and attach snippets to reviews.

## Commit & Pull Request Guidelines
- Follow Conventional Commits as seen in history (`feat(android): …`, `fix: …`); keep subjects imperative and ≤72 chars.
- Squash exploratory commits and link tasks or issues in the PR body.
- Each PR must describe behaviour changes, list platforms touched, and note the commands executed (builds, tests, scripts).
- Exclude secrets or generated artifacts (`HypoApp.app`, `*.apk`, `target/`) from commits and update docs when behaviour shifts.

## Security & Configuration Tips
- Copy secrets from `.env.example` and keep production values in the shared vault; never commit Fly.io or signing credentials.
- Regenerate TLS fingerprints with `backend/scripts/cert_fingerprint.sh` after certificate updates.
- Prefer the repo-scoped Android SDK (`.android-sdk`) to keep builds reproducible; ensure QR pairing flows respect signed entitlements during macOS testing.
