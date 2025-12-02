#!/usr/bin/env python3
"""
Generate app icons for Android and macOS from vector design.
Creates minimal, vectorized icons for both platforms.
"""

import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("❌ PIL (Pillow) not found. Install with: pip install Pillow")
    sys.exit(1)

# Get project root
SCRIPT_DIR = Path(__file__).parent.resolve()
PROJECT_ROOT = SCRIPT_DIR.parent

# Icon color scheme from SVG
BG_START = "#020617"  # Dark blue-black
BG_END = "#02091A"    # Slightly lighter dark blue
CYAN = "#22D3EE"      # Bright cyan for H
RING_COLORS = [
    ("#22D3EE", 0.95),  # Bright cyan
    ("#2DD4BF", 0.75),  # Teal-cyan
    ("#38BDF8", 0.55),  # Sky blue
    ("#0EA5E9", 0.35), # Blue
]

def hex_to_rgb(hex_color):
    """Convert hex color to RGB tuple."""
    hex_color = hex_color.lstrip('#')
    return tuple(int(hex_color[i:i+2], 16) for i in (0, 2, 4))

def create_gradient_background(size, start_color, end_color):
    """Create a linear gradient background."""
    img = Image.new("RGB", (size, size))
    pixels = img.load()
    
    start_rgb = hex_to_rgb(start_color)
    end_rgb = hex_to_rgb(end_color)
    
    for y in range(size):
        for x in range(size):
            # Diagonal gradient
            t = (x + y) / (size * 2)
            r = int(start_rgb[0] * (1 - t) + end_rgb[0] * t)
            g = int(start_rgb[1] * (1 - t) + end_rgb[1] * t)
            b = int(start_rgb[2] * (1 - t) + end_rgb[2] * t)
            pixels[x, y] = (r, g, b)
    
    return img

def draw_rounded_rectangle(draw, bbox, radius, fill=None):
    """Draw a rounded rectangle."""
    x1, y1, x2, y2 = bbox
    if fill:
        # Main rectangle
        draw.rectangle([x1 + radius, y1, x2 - radius, y2], fill=fill)
        draw.rectangle([x1, y1 + radius, x2, y2 - radius], fill=fill)
        # Corners (circles)
        draw.ellipse([x1, y1, x1 + radius*2, y1 + radius*2], fill=fill)
        draw.ellipse([x2 - radius*2, y1, x2, y1 + radius*2], fill=fill)
        draw.ellipse([x1, y2 - radius*2, x1 + radius*2, y2], fill=fill)
        draw.ellipse([x2 - radius*2, y2 - radius*2, x2, y2], fill=fill)

