from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_SETI_INPUT = SCRIPT_DIR / "source" / "glance-theme-seti_black.png"
DEFAULT_LIGHT_INPUT = SCRIPT_DIR / "source" / "glance-theme-one_light.png"
DEFAULT_OUTPUT = SCRIPT_DIR / "dist" / "glance-themes.png"

FONT_CANDIDATES = [
    Path.home() / "Library" / "Fonts" / "JetBrainsMono-SemiBold.ttf",
    Path.home() / "Library" / "Fonts" / "JetBrainsMono-Medium.ttf",
    Path("/Library/Fonts/JetBrainsMono-Regular.ttf"),
    Path("/System/Library/Fonts/Menlo.ttc"),
    Path("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"),
]

PILL_STYLES = {
    "seti_black": {
        "fill": "#4B3212",
        "stroke": "#9C6C2B",
        "text_color": "#F5E5C8",
    },
    "one_light": {
        "fill": "#D9E1FF",
        "stroke": "#91A5FF",
        "text_color": "#445A9A",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate the README theme comparison image.")
    parser.add_argument("--seti-input", type=Path, default=DEFAULT_SETI_INPUT)
    parser.add_argument("--light-input", type=Path, default=DEFAULT_LIGHT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--font-path", type=Path, default=None)
    parser.add_argument("--width", type=int, default=1440)
    parser.add_argument("--feather", type=float, default=2.0)
    parser.add_argument("--label-font-size", type=int, default=28)
    return parser.parse_args()


def parse_hex_color(value: str, alpha: int = 255) -> tuple[int, int, int, int]:
    cleaned = value.strip().lstrip("#")
    if len(cleaned) != 6:
        raise ValueError(f"expected a 6-digit hex color, got {value!r}")
    red, green, blue = (int(cleaned[index:index + 2], 16) for index in range(0, 6, 2))
    return red, green, blue, alpha


def resolve_font(explicit_path: Path | None, size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [explicit_path] if explicit_path else []
    candidates.extend(FONT_CANDIDATES)

    for candidate in candidates:
        if candidate and candidate.exists():
            return ImageFont.truetype(str(candidate), size=size)

    return ImageFont.load_default()


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def crop_to_shared_frame(left: Image.Image, right: Image.Image) -> tuple[Image.Image, Image.Image]:
    shared_width = min(left.width, right.width)
    shared_height = min(left.height, right.height)

    def crop(image: Image.Image) -> Image.Image:
        offset_x = (image.width - shared_width) // 2
        offset_y = (image.height - shared_height) // 2
        return image.crop((offset_x, offset_y, offset_x + shared_width, offset_y + shared_height))

    return crop(left), crop(right)


def resize_to_width(image: Image.Image, width: int) -> Image.Image:
    if image.width == width:
        return image

    height = round(image.height * (width / image.width))
    return image.resize((width, height), Image.Resampling.LANCZOS)


def diagonal_mask(size: tuple[int, int], feather: float) -> Image.Image:
    width, height = size
    x1 = float(width - 1)
    y2 = float(height - 1)
    denominator = ((y2 * y2) + (x1 * x1)) ** 0.5
    transition = max(feather, 0.001)

    mask = Image.new("L", size, 0)
    pixels = mask.load()

    for y in range(height):
        py = y + 0.5
        for x in range(width):
            px = x + 0.5
            signed_distance = ((x1 * y2) - (y2 * px) - (x1 * py)) / denominator
            t = max(0.0, min(1.0, 0.5 + (signed_distance / transition)))
            t = t * t * (3.0 - (2.0 * t))
            pixels[x, y] = round(t * 255)

    return mask


def measure_text(font: ImageFont.ImageFont, text: str) -> float:
    if hasattr(font, "getlength"):
        return float(font.getlength(text))
    bbox = font.getbbox(text)
    return float(bbox[2] - bbox[0])


def draw_label(
    image: Image.Image,
    *,
    text: str,
    origin: tuple[int, int],
    font: ImageFont.ImageFont,
    fill: str,
    stroke: str,
    text_color: str,
) -> None:
    draw = ImageDraw.Draw(image)
    text_width = measure_text(font, text)
    text_height = font.size if hasattr(font, "size") else 18
    padding_x = 16
    padding_y = 10
    x, y = origin
    box = (
        x,
        y,
        x + int(text_width) + (padding_x * 2),
        y + text_height + (padding_y * 2),
    )
    draw.rounded_rectangle(
        box,
        radius=18,
        fill=parse_hex_color(fill, 235),
        outline=parse_hex_color(stroke),
        width=2,
    )
    draw.text(
        (x + padding_x, y + padding_y - 1),
        text,
        font=font,
        fill=parse_hex_color(text_color),
    )


def main() -> None:
    args = parse_args()

    seti = Image.open(args.seti_input).convert("RGBA")
    one_light = Image.open(args.light_input).convert("RGBA")
    seti, one_light = crop_to_shared_frame(seti, one_light)
    seti = resize_to_width(seti, args.width)
    one_light = resize_to_width(one_light, args.width)

    if seti.size != one_light.size:
        raise RuntimeError("source screenshots must match after crop and resize")

    composite = Image.composite(seti, one_light, diagonal_mask(seti.size, feather=args.feather))

    font = resolve_font(args.font_path, size=args.label_font_size)
    draw_label(
        composite,
        text="seti_black",
        origin=(84, 118),
        font=font,
        **PILL_STYLES["seti_black"],
    )
    draw_label(
        composite,
        text="one_light",
        origin=(composite.width - 240, composite.height - 124),
        font=font,
        **PILL_STYLES["one_light"],
    )

    ensure_parent(args.output)
    composite.save(args.output)

    print(f"seti_input={args.seti_input}")
    print(f"light_input={args.light_input}")
    print(f"output={args.output}")
    print(f"size={composite.width}x{composite.height}")


if __name__ == "__main__":
    main()
