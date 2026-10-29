#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""统一应用图标：Android 启动器图标 + Windows 应用图标（赭石圆角方块 + 白色打开的书）。

产品品牌标规格（与 `apps/sync_reader/lib/core/design_tokens.dart` 的
`AppAccent.terracotta.brand` 严格一致）：

- 底色：``#B25430``（赭石）
- 圆角：约为边长的 22%（1024 → 224）
- 书本：Material Icons 的 ``Icons.auto_stories``，纯白 ``#FFFFFF``，
  约占边长 46%（1024 → 470），居中
- 图标画布外为透明（不要白底方块）

母版来源
--------
母版 PNG **不是手绘近似**，而是用 Flutter 渲染出来的（保证书本字形与 App 内
品牌标完全一致）：

1. ``apps/sync_reader/test/screenshot/icon_master_test.dart``（受环境变量
   ``SYNC_ICON_GEN=1`` 门控，常规 ``flutter test`` 里是 skip 用例）用
   ``matchesGoldenFile`` 渲染两张 1024×1024 母版到仓库根 ``ui_audit/tmp/``：

   - ``icon-master-1024.png``：完整图标（赭石圆角方块 + 白色书本）
   - ``icon-glyph-1024.png``：仅白色书本（透明底），供 adaptive icon 前景层用

2. 本脚本用 PIL 从母版派生全部尺寸（LANCZOS + 预乘 alpha，避免边缘黑边）。

用法
----
```bash
# 完整流程（先渲染母版 → 再派生全部资源 → 自检）
python scripts/gen_app_icons.py

# 跳过母版渲染（复用已有的 ui_audit/tmp/icon-master-1024.png）
python scripts/gen_app_icons.py --no-render

# 只做自检
python scripts/gen_app_icons.py --check-only
```

前置条件：Python 3 + Pillow；渲染母版还需要 Flutter SDK（在 PATH 中，或用
``FLUTTER_ROOT`` 环境变量指定）。母版目录 ``ui_audit/tmp/`` 已被 .gitignore
忽略（母版是可复现的中间产物，不入库）。

产物（入库的二进制资源）
------------------------
- ``apps/sync_reader/android/app/src/main/res/mipmap-*/ic_launcher.png``
  （legacy，48/72/96/144/192，RGBA）
- ``apps/sync_reader/android/app/src/main/res/mipmap-*/ic_launcher_foreground.png``
  （adaptive 前景，108/162/216/324/432，透明底）
- ``apps/sync_reader/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml``
  + ``.../res/values/ic_launcher_background.xml``（adaptive icon 声明）
- ``apps/sync_reader/windows/runner/resources/app_icon.ico``（16/24/32/48/64/128/256）
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

# ── 设计令牌（与 design_tokens.dart 一致）────────────────────────────────────
BRAND_HEX = 0xB25430  # AppAccent.terracotta 的 brand（浅色主题）
BRAND_RGB = (0xB2, 0x54, 0x30)

MASTER_SIZE = 1024
CORNER_RATIO = 0.22  # 圆角 ≈ 边长 22%
GLYPH_RATIO = 0.46  # 书本 ≈ 边长 46%

# ── Android 尺寸表 ──────────────────────────────────────────────────────────
# legacy mipmap：图标整体（圆角方块）铺满画布
LEGACY_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# adaptive icon：前景层画布 108dp 等比，书本只占中间 66dp 安全区
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