def create_icon_image(size):
    """Create the icon image at specified size based on the SVG design."""
    # Create gradient background
    img = create_gradient_background(size, BG_START, BG_END)
    draw = ImageDraw.Draw(img, "RGBA")
    
    # Scale factor (SVG is 1024x1024)
    scale = size / 1024.0
    center = size / 2
    
    def scale_val(v):
        return int(v * scale)
    
    # Draw squircle (rounded rectangle background)
    squircle_radius = scale_val(64)  # Corner radius
    padding = scale_val(64)
    
    # Draw energy rings (concentric circles with gradient)
    ring_radii = [80, 130, 190, 250, 320, 390]
    stroke_width = max(2, scale_val(6))
    
    for i, radius in enumerate(ring_radii):
        r = scale_val(radius)
        # Use gradient colors based on ring position
        color_idx = min(i // 2, len(RING_COLORS) - 1)
        ring_color_hex, opacity = RING_COLORS[color_idx]
        ring_color = hex_to_rgb(ring_color_hex)
        # Create RGBA color
        ring_color_rgba = (*ring_color, int(255 * opacity))
        
        # Draw circle with gradient-like effect
        # For simplicity, we'll use a solid color with some alpha
        bbox = [center - r, center - r, center + r, center + r]
        # For outline, we need to draw multiple circles to simulate stroke
        for offset in range(stroke_width):
            bbox_outline = [center - r - offset, center - r - offset, 
                          center + r + offset, center + r + offset]
            draw.ellipse(bbox_outline, outline=ring_color_rgba, width=1)
    
    # Draw letter "H" with glow effect
    h_color = hex_to_rgb(CYAN)
    h_color_rgba = (*h_color, 255)
    
    # H dimensions (from SVG: x=-150, y=-190, width=110, height=380, rx=55)
    h_left_x = center + scale_val(-150)
    h_right_x = center + scale_val(40)
    h_top_y = center + scale_val(-190)
    h_bottom_y = center + scale_val(190)
    h_width = scale_val(110)
    h_radius = scale_val(55)
    h_center_y = center + scale_val(-55)
    h_bar_height = scale_val(110)
    
    # Draw H with glow (simulate by drawing slightly larger version first)
    glow_offset = max(2, scale_val(4))
    glow_color = (*h_color, 80)  # Semi-transparent for glow
    
    # Glow layers
    for glow_size in [glow_offset * 3, glow_offset * 2, glow_offset]:
        glow_alpha = 80 // (glow_size // glow_offset) if glow_size > 0 else 80
        glow_rgba = (*h_color, glow_alpha)
        
        # Left vertical bar glow
        draw_rounded_rectangle(
            draw,
            [h_left_x - glow_size, h_top_y - glow_size, 
             h_left_x + h_width + glow_size, h_bottom_y + glow_size],
            h_radius + glow_size,
            fill=glow_rgba
        )
        
        # Right vertical bar glow
        draw_rounded_rectangle(
            draw,
            [h_right_x - glow_size, h_top_y - glow_size,
             h_right_x + h_width + glow_size, h_bottom_y + glow_size],
            h_radius + glow_size,
            fill=glow_rgba
        )
        
        # Horizontal bar glow
        draw_rounded_rectangle(
            draw,
            [h_left_x - glow_size, h_center_y - h_bar_height//2 - glow_size,
             h_right_x + h_width + glow_size, h_center_y + h_bar_height//2 + glow_size],
            h_radius + glow_size,
            fill=glow_rgba
        )
    
    # Draw H solid (main shape)
    # Left vertical bar
    draw_rounded_rectangle(
        draw,
        [h_left_x, h_top_y, h_left_x + h_width, h_bottom_y],
        h_radius,
        fill=h_color_rgba
    )
    
    # Right vertical bar
    draw_rounded_rectangle(
        draw,
        [h_right_x, h_top_y, h_right_x + h_width, h_bottom_y],
        h_radius,
        fill=h_color_rgba
    )
    
    # Horizontal bar
    draw_rounded_rectangle(
        draw,
        [h_left_x, h_center_y - h_bar_height//2,
         h_right_x + h_width, h_center_y + h_bar_height//2],
        h_radius,
        fill=h_color_rgba
    )
    
    return img

def generate_android_icons():
    """Generate Android mipmap icons."""
    print("📱 Generating Android icons...")
    
    android_res = PROJECT_ROOT / "android" / "app" / "src" / "main" / "res"
    
    # Density sizes
    densities = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    
    for density, size in densities.items():
        density_dir = android_res / density
        density_dir.mkdir(parents=True, exist_ok=True)
        
        icon = create_icon_image(size)
        icon.save(density_dir / "ic_launcher.png", "PNG")
        icon.save(density_dir / "ic_launcher_round.png", "PNG")
        
        print(f"  ✓ {density}: {size}x{size}")
    
    print("✅ Android icons generated")

def generate_macos_icons():
    """Generate macOS iconset."""
    print("🍎 Generating macOS icons...")
    
    macos_res = PROJECT_ROOT / "macos" / "HypoApp.app" / "Contents" / "Resources"
    iconset_dir = macos_res / "AppIcon.iconset"
    iconset_dir.mkdir(parents=True, exist_ok=True)
    
    # macOS icon sizes
    icon_sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    
    for size, filename in icon_sizes:
        icon = create_icon_image(size)
        icon.save(iconset_dir / filename, "PNG")
        print(f"  ✓ {filename}: {size}x{size}")
    
    # Create Contents.json
    contents_json = """{
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
"""
    (iconset_dir / "Contents.json").write_text(contents_json)
    
    # Convert to .icns if iconutil is available
    if os.system("which iconutil > /dev/null 2>&1") == 0:
        os.system(f'iconutil -c icns "{iconset_dir}" -o "{macos_res / "AppIcon.icns"}"')
        print("✅ macOS .icns file created")
    else:
        print("⚠️  iconutil not found, .icns file not created (iconset is ready)")
    
    print("✅ macOS icons generated")

def main():
    """Main entry point."""
    print("🎨 Generating Hypo app icons...\n")
    
    try:
        generate_android_icons()
        print()
        generate_macos_icons()
        print("\n✅ All icons generated successfully!")
    except Exception as e:
        print(f"\n❌ Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()


