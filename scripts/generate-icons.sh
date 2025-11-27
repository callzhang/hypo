#!/bin/bash
# Generate app icons for Android and macOS from SVG
# Requires: ImageMagick (convert) or rsvg-convert

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}ℹ️  $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check for ImageMagick
if ! command -v convert &> /dev/null && ! command -v rsvg-convert &> /dev/null; then
    log_error "ImageMagick (convert) or rsvg-convert not found"
    log_info "Install with: brew install imagemagick librsvg"
    exit 1
fi

# Create temporary SVG file
TEMP_SVG=$(mktemp /tmp/hypo-icon.XXXXXX.svg)
cat > "$TEMP_SVG" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 108 108">
  <!-- Background -->
  <rect width="108" height="108" fill="#6366F1"/>
  
  <!-- Left clipboard -->
  <path fill="#FFFFFF" d="M18,12 L18,36 L30,36 L30,48 L42,48 L42,12 L18,12 Z M22,16 L38,16 L38,32 L30,32 L30,44 L22,44 L22,16 Z"/>
  
  <!-- Right clipboard -->
  <path fill="#FFFFFF" d="M66,12 L66,36 L78,36 L78,48 L90,48 L90,12 L66,12 Z M70,16 L86,16 L86,32 L78,32 L78,44 L70,44 L70,16 Z"/>
  
  <!-- Sync connection arrows -->
  <path fill="#FFFFFF" d="M42,30 L48,24 L48,28 L60,28 L60,32 L48,32 L48,36 L42,30 Z"/>
  <path fill="#FFFFFF" d="M66,30 L60,24 L60,28 L48,28 L48,32 L60,32 L60,36 L66,30 Z"/>
</svg>
EOF

log_info "Generated temporary SVG icon"

# Function to generate PNG from SVG
generate_png() {
    local size=$1
    local output=$2
    
    if command -v rsvg-convert &> /dev/null; then
        rsvg-convert -w "$size" -h "$size" "$TEMP_SVG" -o "$output"
    elif command -v convert &> /dev/null; then
        convert -background none -resize "${size}x${size}" "$TEMP_SVG" "$output"
    fi
}

# Generate Android mipmap icons
log_info "Generating Android icons..."

ANDROID_RES="$PROJECT_ROOT/android/app/src/main/res"

# Create mipmap directories
mkdir -p "$ANDROID_RES/mipmap-mdpi"
mkdir -p "$ANDROID_RES/mipmap-hdpi"
mkdir -p "$ANDROID_RES/mipmap-xhdpi"
mkdir -p "$ANDROID_RES/mipmap-xxhdpi"
mkdir -p "$ANDROID_RES/mipmap-xxxhdpi"

# Generate icons for each density
generate_png 48 "$ANDROID_RES/mipmap-mdpi/ic_launcher.png"
generate_png 72 "$ANDROID_RES/mipmap-hdpi/ic_launcher.png"
generate_png 96 "$ANDROID_RES/mipmap-xhdpi/ic_launcher.png"
generate_png 144 "$ANDROID_RES/mipmap-xxhdpi/ic_launcher.png"
generate_png 192 "$ANDROID_RES/mipmap-xxxhdpi/ic_launcher.png"

# Generate round icons (same as regular for now)
cp "$ANDROID_RES/mipmap-mdpi/ic_launcher.png" "$ANDROID_RES/mipmap-mdpi/ic_launcher_round.png"
cp "$ANDROID_RES/mipmap-hdpi/ic_launcher.png" "$ANDROID_RES/mipmap-hdpi/ic_launcher_round.png"
cp "$ANDROID_RES/mipmap-xhdpi/ic_launcher.png" "$ANDROID_RES/mipmap-xhdpi/ic_launcher_round.png"
cp "$ANDROID_RES/mipmap-xxhdpi/ic_launcher.png" "$ANDROID_RES/mipmap-xxhdpi/ic_launcher_round.png"
cp "$ANDROID_RES/mipmap-xxxhdpi/ic_launcher.png" "$ANDROID_RES/mipmap-xxxhdpi/ic_launcher_round.png"

log_info "Android icons generated"

# Generate macOS iconset
log_info "Generating macOS icons..."

MACOS_ICONSET="$PROJECT_ROOT/macos/HypoApp.app/Contents/Resources/AppIcon.iconset"
mkdir -p "$MACOS_ICONSET"

# Generate all required sizes for macOS
generate_png 16 "$MACOS_ICONSET/icon_16x16.png"
generate_png 32 "$MACOS_ICONSET/icon_16x16@2x.png"
generate_png 32 "$MACOS_ICONSET/icon_32x32.png"
generate_png 64 "$MACOS_ICONSET/icon_32x32@2x.png"
generate_png 128 "$MACOS_ICONSET/icon_128x128.png"
generate_png 256 "$MACOS_ICONSET/icon_128x128@2x.png"
generate_png 256 "$MACOS_ICONSET/icon_256x256.png"
generate_png 512 "$MACOS_ICONSET/icon_256x256@2x.png"
generate_png 512 "$MACOS_ICONSET/icon_512x512.png"
generate_png 1024 "$MACOS_ICONSET/icon_512x512@2x.png"

# Create iconset Contents.json
cat > "$MACOS_ICONSET/Contents.json" << 'EOF'
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

# Convert iconset to .icns file
if command -v iconutil &> /dev/null; then
    iconutil -c icns "$MACOS_ICONSET" -o "$PROJECT_ROOT/macos/HypoApp.app/Contents/Resources/AppIcon.icns"
    log_info "macOS .icns file created"
else
    log_warn "iconutil not found, .icns file not created (iconset is ready)"
fi

log_info "macOS icons generated"

# Cleanup
rm -f "$TEMP_SVG"

log_info "✅ Icon generation complete!"



