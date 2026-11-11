#!/usr/bin/env python3
"""README 展示图：用 Snapshot 渲染的真实面板拼成两张设计稿式大图（中、英各一套）。

    python3 tools/readme-art/build.py            # 输出到 docs/images/
    python3 tools/readme-art/build.py --skip-snapshot   # 复用 /tmp/cswap-readme-shots 里已有的面板图

步骤：swift run Snapshot → 裁掉面板外的 16pt 灰边 → 填进 HTML 版式 → Playwright（Chromium，2x）截图 → cwebp 转 WebP（brew install webp）。
面板图是 2x 渲染（宽 704px = 352pt），版式里按 CSS px 摆放，最终 PNG 也是 2x。
"""
from __future__ import annotations

import base64
import io
import subprocess
import sys
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
SHOTS = Path("/tmp/cswap-readme-shots")
OUT = ROOT / "docs" / "images"
PAD = 32  # Snapshot 面板外边距 16pt × 2x

# ---------------------------------------------------------------- 文案

TEXT = {
    "zh": {
        "lang": "zh-CN",
        "title": "cswap",
        "tagline": "Claude Code 多账号，<br>一眼看清，一键切换。",
        "points": [
            ("gauge", "菜单栏直接显示 5 小时 / 本周用量"),
            ("swap", "快用完时自动换到余量最多的号"),
            ("clock", "每个号的额度什么时候刷新，一目了然"),
            ("bell", "自动换号、全部用完、登录快过期都会提醒"),
        ],
        "foot": "macOS 14+ · 原生 Swift · 搭配 claude-swap 命令行",
        "clock": "11月11日 周三  09:41",
        "pages_title": "需要的都在面板里",
        "pages": [
            ("账号详情", "用量、登录有效期、单独阈值与优先级"),
            ("自动切换", "阈值、换号策略、冷却时间"),
            ("设置", "菜单栏显示、通知、登录时打开、自动更新"),
            ("切换记录", "面板、自动、命令行换的号都记着"),
        ],
        "menubar": ("菜单栏", "两者 / 只看本周 / 快到阈值变色"),
    },
    "en": {
        "lang": "en",
        "title": "cswap",
        "tagline": "Every Claude Code account,<br>at a glance. One click to switch.",
        "points": [
            ("gauge", "5-hour and weekly usage right in the menu bar"),
            ("swap", "Auto-switches to the account with the most quota left"),
            ("clock", "See when each account's quota resets"),
            ("bell", "Notifies on auto-switch, all used up, login expiring"),
        ],
        "foot": "macOS 14+ · Native Swift · Built on the claude-swap CLI",
        "clock": "Wed Nov 11  9:41 AM",
        "pages_title": "Everything you need, one click away",
        "pages": [
            ("Account details", "Usage, login expiry, per-account threshold"),
            ("Auto-switch", "Thresholds, strategy, cooldown"),
            ("Settings", "Menu bar, notifications, auto-update"),
            ("Switch history", "From the panel, auto-switch or the CLI"),
        ],
        "menubar": ("Menu bar", "Both, weekly only, amber near the limit"),
    },
}

# 线性图标（SF Symbols 风格的简化 SVG）
ICONS = {
    "gauge": '<path d="M4 15a8 8 0 1 1 16 0"/><path d="M12 15l4-5"/>',
    "swap": '<path d="M5 8h13l-3-3"/><path d="M19 16H6l3 3"/>',
    "clock": '<circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/>',
    "bell": '<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20a2 2 0 0 0 4 0"/>',
}


def icon(name: str) -> str:
    return (f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
            f'stroke-linecap="round" stroke-linejoin="round">{ICONS[name]}</svg>')


# ---------------------------------------------------------------- 面板图

def snapshot() -> None:
    subprocess.run(["swift", "run", "Snapshot", str(SHOTS)], cwd=ROOT, check=True)


def panel(name: str) -> tuple[str, int, int]:
    """裁掉灰边，返回 data URI 与 CSS 尺寸（2x → 1x）"""
    im = Image.open(SHOTS / f"{name}.png").convert("RGB")
    im = im.crop((PAD, PAD, im.width - PAD, im.height - PAD))
    buf = io.BytesIO()
    im.save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode(), im.width // 2, im.height // 2


def asset(path: str) -> str:
    return "data:image/png;base64," + base64.b64encode((ROOT / path).read_bytes()).decode()


