"""Draws the app icon: assets/icon.png (used for the window) and assets/icon.icns (the app).

  uv run --with pillow tools/make_icon.py
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 1024                     # drawn large, then scaled down smoothly
OUT = Path(__file__).resolve().parent.parent / "assets"


def gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    g = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return g.resize((size, size))


def card(w: int, h: int, angle: float, video: bool) -> Image.Image:
    """A white photo card, with a little landscape (or a play button for the video)."""
    c = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(c)
    d.rounded_rectangle((0, 0, w - 1, h - 1), radius=w // 12, fill=(255, 255, 255, 255))
    m = w // 12
    inner = (m, m, w - m, h - m)
    d.rounded_rectangle(inner, radius=w // 20, fill=(214, 228, 255, 255) if not video else (40, 44, 64, 255))
    x0, y0, x1, y1 = inner
    if video:
        cx, cy, r = (x0 + x1) // 2, (y0 + y1) // 2, (x1 - x0) // 6
        d.polygon([(cx - r * 0.7, cy - r), (cx - r * 0.7, cy + r), (cx + r, cy)], fill=(255, 255, 255, 255))
    else:
        d.ellipse((x1 - (x1 - x0) // 3, y0 + (y1 - y0) // 8, x1 - (x1 - x0) // 8,
                   y0 + (y1 - y0) // 8 + (x1 - x0) // 5), fill=(255, 196, 61, 255))
        d.polygon([(x0, y1), (x0 + (x1 - x0) * 0.38, y0 + (y1 - y0) * 0.42), (x0 + (x1 - x0) * 0.7, y1)],
                  fill=(76, 132, 255, 255))
        d.polygon([(x0 + (x1 - x0) * 0.45, y1), (x0 + (x1 - x0) * 0.72, y0 + (y1 - y0) * 0.58), (x1, y1)],
                  fill=(43, 92, 214, 255))
    return c.rotate(angle, resample=Image.BICUBIC, expand=True)


def icon() -> Image.Image:
    bg = gradient(S, (88, 86, 214), (0, 122, 255)).convert("RGBA")
    mask = Image.new("L", (S, S), 0)
    pad = S // 10                                        # macOS icons sit inside a margin
    ImageDraw.Draw(mask).rounded_rectangle((pad, pad, S - pad, S - pad), radius=S // 5, fill=255)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(bg, (0, 0), mask)
    for img, (x, y) in ((card(470, 360, 12, True), (140, 200)), (card(470, 360, -8, False), (370, 440))):
        shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
        shadow.putalpha(img.getchannel("A").point(lambda a: a * 0.35))
        out.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)), (x + 10, y + 22))
        out.alpha_composite(img, (x, y))
    # a green "done" badge
    d = ImageDraw.Draw(out)
    cx, cy, r = 760, 300, 120
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(52, 199, 89, 255), outline=(255, 255, 255, 255), width=18)
    d.line([(cx - 55, cy + 2), (cx - 12, cy + 45), (cx + 60, cy - 45)], fill=(255, 255, 255, 255), width=30,
           joint="curve")
    return out


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    img = icon()
    img.resize((256, 256), Image.LANCZOS).save(OUT / "icon.png")
    img.save(OUT / "icon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("wrote", OUT / "icon.png", "and", OUT / "icon.icns")
    # the native app's icon set (mac/Sift/Assets.xcassets)
    iconset = OUT.parent / "mac" / "Sift" / "Assets.xcassets" / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{points}x{points}@{scale}x.png"
            img.resize((points * scale, points * scale), Image.LANCZOS).save(iconset / name)
            images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": name})
    (iconset / "Contents.json").write_text(json.dumps({"images": images, "info": {"version": 1, "author": "xcode"}}, indent=2))
    (iconset.parent / "Contents.json").write_text(json.dumps({"info": {"version": 1, "author": "xcode"}}, indent=2))
    print("wrote", iconset)
