from __future__ import annotations

import argparse
import math
import random
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_INPUT = SCRIPT_DIR / "source" / "glance-final.png"
DEFAULT_POSTER = SCRIPT_DIR / "dist" / "glance-hero-poster.png"
DEFAULT_GIF = SCRIPT_DIR / "dist" / "glance-hero-stars.gif"
DEFAULT_MASK = SCRIPT_DIR / "dist" / "glance-hero-mask.png"

STAR_FRAMES = [
    (".", 0),
    (".", 28),
    (".", 76),
    ("+", 128),
    ("*", 230),
    ("+", 128),
    (".", 76),
    (".", 28),
]

FONT_CANDIDATES = [
    Path.home() / "Library" / "Fonts" / "JetBrainsMono-Regular.ttf",
    Path.home() / "Library" / "Fonts" / "JetBrainsMono-Medium.ttf",
    Path.home() / "Library" / "Fonts" / "JetBrainsMono-Light.ttf",
    Path("/Library/Fonts/JetBrainsMono-Regular.ttf"),
]


@dataclass(frozen=True)
class Star:
    x: int
    y: int
    offset: int
    speed: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate animated README hero assets.")
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--poster-output", type=Path, default=DEFAULT_POSTER)
    parser.add_argument("--gif-output", type=Path, default=DEFAULT_GIF)
    parser.add_argument("--mask-output", type=Path, default=DEFAULT_MASK)
    parser.add_argument("--font-path", type=Path, default=None)
    parser.add_argument("--frames", type=int, default=24)
    parser.add_argument("--frame-ms", type=int, default=150)
    parser.add_argument("--star-count", type=int, default=14)
    parser.add_argument("--font-size", type=int, default=24)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--mask-distance", type=float, default=86.0)
    parser.add_argument("--logo-padding", type=int, default=25)
    parser.add_argument("--logo-color", type=str, default="#FD971F")
    parser.add_argument("--star-color", type=str, default="#FFFFFF")
    parser.add_argument("--skip-mask-export", action="store_true")
    return parser.parse_args()


def parse_hex_color(value: str) -> tuple[int, int, int]:
    cleaned = value.strip().lstrip("#")
    if len(cleaned) != 6:
        raise ValueError(f"expected a 6-digit hex color, got {value!r}")
    return tuple(int(cleaned[index:index + 2], 16) for index in range(0, 6, 2))


def resolve_font_path(explicit_path: Path | None) -> Path:
    if explicit_path:
        if not explicit_path.exists():
            raise FileNotFoundError(f"font not found: {explicit_path}")
        return explicit_path

    for candidate in FONT_CANDIDATES:
        if candidate.exists():
            return candidate

    raise FileNotFoundError("JetBrains Mono not found. Pass --font-path to override.")


def extract_logo_mask(
    image: Image.Image,
    target_rgb: tuple[int, int, int],
    max_distance: float,
) -> Image.Image:
    rgba = image.convert("RGBA")
    source = rgba.load()
    mask = Image.new("L", rgba.size, 0)
    mask_pixels = mask.load()

    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = source[x, y]
            if alpha == 0:
                continue

            distance = math.sqrt(
                (red - target_rgb[0]) ** 2
                + (green - target_rgb[1]) ** 2
                + (blue - target_rgb[2]) ** 2
            )
            if distance > max_distance:
                continue

            strength = max(0.0, 1.0 - (distance / max_distance))
            mask_pixels[x, y] = int((strength ** 1.75) * alpha)

    return mask


def binary_mask(mask: Image.Image, threshold: int = 92) -> Image.Image:
    return mask.point(lambda value: 255 if value >= threshold else 0)


def alpha_mask(image: Image.Image, threshold: int = 1) -> Image.Image:
    return image.getchannel("A").point(lambda value: 255 if value >= threshold else 0)


