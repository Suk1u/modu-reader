"""生成无封面占位图（CoverPlaceholder）。

风格参照用户提供的「暂无封面」图：
- 青绿色背景 + 细网格
- 左侧竖排「作者太懒」
- 右上白框内「暂无封面」
- 底部白色描边的可爱史莱姆
"""

from PIL import Image, ImageDraw, ImageFilter, ImageFont
import os

W, H = 900, 1200
OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ModuReader", "Resources", "Assets.xcassets", "CoverPlaceholder.imageset",
)

BG = (64, 208, 208)
GRID = (56, 196, 196)
WHITE = (255, 255, 255)
SLIME_BODY = (72, 214, 214)
SLIME_SHINE = (150, 235, 235)


def load_font(size):
    for candidate in [
        "C:/Windows/Fonts/msyhbd.ttc",
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/simhei.ttf",
    ]:
        if os.path.exists(candidate):
            try:
                return ImageFont.truetype(candidate, size)
            except Exception:
                continue
    return None


def draw_grid(draw):
    step = 90
    for x in range(0, W, step):
        draw.line([(x, 0), (x, H)], fill=GRID, width=2)
    for y in range(0, H, step):
        draw.line([(0, y), (W, y)], fill=GRID, width=2)


def rounded_box(draw, box, radius, outline, width):
    draw.rounded_rectangle(box, radius=radius, outline=outline, width=width)


def main():
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)
    draw_grid(draw)

    # ---- 左侧竖排「作者太懒」 ----
    left_box = [W * 0.06, H * 0.06, W * 0.26, H * 0.47]
    rounded_box(draw, left_box, radius=18, outline=WHITE, width=6)

    font_v = load_font(int(W * 0.082))
    if font_v:
        chars = "作者太懒"
        char_h = H * 0.082
        start_y = left_box[1] + H * 0.045
        for index, ch in enumerate(chars):
            bbox = draw.textbbox((0, 0), ch, font=font_v)
            tw = bbox[2] - bbox[0]
            th = bbox[3] - bbox[1]
            draw.text(
                (left_box[0] + (left_box[2] - left_box[0] - tw) / 2,
                 start_y + index * char_h - bbox[1]),
                ch,
                font=font_v,
                fill=WHITE,
            )

    # ---- 右侧「暂无封面」大白框 ----
    right_box = [W * 0.32, H * 0.055, W * 0.94, H * 0.33]
    rounded_box(draw, right_box, radius=22, outline=WHITE, width=8)

    font_big = load_font(int(W * 0.145))
    if font_big:
        lines = ["暂无", "封面"]
        line_h = H * 0.135
        total_h = line_h * len(lines)
        start_y = right_box[1] + (right_box[3] - right_box[1] - total_h) / 2
        for index, line in enumerate(lines):
            bbox = draw.textbbox((0, 0), line, font=font_big)
            tw = bbox[2] - bbox[0]
            th = bbox[3] - bbox[1]
            draw.text(
                (right_box[0] + (right_box[2] - right_box[0] - tw) / 2,
                 start_y + index * line_h + (line_h - th) / 2 - bbox[1]),
                line,
                font=font_big,
                fill=WHITE,
            )

    # ---- 底部史莱姆 ----
    slime = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(slime)

    cx = W * 0.52
    cy = H * 0.70
    body_w = W * 0.58
    body_h = H * 0.24

    # 身体：上圆下方
    sd.ellipse(
        [cx - body_w / 2, cy - body_h * 0.72,
         cx + body_w / 2, cy + body_h * 0.62],
        fill=SLIME_BODY + (255,),
        outline=WHITE,
        width=10,
    )
    sd.rounded_rectangle(
        [cx - body_w / 2, cy, cx + body_w / 2, cy + body_h * 0.42],
        radius=int(body_w * 0.22),
        fill=SLIME_BODY + (255,),
    )
    # 重新描边底部
    sd.arc(
        [cx - body_w / 2, cy - body_h * 0.10,
         cx + body_w / 2, cy + body_h * 0.95],
        start=20, end=160, fill=WHITE, width=10,
    )

    # 小手
    for sign in (-1, 1):
        hx = cx + sign * body_w * 0.46
        sd.ellipse(
            [hx - body_w * 0.09, cy + body_h * 0.02,
             hx + body_w * 0.09, cy + body_h * 0.24],
            fill=SLIME_BODY + (255,),
            outline=WHITE,
            width=8,
        )

    # 高光
    sd.ellipse(
        [cx - body_w * 0.30, cy - body_h * 0.58,
         cx - body_w * 0.10, cy - body_h * 0.40],
        fill=SLIME_SHINE + (230,),
    )
    sd.ellipse(
        [cx + body_w * 0.14, cy - body_h * 0.52,
         cx + body_w * 0.24, cy - body_h * 0.44],
        fill=SLIME_SHINE + (200,),
    )

    # 眼睛
    eye_y = cy - body_h * 0.20
    eye_dx = body_w * 0.17
    eye_r = body_w * 0.055
    for sign in (-1, 1):
        ex = cx + sign * eye_dx
        sd.ellipse(
            [ex - eye_r, eye_y - eye_r, ex + eye_r, eye_y + eye_r],
            fill=WHITE + (255,),
        )

    # 大嘴
    mouth_w = body_w * 0.34
    mouth_h = body_h * 0.20
    sd.ellipse(
        [cx - mouth_w / 2, cy + body_h * 0.02,
         cx + mouth_w / 2, cy + body_h * 0.02 + mouth_h],
        fill=WHITE + (255,),
    )
    # 嘴巴上的缺口（做成笑口）
    sd.polygon(
        [
            (cx - mouth_w * 0.30, cy + body_h * 0.02),
            (cx - mouth_w * 0.16, cy + body_h * 0.10),
            (cx, cy + body_h * 0.03),
            (cx + mouth_w * 0.16, cy + body_h * 0.10),
            (cx + mouth_w * 0.30, cy + body_h * 0.02),
        ],
        fill=SLIME_BODY + (255,),
    )

    img = Image.alpha_composite(img.convert("RGBA"), slime).convert("RGB")

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, "CoverPlaceholder.png")
    img.save(out, "PNG", optimize=True)
    print(f"generated {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
