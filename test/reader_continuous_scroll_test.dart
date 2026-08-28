import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_size_cache.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

/// 1x1 transparent PNG (standard bytes, decodes to a valid image).
final Uint8List kTransparentPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

/// Decoded once in setUpAll (real async); every page shares this image.
ui.Image? gImage;

/// Controls when page images "finish loading". While pending, every page stays
/// at placeholder height (viewport 600). After the completer completes, all
/// built pages fire onImageLoaded at once and shrink to 400 (1x1 image scaled
/// to fit width 400) — emulating the production race "image finishes loading
/// while the user is scrolled mid-chapter" without any real I/O.
final Completer<void> gCompleter = Completer<void>();

/// Test-only image provider whose completion is gated by a [Completer].
/// A unique instance per page index avoids ImageCache sync-completion paths
/// (production network images never complete synchronously, so ComicImage
/// must not be fed a cache-hit during build — that triggers setState-during-
/// build). Pass a per-test completer to control loading per test; defaults to
/// the shared [gCompleter] (used by the original rollback regression test).
class _GatedImageProvider extends ImageProvider<_GatedImageProvider> {
  _GatedImageProvider(this.index, [Completer<void>? completer])
      : completer = completer ?? gCompleter;

  final int index;
  final Completer<void> completer;

  @override
  Future<_GatedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_GatedImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
      _GatedImageProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(
      completer.future.then((_) => ImageInfo(image: gImage!)),
    );
  }
}

/// Minimal [ReaderView] fake. Multi-chapter capable: [chapterCount] chapters
/// of [pagesPerChapter] pages each, starting at [startChapter]. Page keys are
/// globally unique per chapter (`ch${ch}_p$i`) so ValueKey-based element reuse
/// across a prepend behaves like production.
///
/// NOTE: tests use 20 pages/chapter on purpose — a 10-page chapter would make
/// gp=1 also satisfy `shouldAppendNext` (distance to tail 9 <= 10), letting
/// append race prepend, which single-shot jumpTo can't recover from.
class _FakeReader implements ReaderView {
  _FakeReader({
    required this.logs,
    this.chapterCount = 1,
    this.pagesPerChapter = 20,
    this.startChapter = 1,
  }) : chapter = startChapter;

  final List<String> logs;
  final int chapterCount;
  final int pagesPerChapter;
  final int startChapter;

  late final List<String> _chapterIds =
      List.generate(chapterCount, (i) => 'eid_$i');

  @override
  Iterable<String>? get chapterIds => _chapterIds;

  @override
  ComicType get type => ComicType.local;

  @override
  String get cid => 'test_comic';

  @override
  int chapter;

  @override
  int page = 1;

  @override
  List<String>? get images =>
      List.generate(pagesPerChapter, (i) => 'ch${chapter}_p$i');

  @override
  set images(List<String>? value) {
    // Chapter switch re-assigns images; tests track state via the chapter field.
  }

  @override
  void setPage(int page) => this.page = page;

  @override
  ReaderMode get mode => ReaderMode.continuousTopToBottom;

  @override
  Size get size => const Size(400, 600);

  @override
  bool get isLoading => false;

  @override
  int get maxChapter => chapterCount;

  @override
  void dbg(String s) => logs.add(s);
}

