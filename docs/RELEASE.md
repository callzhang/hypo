# Release Process

This document describes how to create and publish releases on GitHub with built artifacts.

---

## Overview

Releases are automated using GitHub Actions. When you push a tag or manually trigger the workflow, it will:

1. Build Android APKs (debug and release)
2. Build macOS app bundle
3. Create a GitHub release with all artifacts attached
4. Generate release notes with checksums

---

## Quick Start

### Option 1: Push a Tag (Recommended)

```bash
# 1. Update version numbers in code (if needed)
#    - android/app/build.gradle.kts: versionName = "0.2.2"
#    - macos/HypoApp.app/Contents/Info.plist: CFBundleShortVersionString

# 2. Commit changes
git add .
git commit -m "Release v0.2.2"

# 3. Create and push tag
git tag -a v0.2.2 -m "Release v0.2.2"
git push origin v0.2.2
```

The workflow will automatically:
- Build all platforms
- Create a GitHub release
- Attach artifacts (APKs and macOS ZIP)

### Option 2: Manual Workflow Trigger

1. Go to **Actions** tab in GitHub
2. Select **Release** workflow
3. Click **Run workflow**
4. Enter version tag (e.g., `v0.2.2`)
5. Click **Run workflow**

---

## Release Artifacts

Each release includes:

| Artifact | Description | Size |
|----------|-------------|------|
| `hypo-android-release-{version}.apk` | Optimized production APK | ~15-20MB |
| `hypo-android-debug-{version}.apk` | Debug APK for testing | ~47MB |
| `Hypo-macOS-{version}.zip` | macOS app bundle | ~10-15MB |

---

## Version Numbering

Follow [Semantic Versioning](https://semver.org/):

- **Major** (X.0.0): Breaking changes
- **Minor** (0.X.0): New features, backward compatible
- **Patch** (0.0.X): Bug fixes

Examples:
- `v0.2.2` - Patch release
- `v0.3.0` - Minor release
- `v1.0.0` - Major release
- `v0.2.2-beta` - Pre-release

---

## Pre-Release Checklist

Before creating a release:

- [ ] Update version numbers in:
  - [ ] `android/app/build.gradle.kts` (versionName, versionCode)
  - [ ] `macos/HypoApp.app/Contents/Info.plist` (CFBundleShortVersionString)
  - [ ] `docs/INSTALLATION.md` (version number)
- [ ] Update `changelog.md` with release notes
- [ ] Test builds locally:
  ```bash
  # Build release versions
  ./scripts/build-android.sh release
  ./scripts/build-macos.sh release
  
  # Or build all with deploy
  ./scripts/build-all.sh deploy
  ```
- [ ] Verify all tests pass
- [ ] Commit all changes
- [ ] Create and push tag

---

## Release Notes

Release notes are automatically generated from:

1. **Changelog**: If `changelog.md` exists, relevant sections are extracted
2. **Git commits**: GitHub's automatic release notes generator
3. **Manual notes**: Can be edited after release creation

### Format

```markdown
# Release v0.2.2

## Downloads

- **Android (Release)**: `hypo-android-release-0.2.2.apk` (~15-20MB)
- **Android (Debug)**: `hypo-android-debug-0.2.2.apk` (~47MB)
- **macOS**: `Hypo-macOS-0.2.2.zip`

## Installation

See [INSTALLATION.md](docs/INSTALLATION.md) for detailed instructions.

## Changes

[Extracted from changelog.md or git log]

## Checksums

SHA256 checksums:
  abc123...  hypo-android-release-0.2.2.apk
  def456...  hypo-android-debug-0.2.2.apk
  ghi789...  Hypo-macOS-0.2.2.zip
```

---

## Workflow Details

### Trigger Events

1. **Tag Push**: `git push origin v0.2.2`
   - Automatically triggers on tags matching `v*`
   - Uses tag name as version

2. **Manual Trigger**: GitHub Actions UI
   - Allows specifying version
   - Creates tag automatically

### Build Process

1. **Android Build** (Ubuntu):
   - Sets up JDK 17
   - Sets up Android SDK
   - Builds debug and release APKs
   - Uploads as artifacts

2. **macOS Build** (macOS 14):
   - Builds Swift package in release mode
   - Creates app bundle structure
   - Generates icons (if script available)
   - Creates ZIP archive
   - Uploads as artifact

3. **Release Creation** (Ubuntu):
   - Downloads all artifacts
   - Renames with version numbers
   - Generates checksums
   - Creates GitHub release
   - Attaches all artifacts

### Artifact Retention

Artifacts are retained for **30 days** in GitHub Actions. After release creation, they're permanently stored in the GitHub release.

---

## Troubleshooting

### Build Failures

**Android Build Fails**:
- Check Android SDK setup
- Verify Gradle configuration
- Check Java version (must be 17)

**macOS Build Fails**:
- Verify Swift version compatibility
- Check Package.swift dependencies
- Ensure macOS runner is available (macOS-14)

### Release Creation Fails

**Permission Issues**:
- Ensure workflow has `contents: write` permission
- Check repository settings → Actions → General → Workflow permissions

**Tag Already Exists**:
- Delete existing tag: `git tag -d v0.2.2 && git push origin :refs/tags/v0.2.2`
- Or use a different version number

### Missing Artifacts

- Check workflow logs for upload steps
- Verify artifact names match download step
- Ensure all build jobs completed successfully

---

## Manual Release (Alternative)

If you prefer to create releases manually:

```bash
# 1. Build all platforms
./scripts/build-all.sh release

# 2. Create tag
git tag -a v0.2.2 -m "Release v0.2.2"
git push origin v0.2.2

# 3. Create release on GitHub
gh release create v0.2.2 \
  --title "Release v0.2.2" \
  --notes "Release notes here" \
  android/app/build/outputs/apk/release/app-release.apk \
  android/app/build/outputs/apk/debug/app-debug.apk \
  Hypo-macOS-v0.2.2.zip
```

---

## Best Practices

1. **Always test locally** before creating a release
2. **Use semantic versioning** consistently
3. **Update changelog** before each release
4. **Tag from main branch** (or release branch)
5. **Verify artifacts** after release creation
6. **Announce releases** in appropriate channels

---

## Related Documentation

- [INSTALLATION.md](INSTALLATION.md) - Installation instructions
- [CHANGELOG.md](../changelog.md) - Version history
- [.github/workflows/release.yml](../.github/workflows/release.yml) - Workflow definition

---

**Last Updated**: December 2, 2025

