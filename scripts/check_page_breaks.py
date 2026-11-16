"""epub page 模式页界切字量化检查（真机截图）。

判据（正文区墨迹行聚类）：
- 取正文列（排除左右页边距）的墨迹行（每行一个 y 区间）；
- 计算各行高度的中位数 m；
- 页尾最后一行高度 h：若 h < 0.6*m 且该行紧贴正文区底部 → 判定「被页界切半」；
- 同时报告页首第一行是否完整（h >= 0.6*m）。

用法：python ui_audit/cmp_v13/check_page_breaks.py <png...>
"""

import sys
from PIL import Image


def ink_rows(path, col_lo=0.30, col_hi=0.72, thresh=200):
    im = Image.open(path).convert("L")
    w, h = im.size
    x0, x1 = int(w * col_lo), int(w * col_hi)
    px = im.load()
    rows = []
    for y in range(h):
        dark = 0
        for x in range(x0, x1, 2):
            if px[x, y] < thresh:
                dark += 1
        rows.append(dark)
    # 行聚类：连续有墨迹的 y 段
    groups = []
    start = None
    gap = 0
    for y, d in enumerate(rows):
        if d > 0:
            if start is None:
                start = y
            gap = 0
        else:
            if start is not None:
                gap += 1
                if gap >= 3:  # 允许行内 2px 断裂（标点/字内空隙）
                    groups.append((start, y - gap))
                    start = None
                    gap = 0
    if start is not None:
        groups.append((start, h - 1))
    return groups, h


def main(paths):
    bad = 0
    for p in paths:
        groups, h = ink_rows(p)
        if not groups:
            print(f"{p}: 无正文墨迹")
            continue
        # 过滤极扁的墨迹行（epub 原文的分隔线 <hr>：1–2px），它们不是文字行，
        # 参与中位/首尾判定会把「标题完整」误判为「被切半」。
        text_groups = [(t, b) for t, b in groups if (b - t + 1) >= 4]
        if not text_groups:
            text_groups = groups
        heights = [b - t + 1 for t, b in text_groups]
        heights_sorted = sorted(heights)
        mid = heights_sorted[len(heights_sorted) // 2]
        first_h = heights[0]
        last_h = heights[-1]
        last_gap_to_bottom = h - 1 - text_groups[-1][1]
        # 页尾行：若明显矮于中位行高且贴近底部 → 疑似被切半
        cut_last = last_h < 0.6 * mid and last_gap_to_bottom < 40
        # 页首行：明显矮于中位行高 → 疑似被切半
        cut_first = first_h < 0.6 * mid
        flag = "CUT" if (cut_last or cut_first) else "ok"
        if cut_last or cut_first:
            bad += 1
        print(
            f"{p}: {flag} 行数={len(groups)} 中位行高={mid} "
            f"页首行高={first_h} 页尾行高={last_h} 页尾距底={last_gap_to_bottom}"
        )
    print(f"\n疑似切字页：{bad}/{len(paths)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
