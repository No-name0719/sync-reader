/// epub page 模式的**页停候选与页结构**（纯 Dart，无 Flutter 依赖）。
///
/// 背景：epub 的 page 模式是「连续排版 + 吸附翻页」——正文始终是一整条连续
/// 内容流，页界靠「停在某个位置」来切。页界必须满足两条硬约束：
///
/// 1. **页界落在行与行之间**（否则行被拦腰切断：章题只显示上半截、页尾只
///    显示半行）。行边界由渲染树实测得到（见 epub_line_meter.dart）。
/// 2. **图片块是原子**：页界不得落在图片内部，且**图片独占一页**（插图不能
///    与上下文字挤在一页，也不能被切成两半、在两页各露一半）。
///
/// 术语：
/// - **页停候选**（[EpubStop]）：可停靠的位置。
///   - 文本行 = 行盒顶的「安全落点」（行盒顶上移 0.28em，中日韩字面高出
///     ascent 带时不削顶）；
///   - 图片块 = 块顶，并携带块底（[EpubStop.imageBottom]）——块顶..块底是
///     不可切分的原子区间。
/// - **页起点**：每页的起点（= 上一页的终点）。翻页 = 跳到相邻页起点。
///
/// 页结构规则（前后翻页共用，保证往返一致）：
/// - 文本页：页终点 = 一屏之内**最靠下**的行边界候选（页尾留白不足一行）；
/// - 图片页：**图片独占一页**——一屏之内出现图片块顶时，该页终点 = 图片块顶
///   （图片另起一页）；若本页从图片块顶起，则本页终点 = 图片块底（页界不入
///   图片内部）；
/// - **章边界**（[EpubPageStructure.chapterStarts]）：**新章节另起一页**——
///   页终点最多到下一章节起点，章节起点本身即页起点（章题不被挤在上一页
///   尾部，章首也不与上一章正文同页）；
/// - **页起点链**（[EpubPageStructure.chain]）：走过的页起点按序记录（升序），
///   前后翻页据此**精确往返**（下一页 → 上一页 回到原落点），而不是每次重新
///   猜一个近似位置。链在**跳转**（位置语义断裂）时整体作废，见
///   [invalidateChain]。
///
/// 候选表的**代次**（epoch）：候选与已测内容绑定——排版几何一变（字号/行高/
/// 页边距/字体/翻页模式）就整体作废，避免「新旧两套坐标」混在一张表里把
/// 页界算到旧位置（只增不删的代次号由渲染器提供，见 [setStops]）。
library;

/// 页停候选（文档坐标 = 视口顶在整书内容中的 y，即滚动偏移坐标系）。
class EpubStop {
  const EpubStop.text(this.pos) : imageBottom = null;

  /// 图片块候选：块顶 [pos]，块底 [bottom]（二者之间为原子区间）。
  const EpubStop.image(this.pos, double bottom) : imageBottom = bottom;

  /// 落点（文本行安全落点 / 图片块顶）。
  final double pos;

  /// 图片块底（非空 = 图片候选；[pos]..imageBottom 为原子区间）。
  final double? imageBottom;

  /// 是否为图片候选。
  bool get isImage => imageBottom != null;

  @override
  String toString() =>
      'EpubStop(${pos.toStringAsFixed(1)}'
      '${isImage ? ', 图片→${imageBottom!.toStringAsFixed(1)}' : ''})';
}

/// epub page 模式的页结构：候选表（累积） + 页起点链（走过的页起点）。
///
/// 用法：
/// - 滚动/布局变化后 [merge] 新测得的候选；
/// - 翻页用 [nextPageStart] / [prevPageStart]（会记录页起点链）；
/// - 弹道吸附用 [nearestPageStart]（就近的页起点）。
class EpubPageStructure {
  EpubPageStructure({required this.viewport});

  /// 视口高（逻辑像素）：一页的最大内容高度。
  double viewport;

  /// 位置比较容差（逻辑像素）。
  static const double epsilon = 0.5;

  /// 候选表（升序；**当前测量**的结果，整表替换）。
  ///
  /// 刻意不跨滚动累积：块的排版会随上方内容落定而微移（fwfh 的列表/引用
  /// 高度会补齐），累积起来的旧坐标会与新坐标打架（同一张插图在表里出现
  /// 两个块顶，页界就会算错）。整表替换保证「同一时刻测得的一组坐标」自洽
  /// ——页起点链（[chain]）另行记住走过的页起点，负责前后精确往返。
  final List<EpubStop> _stops = [];