/// Builds the [ContinuousMode] under test with the given fake and injectable
/// page provider, returns its state.
Future<ContinuousModeState> _pumpReader(
  WidgetTester tester, {
  required List<String> logs,
  _FakeReader? reader,
  Completer<void>? completer,
  Future<List<String>> Function(int chapter)? pagesProvider,
}) async {
  final r = reader ?? _FakeReader(logs: logs);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ContinuousMode(
          readerOverride: r,
          imageProviderFactory: (key, index) =>
              _GatedImageProvider(index, completer ?? gCompleter),
          chapterPagesProvider: pagesProvider,
          debugLog: logs.add,
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.state<ContinuousModeState>(find.byType(ContinuousMode));
}

/// Jumps the ListView's scroll position to [offset] and pumps frames so item
/// layout, the scroll listener, and any post-frame prepend jump settle.
///
/// A single jumpTo only fires the listener against the *previous* frame's
/// layout (_currentPageFromViewport reads RenderBox positions), so a second
/// tiny jumpTo after the layout settles re-syncs against the new layout —
/// this is what makes prepend/append triggers deterministic in tests.
Future<void> _jumpToOffset(WidgetTester tester, double offset) async {
  final finder = find.descendant(
    of: find.byType(ContinuousMode),
    matching: find.byType(Scrollable),
  );
  final controller = tester.widget<Scrollable>(finder).controller!;
  controller.jumpTo(offset);
  await tester.pump();
  // Layout has settled at `offset` — but a prepend post-frame jump may have
  // already compensated the offset. Re-sync against the *actual* current
  // offset (not the requested one) so a tiny jumpTo re-fires the listener
  // without undoing any prepend compensation.
  controller.jumpTo(controller.offset + 0.5);
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}

/// Page keys for chapter [ch], matching _FakeReader's image naming.
List<String> pagesFor(int ch, int count) =>
    List.generate(count, (i) => 'ch${ch}_p$i');

/// 轨迹点：当前 (gp, ch, p, offset)。用 [SplicedChapters.chapterOfPage]
/// 的 (ch,p) 映射（比 reader.chapter 准——prepend 后 reader.chapter 可能
/// 滞后），每 pump 一帧记录一次，用于断言滚动过程中页码序列不回退
/// （盲区 A：中间帧瞬态回跳；盲区 B：gp 对但 (ch,p) 映射错）。
String _trackPoint(ContinuousModeState s) {
  final gp = s.testCurrentPage;
  final (ch, p, _) = s.testSpliced.chapterOfPage(gp);
  return 'gp=$gp ch$ch p$p off=${s.testScrollOffset}';
}

/// 从轨迹点解析 (gp, ch, p)。
(int, int, int) _parseTrack(String t) {
  final gp = int.parse(RegExp(r'gp=(\d+)').firstMatch(t)!.group(1)!);
  final ch = int.parse(RegExp(r'ch(\d+)').firstMatch(t)!.group(1)!);
  final p = int.parse(RegExp(r'p(\d+) ').firstMatch(t)!.group(1)!);
  return (gp, ch, p);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ComicImage can hit the error/retry branch (uses "Retry".tl), which
    // requires the translation table that App normally initializes at boot.
    await AppTranslation.init();
    gImage = await decodeImageFromList(kTransparentPng);
  });

  setUp(() async {
    // Isolate tests from ImageSizeCache entries put by the cached-size test.
    await ImageSizeCache.instance.clear();
  });

  testWidgets(
      'continuous scroll: image load (height shrink) must not roll the '
      'scroll position back', (tester) async {
    final logs = <String>[];
    final reader = _FakeReader(logs: logs);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContinuousMode(
            readerOverride: reader,
            imageProviderFactory: (key, index) => _GatedImageProvider(index),
            debugLog: logs.add,
            // Test seam：全量 build 所有 item。默认 cacheExtent(250px) 下
            // 视口上方的页永不 build/加载，收缩只发生在视口顶边之下，
            // offset 数学上不可能移动，"不回滚"断言恒真（空转过）。
            // 大 cacheExtent 让 gp1-20 首帧全部 build，complete 后全局收缩
            // 600→400，上方内容变短 → SliverList scrollOffsetCorrection
            // 必须把 offset 修下来（5400→3600），真正走进回归路径。
            debugCacheExtent: 20000,
          ),
        ),
      ),
    );
    // First frame: every page is at placeholder height (viewport 600).
    await tester.pump();

    final state =
        tester.state<ContinuousModeState>(find.byType(ContinuousMode));
    expect(state.testScrollOffset, closeTo(0, 1));

    // Jump to page 10: offset ~= 9 * 600 = 5400. Images are NOT loaded yet
    // (completer pending), so all pages are still placeholder height.
    final anim = state.animateToPage(10);
    await tester.pump(); // start ticker (first tick elapsed=0)
    await tester.pump(const Duration(milliseconds: 250)); // finish animation
    await anim;
    final offsetBefore = state.testScrollOffset!;
    expect(offsetBefore, closeTo(5400, 20),
        reason: 'should sit at page-10 top (9 * 600)');

    // 盲区 A/B 断言：complete 前记录轨迹点，complete 后每帧记录，
    // 断言页码序列（gp/ch/p）不回退——只查最终 offset 会漏掉
    // "第一帧跳回、第二帧拉回"的瞬态回跳。
    final beforeTrack = _trackPoint(state);
    final (beforeGp, beforeCh, _) = _parseTrack(beforeTrack);

    // Let ALL page images "finish loading" now. Every page shrinks from 600
    // (placeholder) to 400 (1x1 image scaled to fit width 400) — including
    // the 9 pages ABOVE the viewport top edge (gp1-9). That shrinks the
    // content above by 9 * 200 = 1800px, forcing SliverList's
    // scrollOffsetCorrection to move the offset down (5400 → ~3600) to keep
    // page 10 visually pinned at the viewport top. The old pixel-accumulation
    // page-number mechanism rolled back to 0 in exactly this scenario.
    gCompleter.complete();
    final trail = <String>[];
    var sawChange = false;
    for (var i = 0; i < 8; i++) {
      await tester.pump();
      final t = _trackPoint(state);
      trail.add(t);
      if (t != beforeTrack) sawChange = true;
    }

    // 防空转断言：complete 后轨迹必须有真实位移（offset/gp 任一变化）。
    // 全局收缩必然改变上方内容高度，SliverList 的 scrollOffsetCorrection
    // 必须修正 offset——若轨迹纹丝不动，说明图片加载/收缩路径没生效，
    // 下面的"不回退"断言全是恒真，测试就空转了。
    expect(sawChange, isTrue,
        reason: '图片加载完成后轨迹必须有位移（$beforeTrack -> $trail），'
            '否则图片加载/收缩路径未生效，断言空过');

    // 轨迹断言：complete 后每一帧都不得回滚（老 bug 表现：offset 回 0 /
    // 页码回开头）。瞬态帧里 correction 应用与重排之间存在 RenderBox 位置
    // 错位窗口，gp 允许短暂漂移，但 ch 不得回退、gp 不得回跳到开头附近。
    for (final t in trail) {
      final (gp, ch, _) = _parseTrack(t);
      expect(ch, greaterThanOrEqualTo(beforeCh),
          reason: '章节不得回退（$beforeTrack -> $t）');
      expect(gp, greaterThanOrEqualTo(beforeGp - 2),
          reason: '页码不得瞬态回跳（$beforeTrack -> $t）');
    }

    final offsetAfter = state.testScrollOffset!;
    final (finalGp, finalCh, _) = _parseTrack(trail.last);
    // Core regression assertions, based on measured SliverList behavior:
    //
    // SliverList does NOT correct the offset here: scrollOffsetCorrection
    // only fires when the in-memory firstChild's scrollOffset exceeds the
    // scroll position (sliver_list.dart). With a huge cacheExtent the
    // firstChild is the list head (index 0, offset 0 <= 5400) → no
    // correction; children re-anchor from the head (gp10 top moves
    // 5400→3600) and the viewport top edge (5400) now lands inside gp14
    // (top = 13*400 = 5200). So the measured truth is:
    //   - offset stays at 5400 (not reset to 0 — that was the old bug)
    //   - page number moves forward to the item actually touching the
    //     viewport top edge (gp 14), never backwards
    //   - the gp jump (delta=4 > 3) exercises the GP JUMP detector for real
    //     (previously a dead code path in this test)
    expect(offsetAfter, closeTo(5400, 50),
        reason: 'offset must stay put (no correction, no reset-to-0 '
            'rollback); got $offsetAfter. Trail: $trail');
    expect(finalGp, inInclusiveRange(beforeGp, 14),
        reason: 'final page must be the item touching the viewport top edge '
            'in the shrunken layout (gp 10..14), never an earlier page '
            '(rollback) nor past gp 14 (wrong leading edge); trail: $trail');
    expect(finalCh, beforeCh, reason: 'chapter must not change');
    expect(logs.where((l) => l.contains('GP JUMP')), isNotEmpty,
        reason: 'the gp advance (10->14, delta 4) must trip the GP JUMP '
            'detector flag — proving the detector path is no longer dead '
            'code; logs: ${logs.where((l) => l.contains("GP JUMP"))}');
    expect(logs.where((l) => l.contains('GP REJECTED')), isEmpty,
        reason: 'no gp-jump rejection expected for a clean correction; '
            'trail: $trail');

    // Drain pending timers (init-cache delay 100ms, scrolling-flag 300ms).
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
      'prepend: rolling near the list head splices the previous chapter and '
      'compensates the scroll offset', (tester) async {
    final logs = <String>[];
    final reader = _FakeReader(
        logs: logs, chapterCount: 3, pagesPerChapter: 20, startChapter: 2);
    final completer = Completer<void>();
    final state = await _pumpReader(
      tester,
      logs: logs,
      reader: reader,
      completer: completer,
      pagesProvider: (ch) async => pagesFor(ch, 20),
    );

    expect(state.testSpliced.length, 20);
    expect(state.testSpliced.firstChapterNum, 2);

    // Scroll to ~page 3 of chapter 2 (offset 1200). The listener sees gp<=10
    // and triggers the async prepend of chapter 1.
    await _jumpToOffset(tester, 1200);

    expect(state.testSpliced.chapterCount, 2, reason: 'ch1 prepended');
    expect(state.testSpliced.firstChapterNum, 1);
    expect(state.testSpliced.containsChapter(1), isTrue);
    expect(state.testSpliced.length, 40);
    // Prepended content sits at the head: gp5 belongs to ch1 page 5.
    expect(state.testSpliced.chapterOfPage(5), (1, 5, 20));
    // Scroll compensation: 1200 + 20 placeholder pages * 600 = 13200, and the
    // viewport page follows the shift (3 + 20 = 23).
    expect(state.testScrollOffset, closeTo(13200, 20));
    expect(state.testCurrentPage, 23);
    expect(logs.where((l) => l.contains('GP JUMP')), isEmpty,
        reason: 'no rollback-detector alert expected');

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
      'prepend: chapter mapping stays consistent after head insert',
      (tester) async {
    final logs = <String>[];
    final reader = _FakeReader(
        logs: logs, chapterCount: 3, pagesPerChapter: 20, startChapter: 2);
    final completer = Completer<void>();
    final state = await _pumpReader(
      tester,
      logs: logs,
      reader: reader,
      completer: completer,
      pagesProvider: (ch) async => pagesFor(ch, 20),
    );

    await _jumpToOffset(tester, 1200);

    // Boundary: gp20 = ch1 last page, gp21 = ch2 first page.
    expect(state.testSpliced.chapterOfPage(20), (1, 20, 20));
    expect(state.testSpliced.chapterOfPage(21), (2, 1, 20));
    expect(state.testSpliced.imagesForChapter(1), hasLength(20));
    expect(state.testSpliced.imagesForChapter(2), hasLength(20));
    expect(state.testSpliced.globalGpForChapterPage(1, 1), 1);
    expect(state.testSpliced.globalGpForChapterPage(2, 1), 21);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
      'prepend: index shift keeps cached flags and page heights consistent',
      (tester) async {
    final logs = <String>[];
    final reader = _FakeReader(
        logs: logs, chapterCount: 3, pagesPerChapter: 20, startChapter: 2);
    final completer = Completer<void>();
    final state = await _pumpReader(
      tester,
      logs: logs,
      reader: reader,
      completer: completer,
      pagesProvider: (ch) async => pagesFor(ch, 20),
    );
    final cachedBefore = state.testCached.length;

    await _jumpToOffset(tester, 1200);

    // cached[] grew by 20; the prepended head pages are un-cached (false).
    expect(state.testCached.length, cachedBefore + 20);
    for (var i = 1; i <= 20; i++) {
      expect(state.testCached[i], isFalse,
          reason: 'prepended pages must start un-cached');
    }
    // _pageHeights only contains the prepended pages (head fill for jump
    // estimation); old-chapter pages have not loaded yet.
    expect(state.testPageHeights.keys, everyElement(inInclusiveRange(1, 20)));
    expect(state.testPageHeights, hasLength(20));
    // The registrar migrated contexts: viewport page is the shifted gp 23.
    expect(state.testCurrentPage, 23);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
      'prepend: zone compensation keeps the viewport stable when prepended '
      'pages finish loading', (tester) async {
    final logs = <String>[];
    final reader = _FakeReader(
        logs: logs, chapterCount: 3, pagesPerChapter: 20, startChapter: 2);
    final completer = Completer<void>();
    final state = await _pumpReader(
      tester,
      logs: logs,
      reader: reader,
      completer: completer,
      pagesProvider: (ch) async => pagesFor(ch, 20),
    );

    await _jumpToOffset(tester, 1200); // prepend ch1, offset 13200 (gp 23)

    // Viewport is at gp23; prepended pages (1..20) are far above the viewport
    // and not built, so they cannot load yet — offset must stay put.
    expect(state.testScrollOffset, closeTo(13200, 20),
        reason: 'prepend compensation must have settled');
    expect(state.testCurrentPage, 23);

    // Scroll up into the prepended zone in small steps (each <=3 pages, like
    // real continuous scrolling — a single big jump would trip the GP JUMP
    // soft-alert that guards against non-user jumps). Zone pages build at
    // placeholder height (600) since the completer is still pending.
    for (final off in [11400.0, 9600.0, 7800.0, 6000.0, 5400.0]) {
      await _jumpToOffset(tester, off);
    }
    // Let the built zone pages finish loading: each shrinks 600 -> 400 and
    // zone compensation pulls the offset along so the viewport stays on the
    // zone instead of jumping away.
    completer.complete();
    await tester.pump();
    await tester.pump();
    final offsetAfter = state.testScrollOffset!;
    expect(offsetAfter, lessThan(5400),
        reason: 'zone compensation must reduce offset when pages shrink');
    expect(state.testCurrentPage, inInclusiveRange(8, 11),
        reason: 'viewport must stay in the prepended zone');
    // NOTE: no log assertion here — the post-frame prepend jump legitimately
    // trips one GP REJECTED on the transitional frame (old layout yields a
    // wrong gp, the guard drops it and _lastSyncedGp stays correct).

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
      'prepend: ImageSizeCache-hit pages still compensate on load (no missed '
      'compensation)', (tester) async {
    final logs = <String>[];
    final reader = _FakeReader(
        logs: logs, chapterCount: 3, pagesPerChapter: 20, startChapter: 2);
    final completer = Completer<void>();
    // Pre-fill a prepended page's real size near the zone we scroll into
    // (gp10 = 'ch1_p9'): its layout is still the placeholder (600) until the
    // image loads, so it MUST compensate like any other zone page even though
    // _pageHeights is pre-filled with 400.
    ImageSizeCache.instance.put('ch1_p9', 1, 1);
    final state = await _pumpReader(
      tester,
      logs: logs,
      reader: reader,
      completer: completer,
      pagesProvider: (ch) async => pagesFor(ch, 20),
    );

    await _jumpToOffset(tester, 1200);

    // Hit page pre-filled its real display height (400) for jump estimation.
    expect(state.testPageHeights[10], 400);

    // Scroll into the zone in small steps (continuous-scroll simulation) and
    // let images load: hit page must compensate too.
    for (final off in [11400.0, 9600.0, 7800.0, 6000.0, 5400.0]) {
      await _jumpToOffset(tester, off);
    }
    completer.complete();
    await tester.pump();
    await tester.pump();
    expect(state.testScrollOffset!, lessThan(5400),
        reason: 'hit pages must also compensate (layout went 600 -> 400)');
    expect(state.testPageHeights[10], 400,
        reason: 'hit page height stays accurate after load');
    // No log assertion: prepend's post-frame jump legitimately trips one GP
    // REJECTED on its transitional frame (see the zone test note).

    await tester.pump(const Duration(milliseconds: 400));
    // Cancel the 2s ImageSizeCache flush timer started by put() above.
    await ImageSizeCache.instance.clear();
  });

  testWidgets('prepend: never triggers at chapter 1 (list head)',
      (tester) async {
    final logs = <String>[];
    final reader =
        _FakeReader(logs: logs, chapterCount: 1, pagesPerChapter: 10);
    final completer = Completer<void>();
    final state = await _pumpReader(
      tester,
      logs: logs,
      reader: reader,
      completer: completer,
      pagesProvider: (ch) async => pagesFor(ch, 10),
    );

    // Scroll to the head; there is no previous chapter.
    await _jumpToOffset(tester, 1200);
    await _jumpToOffset(tester, 0);

    expect(state.testSpliced.chapterCount, 1,
        reason: 'no prepend at chapter 1');
    expect(state.testSpliced.length, 10);
    expect(state.testSpliced.firstChapterNum, 1);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
      'prepend + append: both splice directions coexist without clobbering',
      (tester) async {
    final logs = <String>[];
    final reader = _FakeReader(
        logs: logs, chapterCount: 3, pagesPerChapter: 20, startChapter: 2);
    final completer = Completer<void>();
    final state = await _pumpReader(
      tester,
      logs: logs,
      reader: reader,
      completer: completer,
      pagesProvider: (ch) async => pagesFor(ch, 20),
    );

    // Up: prepend ch1.
    await _jumpToOffset(tester, 1200);
    expect(state.testSpliced.chapterCount, 2);
    expect(state.testSpliced.firstChapterNum, 1);
    expect(state.testSpliced.length, 40);

    // Down: near the tail (gp 31 of 40 after the prepend) appends ch3.
    await _jumpToOffset(tester, 18000);
    expect(state.testSpliced.chapterCount, 3,
        reason: 'append must still work after a prepend');
    expect(state.testSpliced.lastChapterNum, 3);
    expect(state.testSpliced.containsChapter(3), isTrue);
    expect(state.testSpliced.length, 60);

    await tester.pump(const Duration(milliseconds: 400));
  });
}
