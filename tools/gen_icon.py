"""生成 HarmonyOS 分层应用图标：高级蓝背景 + 白色对号（带轻阴影）。

输出（1024x1024 分层图标规范）：
  background.png  纯背景层（满幅，由系统裁剪形状）
  foreground.png  前景层（透明底，只含对号 + 阴影，内容留在安全区内）
  startIcon.png   启动页图标（非分层，圆角蓝底 + 对号）
  docs/icon-preview.png  预览图（浅色/深色桌面 + 小尺寸）
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT_APP = "AppScope/resources/base/media"
OUT_ENTRY = "entry/src/main/resources/base/media"
PREVIEW = "docs/icon-preview.png"


def gradient_background() -> Image.Image:
    """135° 高级蓝渐变 + 左上柔光 + 底部微暗，做出一点纵深。"""
    y, x = np.mgrid[0:S, 0:S].astype(np.float32)
    # 归一化的对角进度：左上 0 → 右下 1
    t = (x + y) / (2.0 * (S - 1))
    t = np.clip(t, 0.0, 1.0)

    c0 = np.array([47, 107, 255], dtype=np.float32)   # #2F6BFF 左上
    c1 = np.array([11, 47, 174], dtype=np.float32)    # #0B2FAE 右下
    rgb = c0[None, None, :] * (1 - t[..., None]) + c1[None, None, :] * t[..., None]

    # 左上柔光（模拟光源），让纯色渐变不那么"平"
    gx, gy = 0.28 * S, 0.22 * S
    r = np.sqrt((x - gx) ** 2 + (y - gy) ** 2) / (0.85 * S)
    glow = np.clip(1.0 - r, 0.0, 1.0) ** 2 * 0.16
    rgb = rgb + (255.0 - rgb) * glow[..., None]

    # 底部轻微压暗，增加"厚度"
    shade = np.clip((y / (S - 1) - 0.55) / 0.45, 0.0, 1.0) * 0.18
    rgb = rgb * (1.0 - shade[..., None])

    rgb = np.clip(rgb, 0, 255).astype(np.uint8)
    img = Image.fromarray(rgb, mode="RGB").convert("RGBA")

    # 极细的顶部高光边（内描边，1px 级别），实机上更"精致"
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=0, outline=(255, 255, 255, 26), width=6)
    return img


def capsule(draw: ImageDraw.ImageDraw, p1, p2, width: int, fill):
    """画一条圆头粗线（胶囊），用于对号的两个笔画。"""
    x1, y1 = p1
    x2, y2 = p2
    dx, dy = x2 - x1, y2 - y1
    length = math.hypot(dx, dy)
    if length == 0:
        draw.ellipse([x1 - width / 2, y1 - width / 2, x1 + width / 2, y1 + width / 2], fill=fill)
        return
    ux, uy = -dy / length, dx / length
    h = width / 2.0
    poly = [
        (x1 + ux * h, y1 + uy * h),
        (x2 + ux * h, y2 + uy * h),
        (x2 - ux * h, y2 - uy * h),
        (x1 - ux * h, y1 - uy * h),
    ]
    draw.polygon(poly, fill=fill)
    draw.ellipse([x1 - h, y1 - h, x1 + h, y1 + h], fill=fill)
    draw.ellipse([x2 - h, y2 - h, x2 + h, y2 + h], fill=fill)


def check_mask(scale: float = 1.0, dx: float = 0.0, dy: float = 0.0) -> Image.Image:
    """对号形状的 alpha 蒙版（白色不透明）。

    坐标以 1024 画布的**中心**为基准缩放，这样调大小不会让对号跑偏。
    """
    m = Image.new("L", (S * 4, S * 4), 0)  # 4 倍超采样，边缘更干净
    d = ImageDraw.Draw(m)
    stroke = int(118 * 4 * scale)
    cx = cy = S / 2.0

    def pt(px, py):
        sx = cx + (px - cx) * scale + dx
        sy = cy + (py - cy) * scale + dy
        return (sx * 4, sy * 4)

    p_start = pt(300, 522)
    p_mid = pt(447, 668)
    p_end = pt(737, 358)
    capsule(d, p_start, p_mid, stroke, 255)
    capsule(d, p_mid, p_end, stroke, 255)
    return m.resize((S, S), Image.LANCZOS)


# 对号相对基准坐标的放大倍数（1.18 时包围盒约 655x505，仍落在图标安全区内）
CHECK_SCALE = 1.18


def foreground() -> Image.Image:
    """透明前景：白色对号 + 一点很轻的投影。"""
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 阴影：对号蒙版轻微下移 + 模糊，只留"一点点"的层次
    shadow = check_mask(scale=CHECK_SCALE, dx=0.0, dy=8.0)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=14))
    shadow_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow_layer.putalpha(shadow.point(lambda v: int(v * 0.22)))
    fg = Image.alpha_composite(fg, shadow_layer)

    # 白色对号
    white = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    white.putalpha(check_mask(scale=CHECK_SCALE))
    fg = Image.alpha_composite(fg, white)
    return fg


def squircle_mask(size: int, radius_ratio: float = 0.235) -> Image.Image:
    mask = Image.new("L", (size * 4, size * 4), 0)
    d = ImageDraw.Draw(mask)
    r = int(size * 4 * radius_ratio)
    d.rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=r, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def compose_icon(bg: Image.Image, fg: Image.Image, size: int) -> Image.Image:
    base = Image.alpha_composite(bg, fg).resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(base, (0, 0), squircle_mask(size))
    return out


def build_preview(icon: Image.Image) -> None:
    """浅色桌面 + 深色桌面 + 小尺寸，方便肉眼确认。"""
    W, H = 1180, 420
    canvas = Image.new("RGB", (W, H), (246, 247, 249))
    dark = Image.new("RGB", (W // 2, H), (18, 19, 22))
    canvas.paste(dark, (W // 2, 0))

    big = icon.resize((240, 240), Image.LANCZOS)
    small = icon.resize((72, 72), Image.LANCZOS)
    canvas.paste(big, (90, 90), big)
    canvas.paste(small, (420, 110), small)
    canvas.paste(small, (420, 230), small)
    canvas.paste(big, (W // 2 + 80, 90), big)
    canvas.paste(small, (W // 2 + 400, 110), small)
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    canvas.save(PREVIEW)


def main() -> None:
    bg = gradient_background()
    fg = foreground()

    for out_dir in (OUT_APP, OUT_ENTRY):
        os.makedirs(out_dir, exist_ok=True)
        bg.save(os.path.join(out_dir, "background.png"))
        fg.save(os.path.join(out_dir, "foreground.png"))

    # 启动页图标：非分层，圆角蓝底 + 对号（从 4 倍尺寸缩下来保证清晰）
    start_big = compose_icon(bg, fg, 608)
    start_big.resize((152, 152), Image.LANCZOS).save(os.path.join(OUT_ENTRY, "startIcon.png"))

    build_preview(compose_icon(bg, fg, 512))
    print("icon written:")
    for p in (f"{OUT_APP}/background.png", f"{OUT_APP}/foreground.png",
              f"{OUT_ENTRY}/background.png", f"{OUT_ENTRY}/foreground.png",
              f"{OUT_ENTRY}/startIcon.png", PREVIEW):
        print(" ", p, Image.open(p).size)


if __name__ == "__main__":
    main()
