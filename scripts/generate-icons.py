#!/usr/bin/env python3
"""
Generate app icons for Android and macOS from vector design.
Creates minimal, vectorized icons with ripple design.
"""

import os
import sys
import math
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    print("❌ PIL (Pillow) not found. Install with: pip install Pillow")
    sys.exit(1)

# Get project root
SCRIPT_DIR = Path(__file__).parent.resolve()
PROJECT_ROOT = SCRIPT_DIR.parent

# Icon color scheme from SVG (hypo_minimal_ripple_purple.svg)
BG_START = "#05010F"  # Dark futuristic background start
BG_END = "#0B0220"    # Dark futuristic background end

# Ripple gradient colors (cyan -> purple)
RIPPLE_COLORS = [
    ("#7DD3FC", 0.9),   # Soft cyan (center)
    ("#38BDF8", 0.7),   # Sky blue
    ("#8B5CF6", 0.55),  # Purple-blue
    ("#9333EA", 0.9),   # Neon purple (outer)
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

def get_gradient_color_at_distance(distance, max_distance, colors):
    """Get color from radial gradient at given distance."""
    t = min(distance / max_distance, 1.0) if max_distance > 0 else 0
    
    # Map t to color stops (0%, 40%, 70%, 100%)
    stops = [0.0, 0.4, 0.7, 1.0]
    
    # Find which segment we're in
    if t <= stops[0]:
        return colors[0]
    elif t >= stops[-1]:
        return colors[-1]
    else:
        for i in range(len(stops) - 1):
            if stops[i] <= t <= stops[i + 1]:
                local_t = (t - stops[i]) / (stops[i + 1] - stops[i])
                c1_hex, o1 = colors[i]
                c2_hex, o2 = colors[i + 1]
                c1 = hex_to_rgb(c1_hex)
                c2 = hex_to_rgb(c2_hex)
                
                r = int(c1[0] * (1 - local_t) + c2[0] * local_t)
                g = int(c1[1] * (1 - local_t) + c2[1] * local_t)
                b = int(c1[2] * (1 - local_t) + c2[2] * local_t)
                opacity = o1 * (1 - local_t) + o2 * local_t
                return ((r, g, b), opacity)
    
    return colors[-1]

def create_icon_image(size):
    """Create the icon image at specified size based on the SVG design."""
    # Create gradient background
    img = create_gradient_background(size, BG_START, BG_END)
    
    # Scale factor (SVG is 512x512)
    scale = size / 512.0
    center = size / 2
    
    def scale_val(v):
        return int(v * scale)
    
    # Squircle corner radius (rx=120 in SVG)
    squircle_radius = scale_val(120)
    
    # Create rounded rectangle mask for squircle
    squircle_mask = Image.new("L", (size, size), 0)
    squircle_draw = ImageDraw.Draw(squircle_mask)
    squircle_draw.rounded_rectangle([0, 0, size, size], radius=squircle_radius, fill=255)
    
    # Apply squircle mask to background
    img = Image.composite(img, Image.new("RGB", (size, size), (0, 0, 0)), squircle_mask)
    
    # Convert to RGBA for compositing
    img = img.convert("RGBA")
    
    # Draw ripples (three concentric circles)
    # Core pulse: r=22, stroke-width=6
    # Main ripple: r=110, stroke-width=10
    # Outer echo: r=180, stroke-width=6, opacity=0.6
    
    ripple_layers = [
        (22, 6, 1.0),   # Core pulse
        (110, 10, 1.0), # Main ripple
        (180, 6, 0.6),  # Outer echo
    ]
    
    # Create composite image for ripples
    ripple_composite = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ripple_draw = ImageDraw.Draw(ripple_composite)
    
    max_radius = scale_val(180) + scale_val(6)
    
    for radius, stroke_width, opacity in ripple_layers:
        r = scale_val(radius)
        sw = max(1, scale_val(stroke_width))
        
        # Get color for this radius
        color_rgb, color_opacity = get_gradient_color_at_distance(r, max_radius, RIPPLE_COLORS)
        final_opacity = color_opacity * opacity
        
        # Create a temporary layer for this ripple
        ripple_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        layer_draw = ImageDraw.Draw(ripple_layer)
        
        # Draw outer circle filled with RGB color
        bbox_outer = [center - r - sw//2, center - r - sw//2,
                      center + r + sw//2, center + r + sw//2]
        layer_draw.ellipse(bbox_outer, fill=color_rgb)
        
        # Erase inner circle to create stroke effect
        bbox_inner = [center - r + sw//2, center - r + sw//2,
                      center + r - sw//2, center + r - sw//2]
        # Draw inner circle with transparent color to erase
        erase_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        erase_draw = ImageDraw.Draw(erase_layer)
        erase_draw.ellipse(bbox_inner, fill=(0, 0, 0, 255))
        # Composite to erase inner
        ripple_layer = Image.composite(
            Image.new("RGBA", (size, size), (0, 0, 0, 0)),
            ripple_layer,
            erase_layer.split()[3]  # Use alpha as mask
        )
        
        # Apply opacity to the layer
        if final_opacity < 1.0:
            alpha = ripple_layer.split()[3]
            alpha = alpha.point(lambda p: int(p * final_opacity))
            ripple_layer.putalpha(alpha)
        
        # Composite onto main ripple image
        ripple_composite = Image.alpha_composite(ripple_composite, ripple_layer)
    
    # Apply glow effect (Gaussian blur)
    glow_radius = max(1, scale_val(10))
    blurred_ripples = ripple_composite.filter(ImageFilter.GaussianBlur(radius=glow_radius))
    
    # Composite blurred ripples first (glow), then sharp ripples
    img = Image.alpha_composite(img, blurred_ripples)
    img = Image.alpha_composite(img, ripple_composite)
    
    return img.convert("RGB")

def generate_android_icons():
    """Generate Android mipmap icons and adaptive icon drawables."""
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
    
    # Generate adaptive icon drawables (for API 26+)
    print("  Generating adaptive icon drawables...")
    drawable_dir = android_res / "drawable"
    drawable_dir.mkdir(parents=True, exist_ok=True)
    
    # Background: dark gradient matching SVG
    background_xml = '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- Dark futuristic background gradient (from SVG) -->
    <path
        android:fillColor="#05010F"
        android:pathData="M0,0 L108,0 L108,108 L0,108 Z" />
</vector>
'''
    (drawable_dir / "ic_launcher_background.xml").write_text(background_xml)
    
    # Foreground: ripple design matching SVG
    foreground_xml = '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- Ripple design matching SVG (cyan -> purple gradient) -->
    <group>
        <!-- Core pulse (r=22 in 512px = ~4.6dp in 108dp) -->
        <path
            android:fillColor="#00000000"
            android:strokeColor="#7DD3FC"
            android:strokeWidth="1.3"
            android:strokeAlpha="0.9"
            android:pathData="M54,54 m-4.6,0 a4.6,4.6 0 1,1 9.2,0 a4.6,4.6 0 1,1 -9.2,0" />
        <!-- Main ripple (r=110 in 512px = ~23.2dp in 108dp) -->
        <path
            android:fillColor="#00000000"
            android:strokeColor="#8B5CF6"
            android:strokeWidth="2.1"
            android:strokeAlpha="0.7"
            android:pathData="M54,54 m-23.2,0 a23.2,23.2 0 1,1 46.4,0 a23.2,23.2 0 1,1 -46.4,0" />
        <!-- Outer echo (r=180 in 512px = ~38dp in 108dp) -->
        <path
            android:fillColor="#00000000"
            android:strokeColor="#9333EA"
            android:strokeWidth="1.3"
            android:strokeAlpha="0.54"
            android:pathData="M54,54 m-38,0 a38,38 0 1,1 76,0 a38,38 0 1,1 -76,0" />
    </group>
</vector>
'''
    (drawable_dir / "ic_launcher_foreground.xml").write_text(foreground_xml)
    print("  ✓ Adaptive icon drawables generated")
    
    print("✅ Android icons generated")

def create_menu_bar_icon(size):
    """Create a simplified monochrome icon for menu bar (template image)."""
    # Create transparent background
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    center = size / 2
    scale = size / 512.0
    
    def scale_val(v):
        return int(v * scale)
    
    # Draw simplified ripple design in white/black for template
    # Use white circles on transparent background (macOS will invert as needed)
    ripple_layers = [
        (22, 3),   # Core pulse
        (110, 5),  # Main ripple
        (180, 3),  # Outer echo
    ]
    
    for radius, stroke_width in ripple_layers:
        r = scale_val(radius)
        sw = max(1, scale_val(stroke_width))
        
        # Draw white circle outline (will be rendered as black in menu bar)
        bbox = [center - r, center - r, center + r, center + r]
        # Draw multiple circles for stroke width
        for i in range(sw):
            bbox_stroke = [center - r - i, center - r - i, center + r + i, center + r + i]
            draw.ellipse(bbox_stroke, outline=(255, 255, 255, 255), width=1)
    
    return img

def generate_macos_icons():
    """Generate macOS iconset."""
    print("🍎 Generating macOS icons...")
    
    macos_res = PROJECT_ROOT / "macos" / "HypoApp.app" / "Contents" / "Resources"
    iconset_dir = macos_res / "AppIcon.iconset"
    iconset_dir.mkdir(parents=True, exist_ok=True)
    
    # Also create menu bar icon directory
    menu_bar_dir = macos_res / "MenuBarIcon.iconset"
    menu_bar_dir.mkdir(parents=True, exist_ok=True)
    
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
    
    # Generate menu bar icons (monochrome template versions)
    print("  Generating menu bar icons (template)...")
    menu_bar_sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
    ]
    
    for size, filename in menu_bar_sizes:
        menu_icon = create_menu_bar_icon(size)
        menu_icon.save(menu_bar_dir / filename, "PNG")
        print(f"  ✓ MenuBar {filename}: {size}x{size}")
    
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


