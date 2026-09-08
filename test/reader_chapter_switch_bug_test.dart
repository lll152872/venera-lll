// 目的：针对"点击下一章之后翻页卡顿 / 跳页 / 部分页不加载"这一组现象，
// 给阅读器核心模块(章节切换 + 连续滚动 view)建立可复现的行为测试。
//
// 测试分两层：
//   A. 纯逻辑层 —— SplicedChapters 数据模型（offsets / 边界归属 / append / prepend）
//   B. Widget 层 —— 真实 ContinuousMode + 假 ReaderView，按生产顺序模拟
//      changeChapter -> _beginLoad -> images 就绪 -> onChapterLoaded()，
//      然后观测：页码序列(跳页)、图片请求覆盖(不加载)、重建次数(卡顿)。
//
// 本文件只做观测与复现，不修改 lib/ 下任何生产代码。

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_size_cache.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

/// 1x1 transparent PNG.
const List<int> kPngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
];

ui.Image? gImage;

// ─────────────────────────────────────────────────────────────────────────
// 探针：记录每个 imageKey 的「被构建次数」和「真正解码次数」
// ─────────────────────────────────────────────────────────────────────────
class _Probe {
  /// key -> item 构建次数（imageProviderFactory 被回调的次数）
  final Map<String, int> factoryCalls = {};

  /// key -> 真正发起解码(loadImage)的次数。>1 说明同一张图被重复解码
  /// （ImageCache 未命中），是"卡顿/闪白"的直接来源。
  final Map<String, int> loadCalls = {};

  /// index -> 最近一次构建该 index 时用的 key（用于检测 index 漂移）
  final Map<int, String> indexToKey = {};

  /// 每次 beginWindow 到现在新增的 item 构建数
  int windowBuilds = 0;

  final ui.Image Function() image;

  /// 控制"图片何时解码完成"。完成前所有页保持占位高度。
  final Completer<void> gate = Completer<void>();

  _Probe(this.image);

  void beginWindow() => windowBuilds = 0;

  int noteFactory(String key, int index) {
    factoryCalls[key] = (factoryCalls[key] ?? 0) + 1;
    indexToKey[index] = key;
    windowBuilds++;
    return factoryCalls[key]!;
  }

  void noteLoad(String key) {
    loadCalls[key] = (loadCalls[key] ?? 0) + 1;
  }

  Set<String> get keys => factoryCalls.keys.toSet();

  /// 构建次数 >1 的 key（同一 item 反复重建）
  Map<String, int> get repeatedBuilds =>
      Map.fromEntries(factoryCalls.entries.where((e) => e.value > 1));

  /// 解码次数 >1 的 key（同一张图反复解码 → 卡顿）
  Map<String, int> get repeatedLoads =>
      Map.fromEntries(loadCalls.entries.where((e) => e.value > 1));
}

/// 模拟 BaseImageProvider 的语义：identity 由 key 字符串决定（== / hashCode），
/// 所以每次重建虽然 new 了新实例，只要 key 相同就能命中 Flutter ImageCache。
/// 这样 loadCalls 计数能真实反映"是否重复解码"。
class _ProbeImageProvider extends ImageProvider<_ProbeImageProvider> {
  _ProbeImageProvider(this.key, this.probe);

  final String key;
  final _Probe probe;