  /// **安全边界**（升序）：可安全裁剪的位置——行落点、插图块顶/底、无行盒
  /// 块的块底。裁剪高度只能落在这些位置上（落在中间 = 把字拦腰切断）。
  final List<double> _safe = [];

  /// 已测内容的下边界（最后一块的底）：文档末尾时用它收尾（内容整段露出）。
  double? _contentEnd;

  /// 候选代次（epoch）：与排版代次绑定，几何一变即整体作废。
  int _epoch = 0;

  /// 页起点链（升序）：走过的页起点。
  final List<double> _chain = [];

  /// 章节起点（升序，文档坐标）：**新章节另起一页**的边界。
  ///
  /// 章起点 = 新章首块的块顶（渲染器实测提供）。页终点不得越过它，且它本身
  /// 就是合法页起点。未知（未测到）的章不在表内——页界只受**已测到**的
  /// 章边界约束（一屏之内的章边界必然被测到：page 模式多预建一屏）。
  final List<double> _chapterStarts = [];

  /// 候选数量（诊断/测试用）。
  int get stopCount => _stops.length;

  /// 候选表（升序；诊断/测试用）。
  List<EpubStop> get stops => List<EpubStop>.unmodifiable(_stops);

  /// 安全边界（升序；诊断/测试用）。
  List<double> get safeBounds => List<double>.unmodifiable(_safe);

  /// 已测内容的下边界（诊断/测试用）。
  double? get contentEnd => _contentEnd;

  /// 候选代次（诊断/测试用）：几何变化后自增。
  int get epoch => _epoch;

  /// 页起点链（升序；诊断/测试用）。
  List<double> get chain => List<double>.unmodifiable(_chain);

  /// 章节起点（升序；诊断/测试用）。
  List<double> get chapterStarts => List<double>.unmodifiable(_chapterStarts);

  /// 清空（排版几何变化 → 行盒全变 → 候选与链一并作废）。
  void clear() {
    _stops.clear();
    _safe.clear();
    _contentEnd = null;
    _chain.clear();
    _chapterStarts.clear();
  }

  /// 整表替换候选（一次测量的结果；升序）。
  ///
  /// [epoch]：排版代次。代次变了 → 旧候选与旧页起点链一并作废（几何变了，
  /// 旧坐标对应旧排版，留着会把页界算到错误位置）。
  ///
  /// [safeBounds]：本次测得的安全边界（行落点/块底等），供**保守裁剪**使用。
  ///
  /// [contentEnd]：本次测得的内容下边界（文档末尾收尾用）。
  ///
  /// [chapterStarts]：本次测得的章节起点（新章另起一页的边界；升序）。
  void setStops(
    List<EpubStop> measured, {
    int? epoch,
    List<double> safeBounds = const [],
    double? contentEnd,
    List<double> chapterStarts = const [],
  }) {
    if (epoch != null && epoch != _epoch) {
      // 代次变了：旧候选与旧链整体作废（几何已变，旧坐标不再成立）。
      _stops.clear();
      _chain.clear();
      _chapterStarts.clear();
      _epoch = epoch;
    }
    _stops
      ..clear()
      ..addAll(measured);
    _safe
      ..clear()
      ..addAll(safeBounds)
      ..sort();
    _contentEnd = contentEnd;
    _chapterStarts
      ..clear()
      ..addAll(chapterStarts)
      ..sort();
  }

  /// **作废页起点链**（跳转 = 位置语义断裂）。
  ///
  /// 目录/进度跳转后，新位置与旧位置的页起点**不再相邻**（中间隔着整段
  /// 未走过的内容）。若留着旧链：
  /// - 弹道吸附（[nearestPageStart]）会把页面**吸回旧位置**（跳转后弹回、
  ///   来回翻页）；
  /// - 翻页会沿旧链走到旧区域（下一页跳回上一章）。
  ///
  /// 故跳转时清链，并把跳转落点另行登记为新页起点（[registerPageStart]）。
  void invalidateChain() {
    _chain.clear();
  }

  /// 登记一个页起点（跳转落点）：并入页起点链，作为往返的锚。
  void registerPageStart(double pos) {
    _chainAdd(pos);
  }

