#!/usr/bin/env python3
"""
Generate app icons for Android and macOS.
Uses macos/scripts/icon.svg as the single source of truth.
"""

import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("❌ PIL (Pillow) not found. Install with: pip install Pillow")
    sys.exit(1)

# Get project root
SCRIPT_DIR = Path(__file__).parent.resolve()
PROJECT_ROOT = SCRIPT_DIR.parent

SVG_PATH = PROJECT_ROOT / "macos" / "scripts" / "icon.svg"
RSVG_CONVERT = "rsvg-convert"

def svg_number(value):
    """Parse an SVG numeric attribute."""
    return float(str(value).replace("px", ""))


def parse_icon_svg():
    """Load the SVG and extract the geometry used across icon outputs."""
    ns = {"svg": "http://www.w3.org/2000/svg"}
    root = ET.parse(SVG_PATH).getroot()
    view_box = [svg_number(part) for part in root.attrib["viewBox"].split()]

    rects = root.findall(".//svg:g/svg:rect", ns)
    ellipses = root.findall(".//svg:g/svg:ellipse", ns)
    group = root.find(".//svg:g", ns)
    filter_ref = group.attrib.get("filter", "").removeprefix("url(#").removesuffix(")")
    filter_node = root.find(f".//svg:filter[@id='{filter_ref}']", ns) if filter_ref else None

    blur = 0.0
    offset_x = 0.0
    offset_y = 0.0
    if filter_node is not None:
        blur_node = filter_node.find(".//svg:feGaussianBlur", ns)
        offset_node = filter_node.find(".//svg:feOffset", ns)
        if blur_node is not None:
            blur = svg_number(blur_node.attrib.get("stdDeviation", "0"))
        if offset_node is not None:
            offset_x = svg_number(offset_node.attrib.get("dx", "0"))
            offset_y = svg_number(offset_node.attrib.get("dy", "0"))

    bounds = []
    for rect in rects:
        x = svg_number(rect.attrib["x"])
        y = svg_number(rect.attrib["y"])
        width = svg_number(rect.attrib["width"])
        height = svg_number(rect.attrib["height"])
        bounds.append((x, y, x + width, y + height))
    for ellipse in ellipses:
        cx = svg_number(ellipse.attrib["cx"])
        cy = svg_number(ellipse.attrib["cy"])
        rx = svg_number(ellipse.attrib["rx"])
        ry = svg_number(ellipse.attrib["ry"])
        bounds.append((cx - rx, cy - ry, cx + rx, cy + ry))

    min_x = min(bound[0] for bound in bounds) - blur * 3 + min(0.0, offset_x)
    min_y = min(bound[1] for bound in bounds) - blur * 3 + min(0.0, offset_y)
    max_x = max(bound[2] for bound in bounds) + blur * 3 + max(0.0, offset_x)
    max_y = max(bound[3] for bound in bounds) + blur * 3 + max(0.0, offset_y)

    width = max_x - min_x
    height = max_y - min_y
    side = max(width, height)
    center_x = (min_x + max_x) / 2
    center_y = (min_y + max_y) / 2

    crop_x = center_x - side / 2
    crop_y = center_y - side / 2

    return {
        "view_box": view_box,
        "crop_box": (crop_x, crop_y, crop_x + side, crop_y + side),
        "ellipses": [
            {
                "cx": svg_number(ellipse.attrib["cx"]),
                "cy": svg_number(ellipse.attrib["cy"]),
                "rx": svg_number(ellipse.attrib["rx"]),
                "ry": svg_number(ellipse.attrib["ry"]),
                "opacity": float(ellipse.attrib.get("opacity", "1")),
            }
            for ellipse in ellipses
        ],
    }


