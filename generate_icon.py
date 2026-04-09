#!/usr/bin/env python3
"""
Generate ActiveSpace app icons at all required macOS sizes.
Design: dark charcoal rounded-rect background, two side-by-side space "bubbles"
with the left one highlighted white and right one dimmed, indicating space switching.
"""
import os
import math
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.expanduser(
    "~/Desktop/ActiveSpace/ActiveSpace/Assets.xcassets/AppIcon.appiconset"
)
os.makedirs(OUT, exist_ok=True)

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # ── Background ───────────────────────────────────────────────────────────
    bg_color = (28, 28, 30, 255)          # #1C1C1E  (macOS dark bg)
    corner = size * 0.22
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=corner, fill=bg_color)

    # ── Two space "pill" bubbles ──────────────────────────────────────────────
    # Arranged horizontally, centred, with a small gap between them
    bubble_w = size * 0.28
    bubble_h = size * 0.38
    gap      = size * 0.06
    total_w  = bubble_w * 2 + gap
    x0       = (size - total_w) / 2
    y0       = (size - bubble_h) / 2

    br = bubble_h / 2   # fully-rounded pill

    # Left bubble — active (white)
    left = [x0, y0, x0 + bubble_w, y0 + bubble_h]
    d.rounded_rectangle(left, radius=br, fill=(255, 255, 255, 255))

    # Right bubble — inactive (dimmed grey)
    rx0 = x0 + bubble_w + gap
    right = [rx0, y0, rx0 + bubble_w, y0 + bubble_h]
    d.rounded_rectangle(right, radius=br, fill=(120, 120, 128, 200))

    # ── Number labels inside each bubble ─────────────────────────────────────
    if size >= 64:
        font_size = int(bubble_h * 0.55)
        try:
            font = ImageFont.truetype(
                "/System/Library/Fonts/Supplemental/Arial Bold.ttf", font_size
            )
        except Exception:
            font = ImageFont.load_default()

        def draw_centered_text(text, rect, color):
            x1, y1, x2, y2 = rect
            bbox = d.textbbox((0, 0), text, font=font)
            tw = bbox[2] - bbox[0]
            th = bbox[3] - bbox[1]
            tx = x1 + (x2 - x1 - tw) / 2 - bbox[0]
            ty = y1 + (y2 - y1 - th) / 2 - bbox[1]
            d.text((tx, ty), text, font=font, fill=color)

        draw_centered_text("1", left,  (28, 28, 30, 255))   # dark on white
        draw_centered_text("2", right, (200, 200, 210, 255)) # light on grey

    return img


def main():
    for size in SIZES:
        icon = draw_icon(size)
        fname = f"icon_{size}x{size}.png"
        icon.save(os.path.join(OUT, fname))
        print(f"  wrote {fname}")

    # Also write @2x variants (same file, doubled logical size)
    pairs = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"),
             (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
             (256, "256x256"), (512, "256x256@2x"), (512, "512x512"),
             (1024, "512x512@2x")]
    sizes_needed = {s for s, _ in pairs}

    for size in sizes_needed:
        if size not in SIZES:
            icon = draw_icon(size)
            fname = f"icon_{size}x{size}.png"
            icon.save(os.path.join(OUT, fname))
            print(f"  wrote {fname}")

    print("Done.")


if __name__ == "__main__":
    main()
