#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""统一应用图标：Android 启动器图标 + Windows 应用图标 + 应用内品牌标（蜂蜜黄圆角方块 + 白色「书 + 放大镜」R 标）。

品牌标规格（源文件 ``scripts/icon_source/icon.svg``）：

- 底色：蜂蜜黄渐变 ``#E3B45A`` → ``#BE8C2C``；adaptive 背景用 gradient drawable
- 圆角：约边长 22%（1024 → 224）
- 字形：纯白 ``#FFFFFF`` 的「书 + 放大镜」R；镜心青瓷 ``#0E7A6E`` 加载环
- 图标画布外透明

母版来源
--------
母版 PNG 由 **Chrome / Edge headless** 从源 SVG 渲染（透明底 1024）：

- ``scripts/icon_source/icon.svg``：完整图标
- ``scripts/icon_source/icon-glyph.svg``：仅字形（透明底，无阴影），供 adaptive 前景层

``--no-render`` 可复用 ``ui_audit/tmp/`` 里已有的母版，不再重新渲染。
旧的 Flutter golden 生成路径已移除；应用内品牌标改用本脚本产出的
``apps/sync_reader/assets/brand/app_icon.png``。

用法
----
```bash
# 完整流程（先渲染母版 → 再派生全部资源 → 自检）
python scripts/gen_app_icons.py

# 跳过母版渲染（复用 ui_audit/tmp/ 的母版）
python scripts/gen_app_icons.py --no-render

# 只做自检
python scripts/gen_app_icons.py --check-only
```

前置条件：Python 3 + Pillow；渲染母版还需要 Chrome 或 Edge。母版目录
``ui_audit/tmp/`` 已被 .gitignore 忽略（母版是可复现的中间产物，不入库）。

产物（入库的二进制资源）
------------------------
- ``apps/sync_reader/android/app/src/main/res/mipmap-*/ic_launcher.png``
  （legacy，48/72/96/144/192，RGBA）
- ``apps/sync_reader/android/app/src/main/res/mipmap-*/ic_launcher_foreground.png``
  （adaptive 前景，108/162/216/324/432，透明底）
- ``.../res/mipmap-anydpi-v26/ic_launcher.xml``
  + ``.../res/drawable/ic_launcher_background.xml``（蜂蜜黄渐变背景）
- ``apps/sync_reader/windows/runner/resources/app_icon.ico``（16/24/32/48/64/128/256）
- ``apps/sync_reader/assets/brand/app_icon.png``（144，应用内品牌标）
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image

# ── 路径常量 ────────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parent.parent
APP_DIR = REPO_ROOT / "apps" / "sync_reader"
ANDROID_RES = APP_DIR / "android" / "app" / "src" / "main" / "res"
WINDOWS_ICO = APP_DIR / "windows" / "runner" / "resources" / "app_icon.ico"
MASTER_DIR = REPO_ROOT / "ui_audit" / "tmp"
MASTER_PNG = MASTER_DIR / "icon-master-1024.png"
GLYPH_PNG = MASTER_DIR / "icon-glyph-1024.png"
AUDIT_DIR = REPO_ROOT / "ui_audit" / "v11"
SOURCE_SVG = REPO_ROOT / "scripts" / "icon_source" / "icon.svg"
GLYPH_SVG = REPO_ROOT / "scripts" / "icon_source" / "icon-glyph.svg"
APP_BRAND_PNG = APP_DIR / "assets" / "brand" / "app_icon.png"
APP_BRAND_SIZE = 144  # 应用内最大 36 逻辑像素；3x 屏约 108 物理像素

# ── 设计令牌（蜂蜜黄 + 白色字形）────────────────────────────────────────────
BRAND_HEX = 0xD1A043  # 色卡中间值
BRAND_RGB = (0xD1, 0xA0, 0x43)
BG_TOP_HEX = 0xE3B45A
BG_BOTTOM_HEX = 0xBE8C2C
GLYPH_RGB = (0xFF, 0xFF, 0xFF)  # 字形为纯白

MASTER_SIZE = 1024

# ── Android 尺寸表 ──────────────────────────────────────────────────────────
# legacy mipmap：图标整体（圆角方块）铺满画布
LEGACY_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# adaptive icon：前景层画布 108dp 等比，字形只占中间 66dp 安全区
ADAPTIVE_CANVAS_DP = 108
ADAPTIVE_SAFE_DP = 66
ADAPTIVE_DENSITIES = {
    "mipmap-mdpi": 1,
    "mipmap-hdpi": 1.5,
    "mipmap-xhdpi": 2,
    "mipmap-xxhdpi": 3,
    "mipmap-xxxhdpi": 4,
}

