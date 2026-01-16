# Version Management

Hypo uses a centralized version management system to ensure consistency across all platforms.

## Centralized Version File

The project version is defined in a single file at the root:

- **`VERSION`** - Contains the version string (e.g., `1.1.5`)

All build systems read from this file:

- **Android**: `android/app/build.gradle.kts` reads from `VERSION` file
- **macOS**: `scripts/build-macos.sh` reads from `VERSION` file and updates `Info.plist`
- **Backend**: `backend/Cargo.toml` should be updated manually (or use `update-version.sh`)

## Updating the Version

### Method 1: Using the Update Script (Recommended)

```bash
./scripts/update-version.sh 1.1.5
```

This script will:
1. Update the `VERSION` file
2. Update `backend/Cargo.toml`
3. Provide next steps for committing and tagging

### Method 2: Manual Update

1. Edit `VERSION` file with the new version (e.g., `1.1.5`)
2. Update `backend/Cargo.toml`:
   ```toml
   version = "1.1.5"
   ```
3. Rebuild apps - they will automatically pick up the new version:
   ```bash
   ./scripts/build-all.sh
   ```

## Version Format

Versions follow semantic versioning: `MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes

Examples: `1.0.5`, `1.1.0`, `1.1.5`, `2.0.0`

## Build Number Derivation

To ensure consistency and allow for versions with patch 0 (e.g., `1.1.0`), build numbers are derived using the formula:
`MAJOR * 10000 + MINOR * 100 + PATCH`

- **Android**: `versionCode` is derived from this formula (e.g., `1.0.5` → `10005`, `1.1.0` → `10100`, `1.1.5` → `10105`)
- **macOS**: `CFBundleVersion` is derived from this formula (e.g., `1.0.5` → `10005`, `1.1.0` → `10100`, `1.1.5` → `10105`)

## Release Process

1. Update version using `./scripts/update-version.sh <version>`
2. Build and test: `./scripts/build-all.sh`
3. Commit changes: `git add VERSION backend/Cargo.toml`
4. Create git tag: `git tag v<version>` (e.g., `git tag v1.0.6`)
5. Push: `git push && git push --tags`

## Version Display

The version is displayed in:
- **Android**: Settings screen (from `BuildConfig.VERSION_NAME`)
- **macOS**: About dialog (from `CFBundleShortVersionString`)

Both are automatically set from the `VERSION` file during build.