def img(name: str, scale: float = 1.0, cls: str = "panel") -> str:
    uri, w, h = panel(name)
    return f'<img class="{cls}" src="{uri}" style="width:{w * scale:.1f}px;height:{h * scale:.1f}px">'


# ---------------------------------------------------------------- 版式

BASE_CSS = """
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
.panel { display: block; border-radius: 12px;
  box-shadow: 0 0 0 .5px rgba(0,0,0,.18), 0 24px 60px -12px rgba(30,15,5,.45), 0 8px 20px -8px rgba(30,15,5,.25); }
.tray { display: flex; align-items: center; gap: 4px; }
.tray img { width: 18px; height: 18px; }
.tray .nums { display: flex; flex-direction: column; font: 600 9.5px/10.5px system-ui, "PingFang SC"; font-variant-numeric: tabular-nums; }
"""


def tray(dark: bool, top: str, bottom: str, warn: bool = False) -> str:
    ic = asset("assets/TrayIconTemplate@3x.png")
    color = "#fff" if dark else "#1d1d1f"
    filt = "invert(1)" if dark else "none"
    top_color = ("#ffb340" if dark else "#c27c0e") if warn else color
    return (f'<div class="tray" style="color:{color}"><img src="{ic}" style="filter:{filt}">'
            f'<div class="nums"><span style="color:{top_color}">{top}</span><span>{bottom}</span></div></div>')


def hero_html(t: dict) -> str:
    points = "".join(f'<li><span class="ic">{icon(i)}</span><span>{s}</span></li>' for i, s in t["points"])
    return f"""<!doctype html><html lang="{t['lang']}"><head><meta charset="utf-8"><style>{BASE_CSS}
body {{ width: 1200px; height: 700px; overflow: hidden; position: relative;
  background:
    radial-gradient(900px 600px at 85% 15%, #f3b48f 0%, rgba(243,180,143,0) 60%),
    radial-gradient(700px 600px at 10% 100%, #6b3a5c 0%, rgba(107,58,92,0) 65%),
    radial-gradient(800px 500px at 40% 40%, #d97757 0%, rgba(217,119,87,0) 70%),
    linear-gradient(135deg, #8a4a3c 0%, #c9643f 45%, #e9a27a 100%); }}
.grain {{ position: absolute; inset: 0; opacity: .5; mix-blend-mode: soft-light;
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/></filter><rect width='100%' height='100%' filter='url(%23n)' opacity='.35'/></svg>"); }}
.menubar {{ position: absolute; top: 0; left: 0; right: 0; height: 30px; display: flex; align-items: center;
  justify-content: flex-end; gap: 18px; padding: 0 18px; color: #fff; font: 500 13px system-ui, "PingFang SC";
  background: rgba(60,25,15,.28); backdrop-filter: blur(20px); }}
.menubar .apple {{ position: absolute; left: 18px; font-size: 15px; }}
.menubar .item {{ display: flex; align-items: center; height: 22px; padding: 0 7px; border-radius: 5px; }}
.menubar .item.on {{ background: rgba(255,255,255,.22); }}
.menubar svg {{ width: 16px; height: 16px; }}
.copy {{ position: absolute; left: 76px; top: 170px; width: 470px; color: #fff; }}
.copy h1 {{ font: 700 64px/1 system-ui, "PingFang SC"; letter-spacing: -1.5px; display: flex; align-items: center; gap: 16px; }}
.copy h1 img {{ width: 84px; height: 84px; margin: -10px -6px -10px -12px; }}
.copy h2 {{ margin-top: 22px; font: 600 27px/1.32 system-ui, "PingFang SC"; letter-spacing: -.2px; }}
.copy ul {{ list-style: none; margin-top: 34px; display: grid; gap: 14px; }}
.copy li {{ display: flex; align-items: center; gap: 12px; font: 500 15.5px/1.3 system-ui, "PingFang SC"; opacity: .96; }}
.copy .ic {{ flex: none; width: 30px; height: 30px; border-radius: 8px; display: grid; place-items: center;
  background: rgba(255,255,255,.18); box-shadow: inset 0 0 0 .5px rgba(255,255,255,.35); }}
.copy .ic svg {{ width: 17px; height: 17px; }}
.copy .foot {{ margin-top: 40px; font: 500 12.5px system-ui, "PingFang SC"; opacity: .72; letter-spacing: .2px; }}
.back {{ position: absolute; left: 560px; top: 118px; }}
.front {{ position: absolute; right: 26px; top: 38px; }}
</style></head><body><div class="grain"></div>
<div class="menubar"><span class="apple"></span>
  <span class="item on">{tray(True, "34%", "41%")}</span>
  <span class="item"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"><path d="M2.5 9a14 14 0 0 1 19 0"/><path d="M6 12.5a9 9 0 0 1 12 0"/><path d="M9.5 16a4 4 0 0 1 5 0"/><circle cx="12" cy="19" r=".8" fill="#fff"/></svg></span>
  <span>{t['clock']}</span></div>
<div class="copy"><h1><img src="{asset('assets/AppIcon.png')}">{t['title']}</h1><h2>{t['tagline']}</h2>
  <ul>{points}</ul><div class="foot">{t['foot']}</div></div>
<div class="back">{img("20-showcase-detail-dark", 0.92)}</div>
<div class="front">{img("02-tiers-light")}</div>
</body></html>"""