  /// 区间 (from, to] 内的**最大安全边界**（保守裁剪用；无则 null）。
  ///
  /// 裁剪高度未知时用它收尾：宁可页尾多留白（裁得更早），也不能让页界落在
  /// 行中间（切字）。
  double? largestSafeWithin(double from, double to) {
    if (_safe.isEmpty || to <= from) return null;
    var low = 0;
    var high = _safe.length - 1;
    var best = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final pos = _safe[mid];
      if (pos <= from + epsilon) {
        low = mid + 1;
      } else if (pos <= to + epsilon) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return best >= 0 ? _safe[best] : null;
  }

  /// 起点 [start] 处的**一页内容高度**（页终点 - 起点；≤ 一屏）。
  ///
  /// **保守兜底**（主视口与推入页共用同一口径）：
  /// ① 页终点（下一个页起点 = 行边界/插图边界）→ 用它，页尾留白不足一行；
  /// ② 候选未知 → 裁到区间内最后一条**安全边界**（宁可页尾多留白）；
  /// ③ 内容到此为止（文档末尾）→ 整段露出，不切任何字；
  /// ④ 什么都没有 → **留白**。
  ///
  /// **绝不退化成整屏**：整屏的切线落在任意 y 上，会把一行字拦腰切断——
  /// 推入页（旧实现：高度冻在起翻瞬间，候选未知时直接给满一屏）因此会在
  /// 翻页途中露出半行，收尾后又消失（用户实测「翻页时一闪一截断的行」）。
  double contentHeightAt(double start, double viewportHeight) {
    if (viewportHeight <= 0) return 0;
    viewport = viewportHeight;
    final next = peekNextPageStart(start);
    if (next != null) return (next - start).clamp(0.0, viewportHeight);
    final safe = largestSafeWithin(start + 0.5, start + viewportHeight);
    if (safe != null) return (safe - start).clamp(0.0, viewportHeight);
    final end = _contentEnd;
    if (end != null && end > start) {
      return (end - start).clamp(0.0, viewportHeight);
    }
    return 0;
  }

  // —— 翻页查询 ——

  /// 下一页起点（严格大于 [from]）。
  ///
  /// 优先走页起点链（精确往返）：[from] 本身是走过的页起点时，直接取链上
  /// 的相邻页起点——保证「下一页 → 上一页」精确回到原落点（局部规则在插图
  /// 附近不唯一，链才是权威）。
  /// 链未覆盖（跳章/跳目录后的未测量区域）时按页结构规则现算。
  ///
  /// 本方法会**记住**走过的页起点（页起点链）；只想查询不动链的场合用
  /// [peekNextPageStart]（弹道物理与视口裁剪用——它们的探测是「试算」，
  /// 不该把猜测写进链里）。
  double? nextPageStart(double from) {
    final next = peekNextPageStart(from);
    if (next == null) return null;
    _chainAdd(from);
    _chainAdd(next);
    return next;
  }

  /// 下一页起点（只读：不写页起点链）。
  double? peekNextPageStart(double from) {
    final index = _chainIndexOf(from);
    if (index >= 0) {
      final chained = _chainNeighbour(index, 1);
      if (chained != null) return chained;
    }
    return _successor(from);
  }

  /// 上一页起点（严格小于 [from]）。
  ///
  /// 语义同 [nextPageStart]：链上有相邻页起点就用链上的（精确往返），
  /// 否则按页结构规则现算（图片块底 → 该图片块顶；否则取「上一页排得最
  /// 满」的最靠前候选，且上一页内不得有插图）。
  double? prevPageStart(double from) {
    final prev = peekPrevPageStart(from);
    if (prev == null) return null;
    _chainAdd(prev);
    _chainAdd(from);
    return prev;
  }

  /// 上一页起点（只读：不写页起点链）。
  double? peekPrevPageStart(double from) {
    final index = _chainIndexOf(from);
    if (index >= 0) {
      final chained = _chainNeighbour(index, -1);
      if (chained != null) return chained;
    }
    return _predecessor(from);
  }