def build_plaque_mask(base: Image.Image, logo_mask: Image.Image, logo_padding: int) -> Image.Image:
    visible = alpha_mask(base)
    exclusion = binary_mask(logo_mask)

    if logo_padding > 1:
        filter_size = logo_padding if logo_padding % 2 == 1 else logo_padding + 1
        exclusion = exclusion.filter(ImageFilter.MaxFilter(size=filter_size))

    return ImageChops.subtract(visible, exclusion)


def pick_stars(
    mask: Image.Image,
    count: int,
    font_size: int,
    seed: int,
) -> list[Star]:
    bbox = binary_mask(mask).getbbox()
    if bbox is None:
        raise RuntimeError("no logo mask detected in the input image")

    rng = random.Random(seed)
    min_distance = max(18, int(font_size * 0.95))
    stars: list[Star] = []

    for _ in range(count * 300):
        x = rng.randint(bbox[0], bbox[2] - 1)
        y = rng.randint(bbox[1], bbox[3] - 1)
        if mask.getpixel((x, y)) < 92:
            continue

        if any((x - star.x) ** 2 + (y - star.y) ** 2 < min_distance ** 2 for star in stars):
            continue

        stars.append(
            Star(
                x=x,
                y=y,
                offset=rng.randrange(len(STAR_FRAMES) * 3),
                speed=1 + rng.randrange(3),
            )
        )
        if len(stars) == count:
            break

    if not stars:
        raise RuntimeError("failed to place any stars on the logo mask")

    return stars


def frame_state(star: Star, tick: int) -> tuple[str, int]:
    index = ((tick + star.offset) // star.speed) % len(STAR_FRAMES)
    return STAR_FRAMES[index]


def render_frame(
    base: Image.Image,
    mask: Image.Image,
    stars: list[Star],
    font: ImageFont.FreeTypeFont,
    tick: int,
    star_rgb: tuple[int, int, int],
) -> Image.Image:
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    for star in stars:
        glyph, alpha = frame_state(star, tick)
        if alpha == 0:
            continue
        draw.text(
            (star.x, star.y),
            glyph,
            font=font,
            fill=(*star_rgb, alpha),
            anchor="mm",
        )

    clipped_alpha = ImageChops.multiply(overlay.getchannel("A"), mask)
    overlay.putalpha(clipped_alpha)
    return Image.alpha_composite(base, overlay)


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def main() -> None:
    args = parse_args()
    logo_color = parse_hex_color(args.logo_color)
    star_color = parse_hex_color(args.star_color)
    font_path = resolve_font_path(args.font_path)

    base = Image.open(args.input).convert("RGBA")
    logo_mask = extract_logo_mask(base, target_rgb=logo_color, max_distance=args.mask_distance)
    plaque_mask = build_plaque_mask(base, logo_mask, logo_padding=args.logo_padding)
    font = ImageFont.truetype(str(font_path), size=args.font_size)
    stars = pick_stars(plaque_mask, count=args.star_count, font_size=args.font_size, seed=args.seed)

    frames = [
        render_frame(base, plaque_mask, stars, font, tick=tick, star_rgb=star_color)
        for tick in range(args.frames)
    ]

    ensure_parent(args.poster_output)
    ensure_parent(args.gif_output)
    base.save(args.poster_output)
    frames[0].save(
        args.gif_output,
        save_all=True,
        append_images=frames[1:],
        duration=args.frame_ms,
        loop=0,
        optimize=True,
        disposal=2,
    )

    if not args.skip_mask_export:
        ensure_parent(args.mask_output)
        binary_mask(plaque_mask).save(args.mask_output)

    print(f"input={args.input}")
    print(f"poster={args.poster_output}")
    print(f"gif={args.gif_output}")
    if not args.skip_mask_export:
        print(f"mask={args.mask_output}")
    print(f"font={font_path}")
    print(f"stars={len(stars)} frames={args.frames} frame_ms={args.frame_ms}")


if __name__ == "__main__":
    main()
