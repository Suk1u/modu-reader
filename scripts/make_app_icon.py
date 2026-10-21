"""生成 App 图标（1024x1024 PNG）。

构图：深色底 + 暖色光晕 + 一本合起的书（书脊在左、书页在右），
书页上有几行墨色文字。所有元素严格落在安全边距内。
"""

from PIL import Image, ImageDraw, ImageFilter
import os

SIZE = 1024
MARGIN = SIZE * 0.14
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ModuReader", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png",
)

BG_TOP = (48, 41, 35)
BG_BOTTOM = (20, 18, 16)
PAPER = (247, 243, 232)
PAPER_EDGE = (222, 213, 195)
SPINE = (196, 130, 62)
SPINE_DARK = (166, 105, 44)
INK = (32, 29, 26)


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        draw.line(
            [(0, y), (size, y)],
            fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
        )
    return img


def main():
    base = vertical_gradient(SIZE, BG_TOP, BG_BOTTOM).convert("RGBA")

    # 暖色光晕，偏右上，柔化背景
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        [SIZE * 0.30, -SIZE * 0.30, SIZE * 1.10, SIZE * 0.55],
        fill=(196, 130, 62, 70),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(SIZE * 0.10))
    base = Image.alpha_composite(base, glow)

    # ---- 书的几何：整体在 MARGIN 内 ----
    book_left = MARGIN
    book_right = SIZE - MARGIN
    book_top = MARGIN
    book_bottom = SIZE - MARGIN
    book_w = book_right - book_left
    book_h = book_bottom - book_top

    spine_w = book_w * 0.20
    radius = SIZE * 0.030

    # 投影
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [book_left + SIZE * 0.012, book_top + SIZE * 0.030,
         book_right + SIZE * 0.012, book_bottom + SIZE * 0.030],
        radius=radius * 1.4,
        fill=(0, 0, 0, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(SIZE * 0.030))
    base = Image.alpha_composite(base, shadow)

    # 书页（右侧主体）
    page = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    pd = ImageDraw.Draw(page)
    pd.rounded_rectangle(
        [book_left + spine_w * 0.55, book_top,
         book_right, book_bottom],
        radius=radius,
        fill=PAPER,
    )
    # 书页右缘的层次感（模拟纸叠）
    pd.rounded_rectangle(
        [book_right - book_w * 0.035, book_top + SIZE * 0.004,
         book_right - book_w * 0.004, book_bottom - SIZE * 0.004],
        radius=radius * 0.7,
        fill=PAPER_EDGE,
    )
    base = Image.alpha_composite(base, page)

    # 书脊
    spine = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spine)
    sd.rounded_rectangle(
        [book_left, book_top, book_left + spine_w, book_bottom],
        radius=radius,
        fill=SPINE,
    )
    # 书脊上的两道压痕
    for offset in (0.26, 0.74):
        y = book_top + book_h * offset
        sd.rounded_rectangle(
            [book_left + spine_w * 0.22, y - SIZE * 0.008,
             book_left + spine_w * 0.78, y + SIZE * 0.008],
            radius=SIZE * 0.008,
            fill=SPINE_DARK,
        )
    base = Image.alpha_composite(base, spine)

    # 书页上的文字行
    text = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    td = ImageDraw.Draw(text)
    text_left = book_left + spine_w * 0.55 + book_w * 0.13
    line_height = SIZE * 0.020
    gaps = [0.24, 0.36, 0.48, 0.60]
    widths = [0.62, 0.54, 0.60, 0.38]
    for gap, w_ratio in zip(gaps, widths):
        y = book_top + book_h * gap
        td.rounded_rectangle(
            [text_left, y, text_left + book_w * w_ratio, y + line_height],
            radius=line_height / 2,
            fill=INK + (185,),
        )
    base = Image.alpha_composite(base, text)

    # 右下角的墨点记号
    dot = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    cx = book_right - book_w * 0.13
    cy = book_bottom - book_h * 0.16
    r = SIZE * 0.040
    ImageDraw.Draw(dot).ellipse([cx - r, cy - r, cx + r, cy + r], fill=SPINE + (255,))
    base = Image.alpha_composite(base, dot)

    base = base.convert("RGB")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    base.save(OUT, "PNG", optimize=True)
    print(f"generated {OUT} ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    main()