# ── Windows ICO 尺寸表 ──────────────────────────────────────────────────────
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]


# ── 工具函数 ────────────────────────────────────────────────────────────────
def resize_rgba(img: Image.Image, size: int | tuple[int, int]) -> Image.Image:
    """预乘 alpha 的 LANCZOS 缩放。

    PIL 直接对 RGBA 缩放时透明像素的 RGB（=0）会渗进边缘，形成黑边；
    先转 ``RGBa``（预乘 alpha）缩放再转回 ``RGBA`` 可消除该瑕疵。
    """
    target = (size, size) if isinstance(size, int) else size
    if img.size == target:
        return img.convert("RGBA")
    return img.convert("RGBa").resize(target, Image.LANCZOS).convert("RGBA")


def _find_browser() -> str | None:
    """定位 Chrome / Edge（PATH → 常见安装位置）。"""
    from shutil import which

    env_chrome = os.environ.get("CHROME")
    if env_chrome and Path(env_chrome).exists():
        return env_chrome
    for name in ("chrome", "chrome.exe", "google-chrome", "msedge", "msedge.exe"):
        found = which(name)
        if found:
            return found
    for candidate in (
        Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
        Path(r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"),
        Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
        Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
    ):
        if candidate.exists():
            return str(candidate)
    return None


def _render_svg(svg_path: Path, out_path: Path) -> None:
    """用 headless 浏览器把 SVG 渲染成 1024×1024 透明 PNG。"""
    browser = _find_browser()
    if browser is None:
        raise SystemExit(
            "找不到 Chrome / Edge；请把浏览器加入 PATH，或设置 CHROME 环境变量后重试。"
        )
    MASTER_DIR.mkdir(parents=True, exist_ok=True)
    svg = svg_path.read_text(encoding="utf-8")
    wrapper = MASTER_DIR / f"_wrap_{out_path.stem}.html"
    wrapper.write_text(
        '<!doctype html><html><head><meta charset="utf-8"><style>'
        "html,body{margin:0;padding:0;background:transparent;overflow:hidden}"
        f"svg{{display:block;width:{MASTER_SIZE}px;height:{MASTER_SIZE}px}}"
        "</style></head><body>" + svg + "</body></html>",
        encoding="utf-8",
    )
    out = out_path.resolve()
    url = "file:///" + wrapper.resolve().as_posix()
    result = subprocess.run(
        [
            browser,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            "--default-background-color=00000000",
            f"--window-size={MASTER_SIZE},{MASTER_SIZE}",
            f"--screenshot={out.as_posix()}",
            url,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    wrapper.unlink(missing_ok=True)
    if result.returncode != 0 or not out.exists():
        raise SystemExit(
            f"母版渲染失败：{svg_path.name}\n{result.stderr.strip()}"
        )
    print(f"[ok  ] 母版 → {out.relative_to(REPO_ROOT)}")


def render_master() -> None:
    """从源 SVG 渲染完整母版与字形母版。"""
    _render_svg(SOURCE_SVG, MASTER_PNG)
    _render_svg(GLYPH_SVG, GLYPH_PNG)


# ── Android 资源生成 ────────────────────────────────────────────────────────
def write_android_legacy(master: Image.Image) -> list[Path]:
    """legacy mipmap PNG（图标铺满画布，四角透明）。"""
    written: list[Path] = []
    for folder, size in LEGACY_SIZES.items():
        target = ANDROID_RES / folder / "ic_launcher.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        resize_rgba(master, size).save(target, format="PNG", optimize=True)
        written.append(target)
        print(f"[ok  ] {target.relative_to(REPO_ROOT)}  ({size}×{size}, RGBA)")
    return written


def _ink_bbox(img: Image.Image) -> tuple[int, int, int, int]:
    """返回非透明像素的包围盒 (left, top, right, bottom)。"""
    alpha = img.getchannel("A")
    bbox = alpha.point(lambda a: 255 if a > 8 else 0).getbbox()
    if bbox is None:
        raise AssertionError("字形母版没有任何可见像素。")
    return bbox


def write_android_adaptive(glyph: Image.Image) -> list[Path]:
    """adaptive icon 前景层 PNG：字形落在 108dp 画布的中间 66dp 安全区内。

    前景层只含**白色字形**（透明底，无阴影），蜂蜜黄渐变背景由
    ``@drawable/ic_launcher_background`` 提供——两者在启动器遮罩下合成。

    字形尺寸：把字形母版里字形的**墨迹包围盒**等比缩放，使其**对角线**等于
    66dp 安全区的直径，再居中放到 108dp 画布。Android 保证 108dp 画布正中央
    的 66dp 直径圆内内容不被任何遮罩（圆形/方形/水滴）裁切，按对角线取值可
    保证字形任何角落都不被切到，四周留白。
    """
    written: list[Path] = []
    left, top, right, bottom = _ink_bbox(glyph)
    ink_w, ink_h = right - left, bottom - top
    ink = glyph.crop((left, top, right, bottom))
    for folder, density in ADAPTIVE_DENSITIES.items():
        canvas = int(round(ADAPTIVE_CANVAS_DP * density))
        safe = int(round(ADAPTIVE_SAFE_DP * density))
        # 等比缩放：墨迹对角线 = 安全区直径。
        scale = safe / ((ink_w**2 + ink_h**2) ** 0.5)
        new_w = max(1, round(ink_w * scale))
        new_h = max(1, round(ink_h * scale))
        scaled = resize_rgba(ink, (new_w, new_h))
        frame = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        frame.alpha_composite(scaled, ((canvas - new_w) // 2, (canvas - new_h) // 2))
        target = ANDROID_RES / folder / "ic_launcher_foreground.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        frame.save(target, format="PNG", optimize=True)
        written.append(target)
        print(
            f"[ok  ] {target.relative_to(REPO_ROOT)}  "
            f"({canvas}×{canvas} 画布, 字形 {new_w}×{new_h} 落在 {safe}dp 安全区)"
        )
    return written


def write_android_adaptive_xml() -> list[Path]:
    """adaptive icon 声明 + 蜂蜜黄渐变背景（不写独立颜色资源）。"""
    drawable = ANDROID_RES / "drawable" / "ic_launcher_background.xml"
    drawable.parent.mkdir(parents=True, exist_ok=True)
    drawable.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">\n'
        f'    <gradient android:startColor="#{BG_TOP_HEX:06X}" '
        f'android:endColor="#{BG_BOTTOM_HEX:06X}" android:angle="270" />\n'
        "</shape>\n",
        encoding="utf-8",
    )

    anydpi = ANDROID_RES / "mipmap-anydpi-v26" / "ic_launcher.xml"
    anydpi.parent.mkdir(parents=True, exist_ok=True)
    anydpi.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@drawable/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )

    print(f"[ok  ] {drawable.relative_to(REPO_ROOT)}")
    print(f"[ok  ] {anydpi.relative_to(REPO_ROOT)}")
    return [drawable, anydpi]


def write_windows_ico(master: Image.Image) -> Path:
    """Windows 多尺寸 ICO（PNG 压缩帧，Windows Vista+ 原生支持 alpha）。

    注意：PIL 的 ICO 写出器要求「基准图」本身就是最大尺寸那一帧，其余尺寸
    通过 ``append_images`` 传入且必须**尺寸精确匹配**（否则会被 thumbnail
    兜底逻辑改写，导致 256 帧丢失）。
    """
    WINDOWS_ICO.parent.mkdir(parents=True, exist_ok=True)
    frames = [resize_rgba(master, size) for size in ICO_SIZES]
    frames[-1].save(
        WINDOWS_ICO,
        format="ICO",
        sizes=[(size, size) for size in ICO_SIZES],
        append_images=frames[:-1],
    )
    print(f"[ok  ] {WINDOWS_ICO.relative_to(REPO_ROOT)}  (多尺寸 {ICO_SIZES})")
    return WINDOWS_ICO


def write_app_brand_asset(master: Image.Image) -> Path:
    """应用内品牌标：144×144 RGBA（圆角方块 + 完整字形）。

    尺寸说明：品牌标在应用内只显示 30×30（首启页）与 36×36（侧栏）逻辑像素，
    3x 屏上约 108 物理像素——144 已留足余量。512 版本要多背 80KB 进包，
    对 30px 的显示毫无收益。
    """
    APP_BRAND_PNG.parent.mkdir(parents=True, exist_ok=True)
    resize_rgba(master, APP_BRAND_SIZE).save(APP_BRAND_PNG, format="PNG", optimize=True)
    print(
        f"[ok  ] {APP_BRAND_PNG.relative_to(REPO_ROOT)}  "
        f"({APP_BRAND_SIZE}×{APP_BRAND_SIZE}, RGBA)"
    )
    return APP_BRAND_PNG


# ── 自检 ────────────────────────────────────────────────────────────────────
def _check_png(path: Path, expect_size: int) -> None:
    """完整图标 PNG 自检：尺寸 / alpha / 四角透明 / 蜂蜜黄底 / 白色字形占比。"""
    raw = Image.open(path)
    if raw.mode != "RGBA":
        raise AssertionError(f"{path.name}: 缺少 alpha 通道（mode={raw.mode}）")
    img = raw.convert("RGBA")
    if img.size != (expect_size, expect_size):
        raise AssertionError(
            f"{path.name}: 尺寸 {img.size} != ({expect_size}, {expect_size})"
        )

    w, h = img.size
    px = img.load()
    for corner in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if px[corner][3] != 0:
            raise AssertionError(f"{path.name}: 角 {corner} 未透明 alpha={px[corner][3]}")

    # 顶部中心应是蜂蜜黄背景（渐变浅端附近）
    r, g, b, a = px[w // 2, h // 8]
    if a < 200 or r < 205 or g < 160 or b > 115:
        raise AssertionError(
            f"{path.name}: 顶部中心 {px[w // 2, h // 8]} 不像蜂蜜黄背景"
        )

    # 中心应不透明（镜心/背景）
    if px[w // 2, h // 2][3] < 200:
        raise AssertionError(f"{path.name}: 中心像素透明")

    # 白色字形占比（每 2px 采样）
    glyph = 0
    samples = 0
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            samples += 1
            pr, pg, pb, pa = px[x, y]
            if pa > 200 and pr > 238 and pg > 238 and pb > 232:
                glyph += 1
    ratio = glyph / max(1, samples)
    if ratio <= 0.03:
        raise AssertionError(f"{path.name}: 白色字形占比 {ratio:.3%} 过低")
    print(
        f"[chk ] {path.name}: {w}×{h}, RGBA, 四角透明, 蜂蜜黄底, "
        f"白色字形 {ratio:.2%}"
    )


def _check_foreground(path: Path, expect_size: int) -> None:
    """adaptive 前景层自检：RGBA / 四角透明 / 字形居中且落在 66dp 安全区。"""
    raw = Image.open(path)
    if raw.mode != "RGBA":
        raise AssertionError(f"{path.name}: 缺少 alpha 通道（mode={raw.mode}）")
    img = raw.convert("RGBA")
    w, h = img.size
    if img.size != (expect_size, expect_size):
        raise AssertionError(
            f"{path.name}: 尺寸 {img.size} != ({expect_size}, {expect_size})"
        )
    px = img.load()
    for corner in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if px[corner][3] != 0:
            raise AssertionError(f"{path.name}: 角 {corner} 未透明 alpha={px[corner][3]}")

    bbox = _ink_bbox(img)
    left, top, right, bottom = bbox
    if right - left < 4 or bottom - top < 4:
        raise AssertionError(f"{path.name}: 字形过小 {bbox}")
    cx = (left + right) / 2
    cy = (top + bottom) / 2
    if abs(cx - w / 2) > 2 or abs(cy - h / 2) > 2:
        raise AssertionError(f"{path.name}: 字形未居中（中心 {cx:.1f},{cy:.1f}）")

    safe = ADAPTIVE_SAFE_DP / ADAPTIVE_CANVAS_DP
    margin = safe * w / 2
    if left < w / 2 - margin - 1 or right > w / 2 + margin + 1:
        raise AssertionError(f"{path.name}: 字形超出安全区（{bbox}）")
    if top < h / 2 - margin - 1 or bottom > h / 2 + margin + 1:
        raise AssertionError(f"{path.name}: 字形超出安全区（{bbox}）")

    opaque = sum(
        1
        for y in range(0, h, 2)
        for x in range(0, w, 2)
        if px[x, y][3] > 200
    )
    total = len(range(0, w, 2)) * len(range(0, h, 2))
    ratio = opaque / max(1, total)
    if ratio <= 0.02:
        raise AssertionError(f"{path.name}: 前景覆盖 {ratio:.3%} 过低")
    print(
        f"[chk ] {path.name}: {w}×{h}, RGBA, 四角透明, 字形居中 "
        f"{right - left}×{bottom - top}（安全区内）, 覆盖 {ratio:.2%}"
    )


def _check_ico(path: Path) -> None:
    with Image.open(path) as ico:
        sizes = sorted(ico.ico.sizes())
        print(f"[chk ] {path.name}: 内含尺寸 {sizes}")
        for want in ICO_SIZES:
            if (want, want) not in sizes:
                raise AssertionError(f"{path.name}: 缺 {want}×{want} 帧")
        big = ico.ico.getimage((256, 256)).convert("RGBA")
    px = big.load()
    w, h = big.size
    for corner in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if px[corner][3] != 0:
            raise AssertionError(f"{path.name}: 256 帧角 {corner} 未透明")
    opaque = sum(
        1
        for y in range(0, h, 2)
        for x in range(0, w, 2)
        if px[x, y][3] > 200
    )
    total = len(range(0, w, 2)) * len(range(0, h, 2))
    ratio = opaque / max(1, total)
    if ratio <= 0.2:
        raise AssertionError(f"{path.name}: 不透明覆盖 {ratio:.3%} 过低")
    print(f"[chk ] {path.name}: 256 帧四角透明, 覆盖 {ratio:.2%}")


def check_all() -> None:
    """对已入库的资源做自检（尺寸 / alpha / 四角透明 / 颜色 / 字形占比）。"""
    print("── 自检 ──")
    _check_png(ANDROID_RES / "mipmap-xxxhdpi" / "ic_launcher.png", 192)
    _check_png(ANDROID_RES / "mipmap-mdpi" / "ic_launcher.png", 48)
    _check_png(APP_BRAND_PNG, APP_BRAND_SIZE)
    _check_foreground(ANDROID_RES / "mipmap-xxxhdpi" / "ic_launcher_foreground.png", 432)
    _check_foreground(ANDROID_RES / "mipmap-mdpi" / "ic_launcher_foreground.png", 108)
    _check_ico(WINDOWS_ICO)


def export_audit_copies() -> None:
    """把母版与派生结果复制到 ui_audit/v11/，供目视核对（该目录不入库）。"""
    AUDIT_DIR.mkdir(parents=True, exist_ok=True)
    copies = [
        (MASTER_PNG, AUDIT_DIR / "icon-master-1024.png"),
        (ANDROID_RES / "mipmap-xxxhdpi" / "ic_launcher.png", AUDIT_DIR / "icon-android-192.png"),
        (WINDOWS_ICO, AUDIT_DIR / "icon-windows-256.png"),
        (APP_BRAND_PNG, AUDIT_DIR / "icon-app-brand.png"),
    ]
    for src, dst in copies:
        if src.suffix.lower() == ".ico":
            with Image.open(src) as ico:
                ico.ico.getimage((256, 256)).convert("RGBA").save(dst)
        else:
            Image.open(src).convert("RGBA").save(dst)
        print(f"[copy] {dst.relative_to(REPO_ROOT)}")


# ── 入口 ────────────────────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser(description="生成统一的应用图标资源")
    parser.add_argument(
        "--no-render", action="store_true", help="跳过 SVG 母版渲染（复用已有母版）"
    )
    parser.add_argument(
        "--check-only", action="store_true", help="只做自检，不重新生成资源"
    )
    args = parser.parse_args()

    if args.check_only:
        check_all()
        return 0

    if not args.no_render:
        render_master()
    if not MASTER_PNG.exists() or not GLYPH_PNG.exists():
        raise SystemExit(f"缺少母版：{MASTER_PNG} / {GLYPH_PNG}")

    master = Image.open(MASTER_PNG).convert("RGBA")
    glyph = Image.open(GLYPH_PNG).convert("RGBA")
    print(f"母版 {master.size}（完整）/ {glyph.size}（字形）")

    write_android_legacy(master)
    write_android_adaptive(glyph)
    write_android_adaptive_xml()
    write_windows_ico(master)
    write_app_brand_asset(master)

    check_all()
    export_audit_copies()
    print("── 完成 ──")
    return 0


if __name__ == "__main__":
    sys.exit(main())
