#!/usr/bin/env python3
"""生成 App 图标母版 assets/AppIcon.png（1024×1024），tools/package.sh 由它出各尺寸 .icns。

    python3 tools/make-icon.py

按 Apple macOS 图标规范（Big Sur 起的 App Icon 模板）：
- 画布 1024，主体是居中的 824×824 圆角方块（四边留 100px 给投影和光学对齐）；
- 圆角用连续曲率的超椭圆（squircle），不是普通圆弧圆角；
- 主体下方一层柔和投影（模板：黑色约 30%，向下约 10px，模糊约 20px）；
- 图案（Claude 星形）在主体里再留出呼吸空间，约占主体宽度的 64%。
星形用 assets/claude-color.svg 的矢量路径（边缘平滑）；底色沿用原图标的橙色渐变。
整张图拼成 SVG 交给 Chromium（Playwright）渲染成透明底 PNG。
Icon Composer 的 .icon（液态玻璃）要 Xcode 的 actool 编译，本机只有 Command Line Tools，用不了。
"""
import math
import re
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "AppIcon.png"

CANVAS = 1024
BODY = 824
GLYPH = 0.64           # 星形宽度 / 主体宽度
SQUIRCLE_N = 5.0       # 超椭圆指数：接近 Apple 的连续圆角
TOP, BOTTOM = "#E97A56", "#EC6B41"   # 与 assets/claude-icon-2048-bright.svg 一致


def squircle_path(size: float, offset: float, steps: int = 1440) -> str:
    """超椭圆 |x|^n + |y|^n = 1 的 SVG 路径"""
    r = size / 2
    c = offset + r
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = c + r * math.copysign(abs(ct) ** (2 / SQUIRCLE_N), ct)
        y = c + r * math.copysign(abs(st) ** (2 / SQUIRCLE_N), st)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(pts) + " Z"


def star_path() -> str:
    svg = (ROOT / "assets" / "claude-color.svg").read_text()
    return re.search(r'<path d="([^"]+)"', svg).group(1)


def icon_svg() -> str:
    off = (CANVAS - BODY) / 2
    body = squircle_path(BODY, off)
    glyph = BODY * GLYPH
    scale = glyph / 24          # claude-color.svg 的 viewBox 是 24×24
    g_off = (CANVAS - glyph) / 2
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{TOP}"/><stop offset="1" stop-color="{BOTTOM}"/></linearGradient>
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity="0.3"/>
  </filter>
</defs>
<path d="{body}" fill="url(#bg)" filter="url(#shadow)"/>
<path d="{star_path()}" fill="#fff" transform="translate({g_off:.2f} {g_off:.2f}) scale({scale:.4f})"/>
</svg>"""


def main() -> None:
    html = f'<html><body style="margin:0;background:transparent">{icon_svg()}</body></html>'
    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": CANVAS, "height": CANVAS}, device_scale_factor=1)
        page.set_content(html)
        page.locator("svg").screenshot(path=str(OUT), omit_background=True)
        b.close()
    print("写出", OUT.relative_to(ROOT))


if __name__ == "__main__":
    main()