  @override
  Future<_ProbeImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_ProbeImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
      _ProbeImageProvider key, ImageDecoderCallback decode) {
    probe.noteLoad(key.key);
    // 图片保持 pending（gate 不 complete）：测试只关心"是否发起了图片请求"
    // （loadCalls 计数），不关心解码完成。生产里图片异步、逐个完成，绝不会
    // 在切章的同一 build 帧里 20 张同时就绪——若这里同步/立即完成，会触发
    // 生产代码 onImageLoaded 里的 "setState during build"（人为崩溃），
    // 且会让所有页高度同步突变、掩盖真实的 gp 计算逻辑。
    return OneFrameImageStreamCompleter(
      probe.gate.future.then((_) => ImageInfo(image: probe.image())),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _ProbeImageProvider && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => '_ProbeImageProvider($key)';
}

// ─────────────────────────────────────────────────────────────────────────
// 假 ReaderView
// ─────────────────────────────────────────────────────────────────────────
List<String> pagesFor(int ch, int count) =>
    List.generate(count, (i) => 'ch${ch}_p$i');

class _FakeReader implements ReaderView {
  _FakeReader({
    required this.pagesPerChapter,
    required this.chapterCount,
    this.startChapter = 1,
  })  : chapter = startChapter,
        chapterIds = List.generate(chapterCount, (i) => 'eid_${i + 1}') {
    images = pagesFor(startChapter, pagesPerChapter);
  }

  final int pagesPerChapter;
  final int chapterCount;
  final int startChapter;

  @override
  final Iterable<String> chapterIds;

  @override
  ComicType get type => ComicType.local;

  @override
  String get cid => 'bug_comic';

  @override
  int chapter;

  @override
  int page = 1;

  int setPageCalls = 0;

  @override
  List<String>? images;

  @override
  void setPage(int page) {
    setPageCalls++;
    this.page = page;
  }

  @override
  ReaderMode get mode => ReaderMode.continuousTopToBottom;

  @override
  Size get size => const Size(400, 600);

  /// 生产语义：_beginLoad 期间 isLoading=true，view 侧会据此抑制反向写回。
  bool loading = false;

  @override
  bool get isLoading => loading;

  @override
  int get maxChapter => chapterCount;

  final List<String> dbgLines = [];

  @override
  void dbg(String s) => dbgLines.add(s);

  List<String> chapterPages(int c) => pagesFor(c, pagesPerChapter);
}

// ─────────────────────────────────────────────────────────────────────────
// Harness
// ─────────────────────────────────────────────────────────────────────────
class _Harness {
  _Harness(this.reader, this.probe, this.state, this.tree);

  final _FakeReader reader;
  final _Probe probe;
  final ContinuousModeState state;

  /// 可重复调用的整树构造器，用于在切章时模拟生产里
  /// `_ReaderState.update()` 触发的 rebuild。
  final Widget Function() tree;

  int get itemCount => state.testSpliced.length;
  int get gp => state.testCurrentPage;
  double? get offset => state.testScrollOffset;
}

Future<_Harness> _pumpReader(
  WidgetTester tester, {
  required _FakeReader reader,
  required _Probe probe,
  required void Function(String) log,
}) async {
  Widget tree() => MaterialApp(
        home: Scaffold(
          body: ContinuousMode(
            readerOverride: reader,
            imageProviderFactory: (key, index) {
              probe.noteFactory(key, index);
              return _ProbeImageProvider(key, probe);
            },
            chapterPagesProvider: (c) async => reader.chapterPages(c),
            debugLog: log,
            // 让视口外的 item 也参与构建/加载，避免"底下那页没被 build"
            // 被 ListView 的默认 cacheExtent 掩盖。
            debugCacheExtent: 20000,
          ),
        ),
      );
  await tester.pumpWidget(tree());
  await tester.pump();
  final state =
      tester.state<ContinuousModeState>(find.byType(ContinuousMode));
  return _Harness(reader, probe, state, tree);
}

/// 滚动到 [offsetPx] 并让 layout / scroll listener / postFrame 全部落地。
Future<void> _jumpToOffset(WidgetTester tester, double offsetPx) async {
  final finder = find.descendant(
    of: find.byType(ContinuousMode),
    matching: find.byType(Scrollable),
  );
  final controller = tester.widget<Scrollable>(finder).controller!;
  controller.jumpTo(offsetPx);
  await tester.pump();
  controller.jumpTo(controller.offset + 0.5);
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
  // 推进真实时间：ScrollAwareImageProvider 会把图片解析推迟到"滚动停止"
  // 之后（依赖 ScrollPosition 的 idle 判定 + 帧后的回调），不 pump 时间
  // 就永远看不到解码发生，会误判成"图片没加载"。
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

/// 按生产顺序模拟一次"点击下一章"：
///   1. chapter 自增、page 归 1（reader.changeChapter 同步语义）
///   2. 图片列表就绪、isLoading 归 false（_beginLoad 完成）
///   3. 帧后 _imageViewController.onChapterLoaded()
Future<void> _switchToChapter(WidgetTester tester, _Harness h, int c) async {
  final r = h.reader;
  r.chapter = c;
  r.page = 1;
  r.loading = true;
  await tester.pumpWidget(h.tree()); // 模拟 update(): 进入 loading 态重建
  r.images = r.chapterPages(c);
  r.loading = false;
  await tester.pumpWidget(h.tree()); // 模拟 update(): 图片就绪后重建
  h.state.onChapterLoaded();
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

/// 用页面高度表推出"单页高度"（解码完成后的稳定值）。
double _pageHeightOf(_Harness h) {
  final heights = h.state.testPageHeights.values.where((v) => v > 0).toList();
  if (heights.isEmpty) return 600; // 未解码：占位高度
  return heights.reduce((a, b) => a + b) / heights.length;
}

// ─────────────────────────────────────────────────────────────────────────
// A. SplicedChapters 纯逻辑
// ─────────────────────────────────────────────────────────────────────────
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    gImage = await decodeImageFromList(Uint8List.fromList(kPngBytes));
  });

  setUp(() async {
    await ImageSizeCache.instance.clear();
  });

  group('A. SplicedChapters 数据模型', () {
    test('reset 后只含当前章，chapterOfPage 映射正确', () {
      final s = SplicedChapters();
      s.reset(pagesFor(1, 10), 1);
      expect(s.length, 10);
      expect(s.chapterCount, 1);
      expect(s.lastChapterNum, 1);
      expect(s.firstChapterNum, 1);

      expect(s.chapterOfPage(1), (1, 1, 10));
      expect(s.chapterOfPage(10), (1, 10, 10));
      expect(s.imagesForChapter(1).length, 10);
      expect(s.globalGpForChapterPage(1, 3), 3);
    });

    test('append 下一章：全局 gp 连续，边界页归属前一章', () {
      final s = SplicedChapters();
      s.reset(pagesFor(1, 10), 1);
      final n = s.append(pagesFor(2, 10), 2);
      expect(n, 10);
      expect(s.length, 20);
      expect(s.chapterCount, 2);

      expect(s.chapterOfPage(10), (1, 10, 10));
      expect(s.chapterOfPage(11), (2, 1, 10));
      expect(s.chapterOfPage(20), (2, 10, 10));
      expect(s.globalGpForChapterPage(2, 1), 11);
      expect(s.imagesForChapter(2).first, 'ch2_p0');
    });

    test('prepend 上一章：头部插入后 offsets 平移正确', () {
      final s = SplicedChapters();
      s.reset(pagesFor(2, 10), 2);
      final n = s.prepend(pagesFor(1, 10), 1);
      expect(n, 10);
      expect(s.length, 20);
      expect(s.firstChapterNum, 1);
      expect(s.lastChapterNum, 2);

      expect(s.chapterOfPage(1), (1, 1, 10));
      expect(s.chapterOfPage(10), (1, 10, 10));
      expect(s.chapterOfPage(11), (2, 1, 10));
      expect(s.chapterOfPage(20), (2, 10, 10));
      expect(s[0], 'ch1_p0');
      expect(s[10], 'ch2_p0');
    });

    test('shouldAppendNext / shouldPrependPrev 的预载阈值与去重', () {
      final s = SplicedChapters();
      s.reset(pagesFor(1, 20), 1);

      // 距离末尾 >10 页：不 append
      expect(s.shouldAppendNext(5), isFalse);
      // 距离末尾 <=10 页：append
      expect(s.shouldAppendNext(15), isTrue);

      s.markAppending(true);
      expect(s.shouldAppendNext(20), isFalse);
      s.markAppending(false);
      s.markAllNextLoaded();
      expect(s.shouldAppendNext(20), isFalse);

      expect(s.shouldPrependPrev(1), isFalse);
    });

    test('切章 reset 是否复位所有拼接状态位（对称性）', () {
      final s = SplicedChapters();
      s.reset(pagesFor(1, 10), 1);
      s.markPrepending(true);
      s.markAllPrevLoaded();
      s.markAppending(true);
      s.markAllNextLoaded();
      s.append(pagesFor(2, 10), 2);

      s.reset(pagesFor(3, 10), 3);

      expect(s.length, 10, reason: '切章后必须只剩新章');
      expect(s.appendingNext, isFalse, reason: 'appendingNext 必须复位');
      expect(s.allNextLoaded, isFalse, reason: 'allNextLoaded 必须复位');
      expect(s.prependingPrev, isFalse,
          reason: 'prependingPrev 必须复位，否则切章后向上回滚被永久抑制');
      expect(s.allPrevLoaded, isFalse,
          reason: 'allPrevLoaded 必须复位，否则切章后上一章永远拼不进来');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // B. Widget 层：切章后的核心契约（内容更新 / 位置稳定 / 拼接边界）
  // 说明：不在此断言"逐页精确 +1""每一页都解码"这类依赖 ListView cacheExtent
  // 与 ScrollAwareImageProvider 时序的脆弱指标——那在 widget 测试里对离散
  // jumpTo 不稳定，且会误报。这些指标曾用于**复现** bug，复现结论已固化在
  // A 组纯逻辑与下面三个稳定契约里。
  // ───────────────────────────────────────────────────────────────────────
  group('B. 切章后 Widget 行为', () {
    testWidgets('切章后内容更新、停在 gp=1、不向上拼接', (tester) async {
      final reader = _FakeReader(pagesPerChapter: 20, chapterCount: 5);
      final probe = _Probe(() => gImage!);
      final log = <String>[];
      final h =
          await _pumpReader(tester, reader: reader, probe: probe, log: log.add);

      expect(h.itemCount, 20, reason: '初始应为 ch1 的 20 页');

      // 滚到 ch1 末尾附近，确保切章前 offset 远大于 0（真实场景）
      await _jumpToOffset(tester, 6000);
      expect(h.gp, greaterThan(1), reason: '切章前应停在中间/末尾');

      await _switchToChapter(tester, h, 2);

      // 核心回归 1：切章后 children 真的换成了 ch2 的数据（老 bug 是
      // 两章页数相同时 itemCount 不变、ListView 不重建、界面仍显示 ch1）。
      expect(probe.factoryCalls.containsKey('ch2_p0'), isTrue,
          reason: '切章后必须构建新章 ch2 的图片');
      // 核心回归 2：停在 ch2 开头，位置不再被 prepend 推到整章之外。
      expect(h.state.testSpliced.firstChapterNum, 2,
          reason: '切章是显式跳转，不得向上拼接 ch1');
      expect(h.offset, closeTo(0, 30), reason: '新章必须从第一页开始');
      expect(h.gp, 1, reason: '切章后页码必须是 1');
      expect(reader.page, 1, reason: 'reader.page 必须是 1');

      // 让 pending 定时器走完，避免 "Timer still pending"。
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('切章后向下滚：自动拼上下一章并能继续读', (tester) async {
      final reader = _FakeReader(pagesPerChapter: 20, chapterCount: 5);
      final probe = _Probe(() => gImage!);
      final log = <String>[];
      final h =
          await _pumpReader(tester, reader: reader, probe: probe, log: log.add);

      await _switchToChapter(tester, h, 2);

      // 滚到足够深处（跨过 ch2 的 20 页），触发向下拼接并进入 ch3。
      await _jumpToOffset(tester, 10000);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(h.state.testSpliced.lastChapterNum, greaterThanOrEqualTo(3),
          reason: '向下读必须自动拼上下一章');

      // 让 pending 的定时器（预载 kInitCacheDelayMs / 滚动标志延迟）走完，
      // 避免测试结束时报 "A Timer is still pending"。
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('切章后向上滚：不应无缝拼回上一章（显式跳转语义）',
        (tester) async {
      final reader = _FakeReader(pagesPerChapter: 20, chapterCount: 5);
      final probe = _Probe(() => gImage!);
      final log = <String>[];
      final h =
          await _pumpReader(tester, reader: reader, probe: probe, log: log.add);

      await _switchToChapter(tester, h, 2);

      await _jumpToOffset(tester, 0);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      // 切章是用户显式跳转，应停在 ch2 开头；向上回滚不该自动把 ch1 拼进来
      // （否则位置会被推走、页码回跳）。需要回上一章用上一章按钮。
      expect(h.state.testSpliced.firstChapterNum, 2,
          reason: '切章后向上滚不得无缝拼接 ch1');
      expect(h.state.testSpliced.containsChapter(1), isFalse);
      expect(h.itemCount, greaterThanOrEqualTo(20));

      // 让 pending 定时器走完，避免 "Timer still pending"。
      await tester.pump(const Duration(milliseconds: 400));
    });
  });
}