  /// 距 [from] 最近的页起点（弹道吸附用）。
  ///
  /// - 链覆盖当前位置 → 取链中最近者（[from] 本身在链里时距离 0 → 不产生
  ///   二次位移：翻页动作 jumpTo 末尾会触发一次 `goBallistic(0)`，若这里再
  ///   挪一次，一次按键就会翻两页）；
  /// - 链未覆盖 → 按页结构规则现算：下一页起点 → 它的上一页起点 → 取较近
  ///   的那个（[from] 恰是页起点时，「上一页起点」就是 [from] 本身 → 不动）。
  ///
  /// 距 [from] 超过一屏视为「无吸附点」（返回 null，由调用方决定回弹）。
  double? nearestPageStart(double from) {
    double? best;
    var bestDistance = double.infinity;
    for (final pos in _chain) {
      final distance = (pos - from).abs();
      if (distance < bestDistance) {
        best = pos;
        bestDistance = distance;
      }
    }
    if (best != null && bestDistance <= viewport + epsilon) return best;
    final next = _successor(from);
    final prev = next != null ? _predecessor(next) : _predecessor(from);
    if (next == null && prev == null) return null;
    if (next == null) return prev;
    if (prev == null) return next;
    return (next - from).abs() <= (from - prev).abs() ? next : prev;
  }

  // —— 页结构规则 ——

  /// 下一个页起点（页结构规则，不经链）。
  ///
  /// **章边界不得越过**（新章节另起一页）：一屏之内出现下一章节起点时，
  /// 本页终点 = 该章节起点（章题与上一章正文不共页）；章节起点本身即是
  /// 合法页起点。
  double? _successor(double from) {
    // 本页从图片块顶起 → 下一页起点 = 图片块底（图片独占一页，页界不入图内）。
    final image = _imageAt(from);
    if (image != null) return image.imageBottom;
    final limit0 = from + viewport + epsilon;
    var limit = limit0;
    double? chapter;
    final nextChapter = _chapterStartAfter(from);
    if (nextChapter != null && nextChapter <= limit0) {
      // 章边界在一屏之内 → 本页到此为止（新章另起一页）。
      chapter = nextChapter;
      limit = nextChapter;
    }
    final start = _firstIndexAfter(from);
    double? best; // 行边界候选（最靠下）
    for (var i = start; i < _stops.length; i++) {
      final stop = _stops[i];
      if (stop.pos > limit) break;
      if (stop.isImage) {
        // 一屏之内出现图片 → 该页终点 = 图片块顶（图片另起一页）。
        return stop.pos;
      }
      best = stop.pos;
    }
    // 章边界即页终点（页内其余行一并显示，页尾留白到章首）。
    if (chapter != null) return chapter;
    return best;
  }

  /// 下一个页起点（页结构规则，**不**夹章边界）。
  ///
  /// 只用于「上一页起点」的精确判定：夹了章边界后，一屏之内的多个候选都会
  /// 映射到同一个章起点，上一页起点就不再精确（往返会退化成「回到最靠前的
  /// 候选」）。
  double? _successorRaw(double from) {
    final image = _imageAt(from);
    if (image != null) return image.imageBottom;
    final limit = from + viewport + epsilon;
    final start = _firstIndexAfter(from);
    double? best;
    for (var i = start; i < _stops.length; i++) {
      final stop = _stops[i];
      if (stop.pos > limit) break;
      if (stop.isImage) return stop.pos;
      best = stop.pos;
    }
    return best;
  }

  /// 上一个页起点（页结构规则，不经链）。
  ///
  /// 规则（与 [_successor] 对称）：
  /// - `from` 是图片块底 → 该图片块顶（图片独占一页）；
  /// - 否则 = 「后继恰为 [from]」的候选中**最靠前**的一个——那一页排得最
  ///   满（插图页尤其重要：取最近的文字行会退化成半页）；
  /// - **不得跨过章边界**（上一页与本章同章；`from` 恰是章起点时，上一页
  ///   可以是上一章的末页）；
  /// - 找不到（`from` 不在页起点上，如手动滚动后的落点）→ 兜底取「一屏之内
  ///   最靠前的合法候选」，且该候选与 [from] 之间**不得有插图**（插图独占页
  ///   → 插图前后的正文不能同页）、**不得跨章**。
  double? _predecessor(double from) {
    // 图片块底 → 上一页起点 = 该图片块顶（图片独占一页）。
    final imageTop = _imageBottomAt(from);
    if (imageTop != null) return imageTop;
    // 上一页可落的最低位置（不跨章边界）。
    final floor = _predecessorFloor(from);
    // 「后继恰为 from」的候选中最靠前的一个（用未夹章边界的原始后继判定，
    // 保证上一页起点精确）。
    for (var i = 0; i < _stops.length; i++) {
      final pos = _stops[i].pos;
      if (pos >= from - epsilon) break;
      if (floor != null && pos < floor - epsilon) continue; // 跨章了
      if (_samePos(_successorRaw(pos), from)) return pos;
    }
    // 兜底：一屏之内最靠前的合法候选（插图前的正文不得与插图后的正文同页；
    // 也不得跨过章边界）。
    var floor2 = from - viewport - epsilon;
    if (floor != null && floor > floor2) floor2 = floor;
    for (final stop in _stops) {
      if (!stop.isImage) continue;
      if (stop.pos >= from - epsilon) break; // 插图在 from 之后 → 不影响
      final bottom = stop.imageBottom!;
      if (bottom > floor2) floor2 = bottom;
    }
    final index = _firstIndexAtOrAfter(floor2);
    if (index >= _stops.length) return null;
    final pos = _stops[index].pos;
    if (pos >= from - epsilon) return null; // 没有更早的候选
    return pos;
  }

