#!/usr/bin/env python3
"""Compose Pharos App Store screenshots with programmatically drawn hardware."""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import gc

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "fastlane/screenshots/raw-demo"
OUT = ROOT / "fastlane/screenshots/en-US"

SIZES = {"iphone": (1320, 2868), "ipad": (2064, 2752)}
SCENES = {
    "projects": ("01", "YOUR WORKSPACE", "Every project.\nOne clear view."),
    "issues": ("02", "MAKE PROGRESS", "From idea\nto shipped."),
    "agents": ("03", "LIVE AGENTS", "Every task.\nEvery machine."),
    "chat": ("04", "BUILD TOGETHER", "Talk where\nthe work happens."),
}

INK = (245, 242, 237)
MUTED = (174, 171, 166)
ACCENT = (255, 139, 61)
BG_TOP = (22, 22, 24)
BG_BOTTOM = (7, 7, 9)


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    name = "SFNSDisplay-Bold.otf" if bold else "SFNSDisplay-Regular.otf"
    candidates = [
        Path("/System/Library/Fonts") / name,
        Path("/System/Library/Fonts/SFNS.ttf"),
        Path("/System/Library/Fonts/SFNSRounded.ttf"),
    ]
    for path in candidates:
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default(size=size)


def background(size: tuple[int, int]) -> Image.Image:
    width, height = size
    stripe = Image.new("RGB", (1, height))
    pixels = stripe.load()
    for y in range(height):
        t = y / max(1, height - 1)
        color = tuple(round(a * (1 - t) + b * t) for a, b in zip(BG_TOP, BG_BOTTOM))
        pixels[0, y] = color
    image = stripe.resize(size)
    stripe.close()

    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow, "RGBA")
    gd.ellipse(
        [-width // 5, int(height * 0.38), int(width * 1.2), int(height * 1.1)],
        fill=ACCENT + (45,),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(width // 4))
    image.paste(glow, (0, 0), glow)
    return image


def tracked_text(draw: ImageDraw.ImageDraw, xy: tuple[float, float], text: str,
                 face: ImageFont.FreeTypeFont, fill: tuple[int, int, int], tracking: int) -> None:
    x, y = xy
    for character in text:
        draw.text((x, y), character, font=face, fill=fill)
        x += draw.textlength(character, font=face) + tracking


def hardware_frame(shot: Image.Image, is_ipad: bool) -> Image.Image:
    """Draw the bezel, metal rim, camera, and shadow without frame assets."""
    sw, sh = shot.size
    rim = max(18, round(sw * (0.018 if is_ipad else 0.026)))
    bezel = max(14, round(sw * (0.012 if is_ipad else 0.020)))
    outer_radius = round(sw * (0.065 if is_ipad else 0.145))
    inner_radius = max(12, outer_radius - rim - bezel)
    pad = rim + bezel

    frame = Image.new("RGBA", (sw + pad * 2, sh + pad * 2), (0, 0, 0, 0))
    draw = ImageDraw.Draw(frame, "RGBA")
    draw.rounded_rectangle([0, 0, frame.width - 1, frame.height - 1], radius=outer_radius,
                           fill=(103, 102, 106, 255), outline=(218, 215, 210, 255), width=max(3, rim // 5))
    draw.rounded_rectangle([rim, rim, frame.width - rim - 1, frame.height - rim - 1],
                           radius=outer_radius - rim, fill=(4, 4, 5, 255))

    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=inner_radius, fill=255)
    frame.paste(shot.convert("RGBA"), (pad, pad), mask)

    if is_ipad:
        camera_radius = max(4, sw // 260)
        cx, cy = frame.width // 2, rim + bezel // 2
        draw.ellipse([cx - camera_radius, cy - camera_radius, cx + camera_radius, cy + camera_radius],
                     fill=(12, 12, 13, 255), outline=(58, 58, 62, 255))
    else:
        island_w, island_h = round(sw * 0.29), round(sw * 0.085)
        cx, top = frame.width // 2, pad + round(sw * 0.035)
        draw.rounded_rectangle([cx - island_w // 2, top, cx + island_w // 2, top + island_h],
                               radius=island_h // 2, fill=(0, 0, 0, 255))
    return frame


def compose(device: str, scene: str) -> Image.Image:
    width, height = SIZES[device]
    shot_path = RAW / f"{device}-{scene}.png"
    shot = Image.open(shot_path).convert("RGB")
    if shot.size != (width, height):
        raise ValueError(f"{shot_path.name}: {shot.size}, expected {(width, height)}")

    canvas = background((width, height))
    draw = ImageDraw.Draw(canvas)
    is_ipad = device == "ipad"
    _, eyebrow, headline = SCENES[scene]

    eye_face = font(round(width * (0.021 if is_ipad else 0.030)), bold=True)
    tracking = round(width * 0.004)
    eye_width = draw.textlength(eyebrow, font=eye_face) + tracking * (len(eyebrow) - 1)
    eye_y = round(height * (0.048 if is_ipad else 0.055))
    tracked_text(draw, ((width - eye_width) / 2, eye_y), eyebrow, eye_face, ACCENT, tracking)

    head_face = font(round(width * (0.057 if is_ipad else 0.086)), bold=True)
    y = eye_y + round(height * (0.035 if is_ipad else 0.043))
    line_step = round(head_face.size * 1.04)
    for line in headline.split("\n"):
        box = draw.textbbox((0, 0), line, font=head_face)
        draw.text(((width - (box[2] - box[0])) / 2, y), line, font=head_face, fill=INK)
        y += line_step

    sub_face = font(round(width * (0.018 if is_ipad else 0.030)))
    subtitle = "Plan, delegate, and follow the work from anywhere."
    sub_width = draw.textlength(subtitle, font=sub_face)
    sub_y = y + round(height * 0.012)
    draw.text(((width - sub_width) / 2, sub_y), subtitle, font=sub_face, fill=MUTED)

    framed = hardware_frame(shot, is_ipad)
    device_top = sub_y + round(height * (0.055 if is_ipad else 0.045))
    available_height = height - device_top + round(height * 0.10)
    available_width = round(width * (0.84 if is_ipad else 0.80))
    scale = min(available_width / framed.width, available_height / framed.height)
    framed = framed.resize((round(framed.width * scale), round(framed.height * scale)), Image.Resampling.LANCZOS)

    shadow = Image.new("RGBA", (framed.width + 100, framed.height + 100), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([50, 50, framed.width + 50, framed.height + 50],
                                             radius=max(30, framed.width // 12), fill=(0, 0, 0, 185))
    shadow = shadow.filter(ImageFilter.GaussianBlur(35))
    x = (width - framed.width) // 2
    canvas.paste(shadow, (x - 50, device_top - 30), shadow)
    canvas.paste(framed, (x, device_top), framed)

    shot.close()
    framed.close()
    shadow.close()
    return canvas


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*-iphone-1320x2868.png"):
        old.unlink()
    for old in OUT.glob("*-ipad-2064x2752.png"):
        old.unlink()

    count = 0
    for device in ("iphone", "ipad"):
        width, height = SIZES[device]
        for scene, (order, _, _) in SCENES.items():
            image = compose(device, scene)
            output = OUT / f"{order}-{scene}-{device}-{width}x{height}.png"
            image.save(output, optimize=True)
            print(f"wrote {output.name}")
            image.close()
            gc.collect()
            count += 1
    print(f"generated {count} App Store screenshots")


if __name__ == "__main__":
    main()
