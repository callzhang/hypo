#!/bin/bash
# Update version across the entire project
# Usage: ./scripts/update-version.sh <version>
# Example: ./scripts/update-version.sh 1.0.6

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 1.0.6"
    exit 1
fi

NEW_VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$PROJECT_ROOT/VERSION"

# Validate version format (basic check: should be x.y.z)
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must be in format x.y.z (e.g., 1.0.6)"
    exit 1
fi

echo "Updating version to $NEW_VERSION..."

# Update VERSION file
echo "$NEW_VERSION" > "$VERSION_FILE"
echo "✅ Updated VERSION file"

# Update backend Cargo.toml
if [ -f "$PROJECT_ROOT/backend/Cargo.toml" ]; then
    sed -i '' "s/^version = \".*\"/version = \"$NEW_VERSION\"/" "$PROJECT_ROOT/backend/Cargo.toml"
    echo "✅ Updated backend/Cargo.toml"
fi

echo ""
echo "Version updated to $NEW_VERSION"
echo ""
echo "Next steps:"
echo "1. Build apps: ./scripts/build-all.sh"
echo "2. Test the apps"
echo "3. Commit changes: git add VERSION backend/Cargo.toml"
echo "4. Create git tag: git tag v$NEW_VERSION"
echo "5. Push: git push && git push --tags"

