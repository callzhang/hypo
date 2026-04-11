#!/usr/bin/env python3
"""
Generate app icons for Android and macOS.
Creates a polished ripple-based icon with a luminous core and concentric waves.
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

BG_START = "#03131D"
BG_END = "#0A2740"
BG_GLOW = "#123D63"
CENTER_GLOW = "#DFFBFF"
CORE_COLOR = "#8EF2FF"

RIPPLE_COLORS = [
    ("#C9FBFF", 0.95),
    ("#74E7FF", 0.92),
    ("#33C7F3", 0.84),
    ("#1592D1", 0.72),
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

def create_radial_glow(size, center_x, center_y, radius, color, max_alpha):
    """Create a soft radial glow layer."""
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    rgb = hex_to_rgb(color)

    steps = 10
    for step in range(steps, 0, -1):
        t = step / steps
        current_radius = radius * t
        alpha = int(max_alpha * (t ** 2))
        bbox = [
            center_x - current_radius,
            center_y - current_radius,
            center_x + current_radius,
            center_y + current_radius,
        ]
        draw.ellipse(bbox, fill=(*rgb, alpha))

    return glow

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
    """Create the main app icon image."""
    img = create_gradient_background(size, BG_START, BG_END)

    scale = size / 512.0
    center = size / 2

    def scale_val(v):
        return int(v * scale)

    squircle_radius = scale_val(120)

    squircle_mask = Image.new("L", (size, size), 0)
    squircle_draw = ImageDraw.Draw(squircle_mask)
    squircle_draw.rounded_rectangle([0, 0, size, size], radius=squircle_radius, fill=255)

    img = Image.composite(img, Image.new("RGB", (size, size), (0, 0, 0)), squircle_mask)
    img = img.convert("RGBA")

    glow_center_x = center - scale_val(22)
    glow_center_y = center - scale_val(26)
    background_glow = create_radial_glow(
        size=size,
        center_x=glow_center_x,
        center_y=glow_center_y,
        radius=scale_val(290),
        color=BG_GLOW,
        max_alpha=120,
    )
    img = Image.alpha_composite(img, background_glow)

    ripple_layers = [
        (40, 12, 1.0),
        (112, 16, 0.95),
        (184, 10, 0.82),
    ]

    ripple_composite = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    max_radius = scale_val(184) + scale_val(16)

    for radius, stroke_width, opacity in ripple_layers:
        r = scale_val(radius)
        sw = max(1, scale_val(stroke_width))

        color_rgb, color_opacity = get_gradient_color_at_distance(r, max_radius, RIPPLE_COLORS)
        final_opacity = color_opacity * opacity

        ripple_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        layer_draw = ImageDraw.Draw(ripple_layer)

        bbox_outer = [center - r - sw//2, center - r - sw//2,
                      center + r + sw//2, center + r + sw//2]
        layer_draw.ellipse(bbox_outer, fill=color_rgb)

        bbox_inner = [center - r + sw//2, center - r + sw//2,
                      center + r - sw//2, center + r - sw//2]
        erase_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        erase_draw = ImageDraw.Draw(erase_layer)
        erase_draw.ellipse(bbox_inner, fill=(0, 0, 0, 255))
        ripple_layer = Image.composite(
            Image.new("RGBA", (size, size), (0, 0, 0, 0)),
            ripple_layer,
            erase_layer.split()[3]
        )

        if final_opacity < 1.0:
            alpha = ripple_layer.split()[3]
            alpha = alpha.point(lambda p: int(p * final_opacity))
            ripple_layer.putalpha(alpha)

        ripple_composite = Image.alpha_composite(ripple_composite, ripple_layer)

    ripple_glow = ripple_composite.filter(ImageFilter.GaussianBlur(radius=max(1, scale_val(16))))
    img = Image.alpha_composite(img, ripple_glow)
    img = Image.alpha_composite(img, ripple_composite)

    core_glow = create_radial_glow(
        size=size,
        center_x=center,
        center_y=center,
        radius=scale_val(92),
        color=CENTER_GLOW,
        max_alpha=140,
    )
    img = Image.alpha_composite(img, core_glow)

    core_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    core_draw = ImageDraw.Draw(core_layer)
    core_radius = scale_val(24)
    core_draw.ellipse(
        [center - core_radius, center - core_radius, center + core_radius, center + core_radius],
        fill=hex_to_rgb(CORE_COLOR),
    )
    highlight_radius = scale_val(10)
    highlight_offset = scale_val(8)
    core_draw.ellipse(
        [
            center - highlight_offset - highlight_radius,
            center - highlight_offset - highlight_radius,
            center - highlight_offset + highlight_radius,
            center - highlight_offset + highlight_radius,
        ],
        fill=(*hex_to_rgb("#FFFFFF"), 190),
    )
    img = Image.alpha_composite(img, core_layer)

    vignette = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    vignette_draw = ImageDraw.Draw(vignette)
    for step in range(4):
        inset = scale_val(step * 9)
        alpha = int(18 + step * 10)
        vignette_draw.rounded_rectangle(
            [inset, inset, size - inset, size - inset],
            radius=max(1, squircle_radius - inset),
            outline=(0, 0, 0, alpha),
            width=max(1, scale_val(2)),
        )
    img = Image.alpha_composite(img, vignette)

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
    <!-- Deep ocean background -->
    <path
        android:fillColor="#03131D"
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
    <!-- Ripple design matching the app icon -->
    <group>
        <!-- Core pulse -->
        <path
            android:fillColor="#00000000"
            android:strokeColor="#C9FBFF"
            android:strokeWidth="2.5"
            android:strokeAlpha="0.95"
            android:pathData="M54,54 m-8.4,0 a8.4,8.4 0 1,1 16.8,0 a8.4,8.4 0 1,1 -16.8,0" />
        <!-- Mid ripple -->
        <path
            android:fillColor="#00000000"
            android:strokeColor="#74E7FF"
            android:strokeWidth="3.4"
            android:strokeAlpha="0.9"
            android:pathData="M54,54 m-23.6,0 a23.6,23.6 0 1,1 47.2,0 a23.6,23.6 0 1,1 -47.2,0" />
        <!-- Outer ripple -->
        <path
            android:fillColor="#00000000"
            android:strokeColor="#1592D1"
            android:strokeWidth="2.1"
            android:strokeAlpha="0.74"
            android:pathData="M54,54 m-38.8,0 a38.8,38.8 0 1,1 77.6,0 a38.8,38.8 0 1,1 -77.6,0" />
        <!-- Filled center -->
        <path
            android:fillColor="#8EF2FF"
            android:fillAlpha="0.95"
            android:pathData="M54,54 m-4.8,0 a4.8,4.8 0 1,1 9.6,0 a4.8,4.8 0 1,1 -9.6,0" />
    </group>
</vector>
'''
    (drawable_dir / "ic_launcher_foreground.xml").write_text(foreground_xml)
    print("  ✓ Adaptive icon drawables generated")
    
    print("✅ Android icons generated")

def create_menu_bar_icon(size):
    """Create a simplified monochrome icon for menu bar (template image)."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    center = size / 2
    stroke = max(2, int(round(size * 0.10)))
    core_radius = max(3, int(round(size * 0.12)))
    inner_radius = int(round(size * 0.29))
    outer_radius = int(round(size * 0.44))

    draw.ellipse(
        [center - core_radius, center - core_radius, center + core_radius, center + core_radius],
        fill=(255, 255, 255, 255),
    )

    ripple_layers = [
        (inner_radius, stroke),
        (outer_radius, stroke),
    ]

    for radius, stroke_width in ripple_layers:
        bbox = [center - radius, center - radius, center + radius, center + radius]
        draw.ellipse(bbox, outline=(255, 255, 255, 255), width=stroke_width)

    return img

def generate_macos_icons():
    """Generate macOS iconset."""
    print("🍎 Generating macOS icons...")
    
    macos_res = PROJECT_ROOT / "macos" / "Hypo.app" / "Contents" / "Resources"
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