def pages_html(t: dict) -> str:
    cols = [("20-showcase-detail-light", t["pages"][0]), ("21-showcase-auto-dark", t["pages"][1]),
            ("23-showcase-settings-light", t["pages"][2])]
    s = 0.74
    col_html = "".join(f'<div class="col"><div class="cap"><b>{a}</b><span>{b}</span></div>{img(n, s)}</div>'
                       for n, (a, b) in cols)
    mb_title, mb_sub = t["menubar"]
    bars = "".join(f'<div class="bar {"dark" if d else ""}">{tray(d, a, b, w)}</div>'
                   for d, a, b, w in [(False, "34%", "41%", False), (True, "41%", "", False), (True, "90%", "71%", True)])
    last = (f'<div class="col"><div class="cap"><b>{t["pages"][3][0]}</b><span>{t["pages"][3][1]}</span></div>'
            f'{img("22-showcase-history-dark", s)}'
            f'<div class="cap" style="margin-top:30px"><b>{mb_title}</b><span>{mb_sub}</span></div>'
            f'<div class="bars">{bars}</div></div>')
    return f"""<!doctype html><html lang="{t['lang']}"><head><meta charset="utf-8"><style>{BASE_CSS}
body {{ width: 1200px; padding: 56px 40px 60px; color: #2b2320;
  background: radial-gradient(900px 500px at 20% 0%, #fbf3ec 0%, rgba(251,243,236,0) 70%),
              radial-gradient(800px 600px at 100% 100%, #ead9cc 0%, rgba(234,217,204,0) 70%), #f4ece5; }}
h3 {{ text-align: center; font: 700 30px system-ui, "PingFang SC"; letter-spacing: -.4px; margin-bottom: 40px; }}
h3 em {{ font-style: normal; color: #c9643f; }}
.grid {{ display: flex; gap: 22px; justify-content: center; align-items: flex-start; }}
.col {{ width: 260.5px; }}
.cap {{ margin: 0 4px 14px; }}
.cap b {{ display: block; font: 650 15px system-ui, "PingFang SC"; }}
.cap span {{ display: block; margin-top: 4px; font: 500 12px/1.4 system-ui, "PingFang SC"; color: #7a6c64; }}
.bars {{ display: grid; gap: 10px; }}
.bar {{ height: 44px; border-radius: 10px; display: flex; align-items: center; justify-content: center;
  background: rgba(255,255,255,.75); box-shadow: 0 0 0 .5px rgba(0,0,0,.12), 0 6px 16px -8px rgba(60,30,10,.3); }}
.bar.dark {{ background: #2a2a2e; }}
.bar .tray {{ transform: scale(1.35); }}
</style></head><body><h3>{t['pages_title']}</h3><div class="grid">{col_html}{last}</div></body></html>"""


# ---------------------------------------------------------------- 输出

def render(page, html: str, path: Path) -> None:
    page.set_content(html)
    page.wait_for_timeout(200)
    png = path.with_suffix(".png")
    page.screenshot(path=str(png), full_page=True)
    # PNG 约 2.7MB，README 加载太慢：转 WebP（q90，文字仍清晰），GitHub 直接显示
    subprocess.run(["cwebp", "-quiet", "-q", "90", "-m", "6", str(png), "-o", str(path)], check=True)
    png.unlink()
    print("写出", path.relative_to(ROOT))


def main() -> None:
    if "--skip-snapshot" not in sys.argv:
        snapshot()
    OUT.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": 1200, "height": 700}, device_scale_factor=2)
        for lang, t in TEXT.items():
            render(page, hero_html(t), OUT / f"hero-{lang}.webp")
            render(page, pages_html(t), OUT / f"pages-{lang}.webp")
        b.close()


if __name__ == "__main__":
    main()