def render_master() -> None:
    """调用 Flutter 金测渲染母版 PNG（幂等：母版已存在则跳过）。"""
    if MASTER_PNG.exists() and GLYPH_PNG.exists():
        print(f"[skip] 母版已存在 → {MASTER_PNG.relative_to(REPO_ROOT)}")
        return

    flutter = _find_flutter()
    if flutter is None:
        raise SystemExit(
            "找不到 flutter 可执行文件；请把 Flutter SDK 加入 PATH，"
            "或设置 FLUTTER_ROOT 环境变量后重试。"
        )

    env = dict(os.environ)
    env["SYNC_ICON_GEN"] = "1"
    cmd = (
        f'"{flutter}" test --update-goldens '
        "test/screenshot/icon_master_test.dart"
    )
    print(f"[run ] {cmd}  (cwd={APP_DIR})")
    result = subprocess.run(
        cmd,
        cwd=str(APP_DIR),
        env=env,
        shell=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit("母版渲染失败（flutter test 非零退出）。")
    if not MASTER_PNG.exists() or not GLYPH_PNG.exists():
        raise SystemExit("母版渲染后仍缺少母版 PNG。")
    print(f"[ok  ] 母版已生成 → {MASTER_PNG.relative_to(REPO_ROOT)}")


def _find_flutter() -> str | None:
    """定位 flutter 可执行文件（PATH → FLUTTER_ROOT → 本机固定路径）。"""
    from shutil import which

    for name in ("flutter", "flutter.bat"):
        found = which(name)
        if found:
            return found
    root = os.environ.get("FLUTTER_ROOT")
    if root:
        candidate = Path(root) / "bin" / "flutter.bat"
        if candidate.exists():
            return str(candidate)
        candidate = Path(root) / "bin" / "flutter"
        if candidate.exists():
            return str(candidate)
    fallback = Path("D:/softwares/node_env/flutter/bin/flutter.bat")
    if fallback.exists():
        return str(fallback)
    return None


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
    """adaptive icon 前景层 PNG：书本落在 108dp 画布的中间 66dp 安全区内。

    前景层只含**白色书本**（透明底），赭石底色由 ``@color/ic_launcher_background``
    背景层提供——两者在启动器遮罩下合成出与 legacy 图标一致的观感。

    书本尺寸：把字形母版里书本的**墨迹包围盒**等比缩放，使其**对角线**等于
    66dp 安全区的直径，再居中放到 108dp 画布。Android 保证 108dp 画布正中央
    的 66dp 直径圆内内容不被任何遮罩（圆形/方形/水滴）裁切，按对角线取值可
    保证书本任何角落都不被切到，四周留白。
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
            f"({canvas}×{canvas} 画布, 书本 {new_w}×{new_h} 落在 {safe}dp 安全区)"
        )
    return written


def write_android_adaptive_xml() -> list[Path]:
    """adaptive icon 声明 + 背景色资源。"""
    anydpi = ANDROID_RES / "mipmap-anydpi-v26" / "ic_launcher.xml"
    anydpi.parent.mkdir(parents=True, exist_ok=True)
    anydpi.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '</adaptive-icon>\n',
        encoding="utf-8",
    )
    values = ANDROID_RES / "values" / "ic_launcher_background.xml"
    values.parent.mkdir(parents=True, exist_ok=True)
    values.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        f'    <color name="ic_launcher_background">#{BRAND_HEX:06X}</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )
    print(f"[ok  ] {anydpi.relative_to(REPO_ROOT)}")
    print(f"[ok  ] {values.relative_to(REPO_ROOT)}")
    return [anydpi, values]


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


# ── 自检 ────────────────────────────────────────────────────────────────────
def _check_png(path: Path, expect_size: int, min_white_ratio: float = 0.08) -> None:
    """完整图标 PNG 自检：尺寸 / alpha / 四角透明 / 中心赭石 / 白色字形占比。"""
    raw = Image.open(path)
    if raw.mode != "RGBA":
        raise AssertionError(f"{path.name}: 缺少 alpha 通道（mode={raw.mode}）")
    img = raw.convert("RGBA")
    if img.size != (expect_size, expect_size):
        raise AssertionError(f"{path.name}: 尺寸 {img.size} != ({expect_size}, {expect_size})")

    w, h = img.size
    px = img.load()
    for corner in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if px[corner][3] != 0:
            raise AssertionError(f"{path.name}: 角 {corner} 未透明 alpha={px[corner][3]}")

    # 中心像素应为赭石色附近（书本字形有中缝，中心落在底色上）
    r, g, b, a = px[w // 2, h // 2]
    if a < 200:
        raise AssertionError(f"{path.name}: 中心像素未不透明 alpha={a}")
    if abs(r - BRAND_RGB[0]) > 26 or abs(g - BRAND_RGB[1]) > 26 or abs(b - BRAND_RGB[2]) > 26:
        raise AssertionError(f"{path.name}: 中心像素 {px[w // 2, h // 2]} 偏离赭石色")

    # 白色字形占比
    white = 0
    total = 0
    for y in range(h):
        for x in range(w):
            total += 1
            pr, pg, pb, pa = px[x, y]
            if pa > 200 and pr > 230 and pg > 230 and pb > 230:
                white += 1
    ratio = white / total
    if ratio <= min_white_ratio:
        raise AssertionError(f"{path.name}: 白色字形占比 {ratio:.3%} <= {min_white_ratio:.0%}")
    print(f"[chk ] {path.name}: {w}×{h}, RGBA, 四角透明, 中心赭石, 白色占比 {ratio:.2%}")


def _check_foreground(path: Path, expect_size: int) -> None:
    """adaptive 前景层自检：RGBA / 四角透明 / 字形居中且落在 66dp 安全区内。"""
    raw = Image.open(path)
    if raw.mode != "RGBA":
        raise AssertionError(f"{path.name}: 缺少 alpha 通道（mode={raw.mode}）")
    img = raw.convert("RGBA")
    w, h = img.size
    if img.size != (expect_size, expect_size):
        raise AssertionError(f"{path.name}: 尺寸 {img.size} != ({expect_size}, {expect_size})")
    px = img.load()
    for corner in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if px[corner][3] != 0:
            raise AssertionError(f"{path.name}: 角 {corner} 未透明 alpha={px[corner][3]}")

    bbox = _ink_bbox(img)
    left, top, right, bottom = bbox
    if right - left < 4 or bottom - top < 4:
        raise AssertionError(f"{path.name}: 墨迹过小 {bbox}")
    # 居中：墨迹中心与画布中心的偏差不超过 2px
    cx = (left + right) / 2
    cy = (top + bottom) / 2
    if abs(cx - w / 2) > 2 or abs(cy - h / 2) > 2:
        raise AssertionError(f"{path.name}: 墨迹未居中（中心 {cx:.1f},{cy:.1f}）")

    # 安全区：墨迹包围盒必须落在中央 66/108 区域内
    safe = ADAPTIVE_SAFE_DP / ADAPTIVE_CANVAS_DP
    margin_x = safe * w / 2
    margin_y = safe * h / 2
    if left < w / 2 - margin_x - 1 or right > w / 2 + margin_x + 1:
        raise AssertionError(f"{path.name}: 墨迹超出安全区（{bbox}）")

    white = sum(
        1
        for y in range(h)
        for x in range(w)
        if px[x, y][3] > 200 and min(px[x, y][:3]) > 230
    )
    if white == 0:
        raise AssertionError(f"{path.name}: 没有白色字形")
    print(
        f"[chk ] {path.name}: {w}×{h}, RGBA, 四角透明, 墨迹居中 "
        f"{right - left}×{bottom - top}（安全区内）, 白色像素 {white}"
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
    white = sum(
        1
        for y in range(0, h, 2)
        for x in range(0, w, 2)
        if px[x, y][3] > 200 and min(px[x, y][:3]) > 230
    )
    ratio = white / ((w // 2) * (h // 2))
    if ratio <= 0.08:
        raise AssertionError(f"{path.name}: 白色字形占比 {ratio:.3%} 过低")
    print(f"[chk ] {path.name}: 256 帧四角透明, 白色占比 {ratio:.2%}")


def check_all() -> None:
    """对已入库的资源做自检（尺寸 / alpha / 四角透明 / 颜色 / 白色占比）。"""
    print("── 自检 ──")
    _check_png(ANDROID_RES / "mipmap-xxxhdpi" / "ic_launcher.png", 192)
    _check_png(ANDROID_RES / "mipmap-mdpi" / "ic_launcher.png", 48)
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
        "--no-render", action="store_true", help="跳过 Flutter 母版渲染（复用已有母版）"
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

    check_all()
    export_audit_copies()
    print("── 完成 ──")
    return 0


if __name__ == "__main__":
    sys.exit(main())
