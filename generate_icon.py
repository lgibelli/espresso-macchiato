#!/usr/bin/env python3
"""
Generate a simple coffee cup icon for Espresso.app
Creates an .icns file with multiple resolutions.
Requires no external dependencies - uses built-in macOS tools.
"""
import subprocess
import sys
import os
import tempfile

def create_svg_icon():
    """Create a coffee cup SVG icon."""
    return '''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <defs>
    <linearGradient id="cup" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#8B6914;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#6B4F12;stop-opacity:1" />
    </linearGradient>
    <linearGradient id="coffee" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#4A2C0A;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#2C1A06;stop-opacity:1" />
    </linearGradient>
  </defs>

  <!-- Background circle -->
  <circle cx="256" cy="256" r="240" fill="#1a1a2e" />

  <!-- Saucer -->
  <ellipse cx="256" cy="380" rx="160" ry="28" fill="#7A5C1E" opacity="0.6"/>

  <!-- Cup body -->
  <path d="M 140 200 L 156 360 C 160 380 200 390 256 390 C 312 390 352 380 356 360 L 372 200 Z"
        fill="url(#cup)" />

  <!-- Coffee surface -->
  <ellipse cx="256" cy="200" rx="116" ry="30" fill="url(#coffee)" />

  <!-- Cup rim highlight -->
  <ellipse cx="256" cy="200" rx="116" ry="30" fill="none"
           stroke="#A8892A" stroke-width="4" />

  <!-- Handle -->
  <path d="M 372 230 C 420 230 430 270 430 290 C 430 320 410 340 372 330"
        fill="none" stroke="url(#cup)" stroke-width="20"
        stroke-linecap="round" />

  <!-- Steam lines -->
  <path d="M 210 170 C 210 140 230 140 230 110 C 230 80 210 80 210 50"
        fill="none" stroke="white" stroke-width="6" stroke-linecap="round"
        opacity="0.5" />
  <path d="M 256 160 C 256 130 276 130 276 100 C 276 70 256 70 256 40"
        fill="none" stroke="white" stroke-width="6" stroke-linecap="round"
        opacity="0.4" />
  <path d="M 302 170 C 302 140 322 140 322 110 C 322 80 302 80 302 50"
        fill="none" stroke="white" stroke-width="6" stroke-linecap="round"
        opacity="0.3" />
</svg>'''

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 generate_icon.py <output.icns>")
        sys.exit(1)

    output_path = sys.argv[1]

    with tempfile.TemporaryDirectory() as tmpdir:
        # Write SVG
        svg_path = os.path.join(tmpdir, "icon.svg")
        with open(svg_path, "w") as f:
            f.write(create_svg_icon())

        # Create iconset directory
        iconset_dir = os.path.join(tmpdir, "AppIcon.iconset")
        os.makedirs(iconset_dir)

        # Generate PNGs at required sizes using sips (built into macOS)
        # First convert SVG to a large PNG using built-in tools
        # We'll use qlmanage or sips. Since SVG support varies, try a few approaches.
        large_png = os.path.join(tmpdir, "icon_1024.png")

        # Try using qlmanage (Quick Look) to render SVG
        try:
            subprocess.run(
                ["qlmanage", "-t", "-s", "1024", "-o", tmpdir, svg_path],
                capture_output=True, timeout=10
            )
            ql_output = svg_path + ".png"
            if os.path.exists(ql_output):
                os.rename(ql_output, large_png)
        except (subprocess.TimeoutExpired, OSError) as e:
            print(f"Note: qlmanage SVG render failed ({e}); falling back.")

        if not os.path.exists(large_png):
            # Fallback: create a simple PNG using Python + minimal drawing
            # Generate using sips from a basic tiff
            print("Note: Could not render SVG icon. The app will use system SF Symbols instead.")
            return

        # Required icon sizes for .icns
        sizes = [16, 32, 64, 128, 256, 512, 1024]

        for size in sizes:
            png_path = os.path.join(iconset_dir, f"icon_{size}x{size}.png")
            subprocess.run(
                ["sips", "-z", str(size), str(size), large_png,
                 "--out", png_path],
                capture_output=True
            )
            # Also create @2x versions
            if size <= 512:
                retina_size = size * 2
                retina_path = os.path.join(
                    iconset_dir, f"icon_{size}x{size}@2x.png"
                )
                subprocess.run(
                    ["sips", "-z", str(retina_size), str(retina_size),
                     large_png, "--out", retina_path],
                    capture_output=True
                )

        # Convert iconset to icns
        result = subprocess.run(
            ["iconutil", "-c", "icns", iconset_dir, "-o", output_path],
            capture_output=True, text=True
        )

        if result.returncode == 0:
            print(f"  Icon generated: {output_path}")
        else:
            print(f"  Icon generation failed: {result.stderr}")
            print("  The app will use system SF Symbols instead.")

if __name__ == "__main__":
    main()