  /// 上一页起点可落的**最低位置**（不得跨过章边界）。
  ///
  /// - [from] 不是章起点 → 上一页必须在**同一章**内 → 下界 = 本章起点；
  /// - [from] 恰是章起点 → 上一页可以是上一章的末页 → 下界 = 上一章起点
  ///   （未测到则不设限）。
  double? _predecessorFloor(double from) {
    double? current;
    double? previous;
    for (final c in _chapterStarts) {
      if (c <= from + epsilon) {
        previous = current;
        current = c;
      } else {
        break;
      }
    }
    if (current == null) return null;
    if (_samePos(current, from)) return previous;
    return current;
  }

  /// 严格大于 [from] 的最近章节起点（章边界）。
  double? _chapterStartAfter(double from) {
    for (final c in _chapterStarts) {
      if (c > from + epsilon) return c;
    }
    return null;
  }

  /// 位于 [pos] 的图片候选（[pos] 为图片块顶）。
  EpubStop? _imageAt(double pos) {
    final index = _indexAt(pos);
    if (index < 0) return null;
    final stop = _stops[index];
    return stop.isImage ? stop : null;
  }

  /// 以 [pos] 为块底的图片候选的块顶（[pos] 为图片块底）。
  double? _imageBottomAt(double pos) {
    final index = _indexAt(pos);
    if (index < 0) return null;
    for (var i = index - 1; i >= 0; i--) {
      final stop = _stops[i];
      if (!stop.isImage) continue;
      if (_samePos(stop.imageBottom, pos)) return stop.pos;
    }
    return null;
  }

  // —— 候选表查找 ——

  /// 首个 pos > [pos] 的候选下标（升序）。
  int _firstIndexAfter(double pos) {
    var low = 0;
    var high = _stops.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_stops[mid].pos <= pos + epsilon) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// 与 [pos] 相同（±epsilon）的候选下标；无则 -1。
  int _indexAt(double pos) {
    var low = 0;
    var high = _stops.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final diff = _stops[mid].pos - pos;
      if (diff.abs() <= epsilon) return mid;
      if (diff < 0) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return -1;
  }

  /// 首个 pos ≥ [pos] 的候选下标（升序）。
  int _firstIndexAtOrAfter(double pos) {
    var low = 0;
    var high = _stops.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_stops[mid].pos < pos - epsilon) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  static bool _samePos(double? a, double? b) {
    if (a == null || b == null) return false;
    return (a - b).abs() <= epsilon;
  }

  // —— 页起点链 ——

  /// 链中与 [from] 重合的页起点下标；无则 -1。
  int _chainIndexOf(double from) {
    for (var i = 0; i < _chain.length; i++) {
      if (_samePos(_chain[i], from)) return i;
      if (_chain[i] > from + epsilon) break;
    }
    return -1;
  }

  /// 链上第 [index] 项的相邻页起点（[step] = +1 下一页 / -1 上一页）。
  ///
  /// 相邻项若离得超过一屏（跳章留下的缺口），视为「不是相邻页」→ 返回
  /// null，由调用方改用页结构规则现算（免得一次翻页跳过整段内容）。
  double? _chainNeighbour(int index, int step) {
    final target = index + step;
    if (target < 0 || target >= _chain.length) return null;
    final distance = (_chain[target] - _chain[index]).abs();
    if (distance > viewport + epsilon) return null;
    return _chain[target];
  }

  /// 记入一个页起点（保持升序；已有则忽略）。
  void _chainAdd(double pos) {
    for (final known in _chain) {
      if (_samePos(known, pos)) return;
    }
    var low = 0;
    var high = _chain.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_chain[mid] < pos) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    _chain.insert(low, pos);
  }
}