def render_svg_square(size, svg_data):
    """Render the SVG, then crop it to the icon square derived from the SVG geometry."""
    render_size = max(size * 3, 2048)
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as temp_file:
        temp_path = Path(temp_file.name)

    try:
        subprocess.run(
            [
                RSVG_CONVERT,
                str(SVG_PATH),
                "-w",
                str(render_size),
                "-h",
                str(int(render_size * svg_data["view_box"][3] / svg_data["view_box"][2])),
                "-o",
                str(temp_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        image = Image.open(temp_path).convert("RGBA")
        view_width = svg_data["view_box"][2]
        scale = image.width / view_width
        crop_box = tuple(int(round(value * scale)) for value in svg_data["crop_box"])
        square = image.crop(crop_box).resize((size, size), Image.LANCZOS)
        return square.convert("RGB")
    finally:
        temp_path.unlink(missing_ok=True)


def create_icon_image(size, svg_data):
    """Create the main app icon by rasterizing macos/scripts/icon.svg."""
    return render_svg_square(size, svg_data)

def build_android_foreground_xml():
    """Adaptive icon foreground matching the stacked-card SVG motif."""
    return '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:pathData="M27,27 h54 a15.3,15.3 0 0 1 15.3,15.3 v23.4 a15.3,15.3 0 0 1 -15.3,15.3 h-54 a15.3,15.3 0 0 1 -15.3,-15.3 v-23.4 a15.3,15.3 0 0 1 15.3,-15.3 z">
        <gradient
            android:type="linear"
            android:startX="27"
            android:startY="27"
            android:endX="81"
            android:endY="81"
            android:startColor="#5EB1FF"
            android:endColor="#8458FF" />
    </path>
    <path
        android:fillColor="#FFFFFF"
        android:fillAlpha="0.12"
        android:pathData="M34.1,61.2 a18.9,7.56 0 1,0 37.8,0 a18.9,7.56 0 1,0 -37.8,0z" />
    <path
        android:fillColor="#FFFFFF"
        android:fillAlpha="0.25"
        android:pathData="M34.1,54.9 a18.9,7.56 0 1,0 37.8,0 a18.9,7.56 0 1,0 -37.8,0z" />
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M34.1,48.6 a18.9,7.56 0 1,0 37.8,0 a18.9,7.56 0 1,0 -37.8,0z" />
</vector>
'''


def generate_android_icons(svg_data):
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
        
        icon = create_icon_image(size, svg_data)
        icon.save(density_dir / "ic_launcher.png", "PNG")
        icon.save(density_dir / "ic_launcher_round.png", "PNG")
        
        print(f"  ✓ {density}: {size}x{size}")
    
    # Generate adaptive icon drawables (for API 26+)
    print("  Generating adaptive icon drawables...")
    drawable_dir = android_res / "drawable"
    drawable_dir.mkdir(parents=True, exist_ok=True)
    
    # Background and foreground are a simplified vector reduction of the same SVG.
    background_xml = '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#E6EEFF"
        android:pathData="M0,0 L108,0 L108,108 L0,108 Z" />
</vector>
'''
    (drawable_dir / "ic_launcher_background.xml").write_text(background_xml)
    foreground_xml = build_android_foreground_xml()
    (drawable_dir / "ic_launcher_foreground.xml").write_text(foreground_xml)
    print("  ✓ Adaptive icon drawables generated")
    
    print("✅ Android icons generated")

def create_menu_bar_icon(size, svg_data):
    """Create a monochrome outline icon derived from the SVG ellipses."""
    master_size = 512
    img = Image.new("RGBA", (master_size, master_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    ellipses = svg_data["ellipses"]
    stack_min_x = min(ellipse["cx"] - ellipse["rx"] for ellipse in ellipses)
    stack_max_x = max(ellipse["cx"] + ellipse["rx"] for ellipse in ellipses)
    stack_min_y = min(ellipse["cy"] - ellipse["ry"] for ellipse in ellipses)
    stack_max_y = max(ellipse["cy"] + ellipse["ry"] for ellipse in ellipses)

    stack_width = stack_max_x - stack_min_x
    stack_height = stack_max_y - stack_min_y
    content_width = master_size * 0.86
    content_height = master_size * 0.70
    scale = min(content_width / stack_width, content_height / stack_height)
    x_offset = (master_size - stack_width * scale) / 2
    y_offset = (master_size - stack_height * scale) / 2

    stroke_alphas = [72, 136, 255]
    stroke_widths = [
        max(1, int(round(master_size * 0.045))),
        max(1, int(round(master_size * 0.048))),
        max(1, int(round(master_size * 0.052))),
    ]
    vertical_offsets = [master_size * 0.07, 0.0, -master_size * 0.07]

    for index, ellipse in enumerate(ellipses):
        left = x_offset + (ellipse["cx"] - ellipse["rx"] - stack_min_x) * scale
        top = y_offset + (ellipse["cy"] - ellipse["ry"] - stack_min_y) * scale + vertical_offsets[index]
        right = x_offset + (ellipse["cx"] + ellipse["rx"] - stack_min_x) * scale
        bottom = y_offset + (ellipse["cy"] + ellipse["ry"] - stack_min_y) * scale + vertical_offsets[index]
        bbox = [
            left,
            top,
            right,
            bottom,
        ]
        draw.ellipse(
            bbox,
            outline=(255, 255, 255, stroke_alphas[index]),
            width=stroke_widths[index],
        )

    return img.resize((size, size), Image.Resampling.LANCZOS)

def generate_macos_icons(svg_data):
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
        icon = create_icon_image(size, svg_data)
        icon.save(iconset_dir / filename, "PNG")
        print(f"  ✓ {filename}: {size}x{size}")
    
    # Generate menu bar icons (monochrome template versions)
    print("  Generating menu bar icons (template)...")
    menu_bar_sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
    ]
    
    for size, filename in menu_bar_sizes:
        menu_icon = create_menu_bar_icon(size, svg_data)
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
        svg_data = parse_icon_svg()
        generate_android_icons(svg_data)
        print()
        generate_macos_icons(svg_data)
        print("\n✅ All icons generated successfully!")
    except Exception as e:
        print(f"\n❌ Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
