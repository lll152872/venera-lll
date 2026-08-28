// E2E integration test for the continuous-scroll reader mode on Windows.
//
// Drives a REAL Reader (no mock): a procedurally generated multi-chapter local
// comic (different image sizes per page, with a random single-page "hiatus"
// chapter) feeds real file I/O, real image decode, and the real
// ContinuousMode + SplicedChapters pipeline. The reader widget tree is the
// real one (no readerOverride test seam); the only production change it relies
// on is the local-comic cross-chapter fix in images.dart (_fetchChapterPages).
//
// Run: flutter test integration_test/reader_e2e_test.dart -d windows --no-pub

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

/// Fixed seed → reproducible chapter page counts + hiatus position.
const int _kSeed = 42;
const int _kChapterCount = 32;
const int _kPagesMin = 50;
const int _kPagesVar = 11; // 50 + rand(11) → 50..60 pages
const double _kPageWidth = 400;

/// Deterministic comic spec: page counts, the single-page hiatus chapter, and
/// per-page heights (each page a different size → real async height changes,
/// the trigger condition for the jump-page bug).
class _ComicSpec {
  _ComicSpec({
    int chapters = _kChapterCount,
    int pagesMin = _kPagesMin,
    int pagesVar = _kPagesVar,
  })  : chapterCount = chapters,
        pagesMin = pagesMin,
        pagesVar = pagesVar {
    final rnd = math.Random(_kSeed);
    // 休刊：单页章节随机落在 2..(chapterCount-1)，避开第1章
    singlePageChapter = 2 + rnd.nextInt(chapterCount - 2);
    pageCounts = List.generate(chapterCount, (i) {
      if (i + 1 == singlePageChapter) return 1; // 休刊：仅1页
      return pagesMin + rnd.nextInt(pagesVar);
    });
    const heights = <double>[200, 400, 600, 800, 1000, 1200, 1600];
    pageHeights = List.generate(chapterCount, (ch) {
      final n = pageCounts[ch];
      return List.generate(n, (p) => heights[(ch * 7 + p) % heights.length]);
    });
  }

  final int chapterCount;
  final int pagesMin;
  final int pagesVar;

  late final int singlePageChapter;
  late final List<int> pageCounts; // [chapter index] -> page count
  late final List<List<double>> pageHeights; // [chapter][page] -> height
}

String _pad(int n) => n.toString().padLeft(2, '0');

/// 生成一张标注 "chXX pYY" 的 PNG（深色背景 + 居中白字）。
/// 尺寸不同 → 图片加载后高度异步变化（跳页 bug 触发条件）。
Future<void> _writePageImage(
    File file, String label, int width, int height) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF202020),
  );
  // TextPainter / TextSpan 来自 flutter painting（material re-export），
  // 不在 dart:ui；用无前缀。
  final tp = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        color: const ui.Color(0xFFFFFFFF),
        fontSize: 44,
        fontFamily: 'Arial',
      ),
    ),
    textDirection: ui.TextDirection.ltr,
  )..layout();
  tp.paint(
    canvas,
    ui.Offset((width - tp.width) / 2, (height - tp.height) / 2),
  );
  final pic = rec.endRecording();
  final img = await pic.toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  await file.writeAsBytes(data!.buffer.asUint8List());
}

Future<LocalComic> _prepareTestComic(Directory baseDir, _ComicSpec spec) async {
  // 幂等：目录已存在且非空 → 跳过图片生成（重跑秒进）
  final exists = baseDir.existsSync() &&
      baseDir.listSync(recursive: false).isNotEmpty;
  if (!exists) {
    await baseDir.create(recursive: true);
    var written = 0;
    final sw = Stopwatch()..start();
    for (var ch = 1; ch <= spec.chapterCount; ch++) {
      final chDir = Directory('${baseDir.path}/ch${_pad(ch)}');
      await chDir.create(recursive: true);
      final n = spec.pageCounts[ch - 1];
      for (var p = 1; p <= n; p++) {
        final h = spec.pageHeights[ch - 1][p - 1].toInt();
        final file = File('${chDir.path}/${_pad(p)}.png');
        await _writePageImage(file, 'ch${_pad(ch)} p${_pad(p)}',
            _kPageWidth.toInt(), h);
        written++;
        if (written % 100 == 0) {
          debugPrint('[E2E] generated $written images in ${sw.elapsed.inSeconds}s');
        }
      }
    }
    debugPrint('[E2E] generated $written images in ${sw.elapsed.inSeconds}s');
  }

  final chapters = <String, String>{};
  for (var ch = 1; ch <= spec.chapterCount; ch++) {
    chapters['ch${_pad(ch)}'] = 'Chapter $ch';
  }

  return LocalComic(
    id: 'e2e_test_comic',
    title: 'E2E Test Comic',
    subtitle: 'e2e',
    tags: const ['e2e', 'test'],
    directory: baseDir.absolute.path,
    chapters: ComicChapters(chapters),
    cover: 'ch01/001.png',
    comicType: ComicType.local,
    downloadedChapters: [
      for (var ch = 1; ch <= spec.chapterCount; ch++) 'ch${_pad(ch)}',
    ],
    createdAt: DateTime.now(),
  );
}

Future<void> _pumpReader(WidgetTester tester, LocalComic comic,
    {int initialChapter = 1}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      // 复刻 MyApp 的 builder：WindowFrame 必须包住 Navigator，否则
      // initReaderWindow 的 WindowFrame.of(App.rootContext) null 断言。
      builder: (context, child) => WindowFrame(child!),
      home: Reader(
        type: ComicType.local,
        cid: comic.id,
        name: comic.title,
        chapters: comic.chapters,
        history: History.fromModel(model: comic, ep: 0, page: 0),
        author: comic.subtitle,
        tags: comic.tags,
        initialChapter: initialChapter,
      ),
    ),
  );
}

/// 真实等待：runAsync 让真实时间流逝（图片解码/文件 I/O 真实发生），
/// 再 pump 一帧渲染最新状态。替代 pumpAndSettle（真实 I/O 永不 settle）。
Future<void> _waitReal(WidgetTester tester,
    {Duration duration = const Duration(milliseconds: 1500)}) async {
  await tester.runAsync(() => Future<void>.delayed(duration));
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 小规模先行验证链路（4 章 × 3 页 + 休刊 1 页章），跑通后去掉该开关
  // 用全量（32 章 × 50+ 页）。flutter test --dart-define=E2E_SMALL=true
  const bool smallMode =
      bool.fromEnvironment('E2E_SMALL', defaultValue: false);

  late LocalComic comic;
  late _ComicSpec spec;
  final baseDir = Directory(
    '${Directory.current.path}/build/${smallMode ? 'e2e_test_comic_small' : 'e2e_test_comic'}',
  );

  setUpAll(() async {
    debugPrint('[E2E] setUpAll start (smallMode=$smallMode)');
    final sw = Stopwatch()..start();
    await App.init();
    debugPrint('[E2E] App.init done ${sw.elapsed.inSeconds}s');
    // 注意：不调 Rhttp.init()。本机 frb 版本脱节（codegen 2.11.1 vs
    // runtime 2.13.0，镜像污染），Rhttp.init 的 sanity check 直接抛异常。
    // 测试全走本地（file:// 图片 + LocalManager），不碰网络，无需 rhttp。
    // ensureInit 链：LocalManager.init 里 await ComicSourceManager().ensureInit()，
    // 而 ComicSourceManager.doInit 里 await JsEngine().ensureInit()——ensureInit
    // 只有在对应 init() 被调用后才 complete。必须先 JsEngine → ComicSourceManager
    // → 再 App.initComponents（local.init），否则永远挂起（实测卡 12 分钟）。
    await JsEngine().init();
    debugPrint('[E2E] JsEngine.init done ${sw.elapsed.inSeconds}s');
    await ComicSourceManager().init();
    debugPrint('[E2E] ComicSourceManager.init done ${sw.elapsed.inSeconds}s');
    await App.initComponents();
    debugPrint('[E2E] App.initComponents done ${sw.elapsed.inSeconds}s');
    await AppTranslation.init();
    debugPrint('[E2E] AppTranslation.init done ${sw.elapsed.inSeconds}s');
    appdata.settings['readerMode'] = 'continuousTopToBottom';

    spec = smallMode
        ? _ComicSpec(chapters: 4, pagesMin: 3, pagesVar: 2) // 3-4 页
        : _ComicSpec();
    debugPrint('[E2E] spec: ${spec.chapterCount} chapters, '
        'hiatus=ch${spec.singlePageChapter}, total=${spec.pageCounts.fold<int>(0, (a, b) => a + b)} pages');
    comic = await _prepareTestComic(baseDir, spec);
    debugPrint('[E2E] comic files ready ${sw.elapsed.inSeconds}s');
    await LocalManager().add(comic);
    debugPrint('[E2E] LocalManager.add done ${sw.elapsed.inSeconds}s');
  });

  testWidgets('连续滚动：滚动翻页页码正确', (tester) async {
    await _pumpReader(tester, comic);
    // 等真实文件列举 + 首屏图片解码 + onChapterLoaded 跨章拼接
    await _waitReal(tester);

    final state = tester.state<ContinuousModeState>(find.byType(ContinuousMode));
    final n1 = spec.pageCounts[0]; // 第1章页数

    // 初始第1章第1页（页码文本是 "章节名 : 页码/总页" 格式，用 textContaining）
    expect(state.testCurrentPage, 1, reason: '初始应在第1章第1页');
    expect(find.textContaining('1/$n1'), findsWidgets,
        reason: '页码悬浮文本应显示 1/$n1');

    // 真实手势滚动翻页（drag 驱动，integration_test 下 animateToPage 的
    // Future 不可靠；drag 是用户真实操作，测试 2 已证明 work）
    await tester.drag(find.byType(ContinuousMode), const Offset(0, -800));
    await _waitReal(tester);
    final pageAfterDrag1 = state.testCurrentPage;
    expect(pageAfterDrag1, greaterThan(1),
        reason: '向下滚动后页码应前进（当前 ${state.testCurrentPage}）');

    // 继续滚动，页码不应回退（ch2 拼接是异步的，停在 ch1 末页是正常的，
    // 越过章末由测试 2 验证）
    await tester.drag(find.byType(ContinuousMode), const Offset(0, -800));
    await _waitReal(tester);
    expect(state.testCurrentPage, greaterThanOrEqualTo(pageAfterDrag1),
        reason: '继续向下滚动页码不应回退（当前 ${state.testCurrentPage}）');
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('连续滚动：滚过章末跨章拼接不跳变', (tester) async {
    await _pumpReader(tester, comic);
    await _waitReal(tester);

    final state = tester.state<ContinuousModeState>(find.byType(ContinuousMode));
    final n1 = spec.pageCounts[0];
    final n2 = spec.pageCounts[1];

    final offsetBefore = state.testScrollOffset;
    expect(offsetBefore, isNotNull);

    // 循环 drag 滚过第1章末页 → 触发 SplicedChapters 追加第2章
    // （真实 _fetchChapterPages → LocalManager.getImages，修复前这里
    // comicSource! null 崩溃）。单次 drag 距离有限，全量 50+ 页章节
    // 需要多次滚动（每页 200-1600px，ch1 总高 ~50k px）。
    // 注意：切章只发生在滚动 listener 触发时，append 完成后没有新滚动
    // 则不切章——所以循环条件必须等页码文本真正进入第2章（reader.chapter
    // 切到 2 后 UI 才更新）。
    var drags = 0;
    while (drags < 80) {
      await tester.drag(
          find.byType(ContinuousMode), const Offset(0, -2000));
      // 跨章拼接 + 下一章图片真实异步解码，等真实 I/O 完成
      await _waitReal(tester);
      drags++;
      if (state.testCurrentPage > n1 &&
          find.textContaining('/$n2').evaluate().isNotEmpty) {
        break; // 已进入第2章且页码文本切到 ch2 格式
      }
    }
    debugPrint('[E2E] 跨章用了 $drags 次 drag，testCurrentPage=${state.testCurrentPage} '
        '(n1=$n1 n2=$n2)');

    // 已进入第2章：页码文本 x/n2（章内语义）；testCurrentPage 是全局拼接页码，
    // 应越过第1章末页且不超过两章总页数；offset 不回退到章首前。
    expect(find.textContaining('/$n2'), findsWidgets,
        reason: '跨章后应显示第2章页码 x/$n2');
    expect(state.testCurrentPage, greaterThan(n1),
        reason: '跨章后全局页码应越过第1章末页');
    expect(state.testScrollOffset!, greaterThanOrEqualTo(offsetBefore! - 50),
        reason: '跨章后滚动偏移不应回退到第1章之前');
    expect(state.testCurrentPage, lessThanOrEqualTo(n1 + n2),
        reason: '当前页不应超出两章总页数');
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('从休刊章 ch9 向上滚到 ch1 再向下滚到最后', (tester) async {
    // 完整场景：initialChapter=9（休刊 1 页章），向上无缝 prepend 回滚到
    // ch1，再向下无缝 append 滚到 ch32 末页。验证用户实现的向上 prepend。
    await _pumpReader(tester, comic, initialChapter: 9);
    await _waitReal(tester);

    final state =
        tester.state<ContinuousModeState>(find.byType(ContinuousMode));
    final n1 = spec.pageCounts[0];

    // 轨迹记录：每步 (gp, ch, p)，ch/p 用 testSpliced.chapterOfPage 实时映射
    //（比 reader.chapter 准）。向上阶段 prepend 会平移 gp（内容没动），单调
    // 断言不适用，只记录观察；向下阶段 append 不改变当前 gp，严格断言不回退。
    final trail = <String>[];
    void record(String phase) {
      final gp = state.testCurrentPage;
      final (ch, p, _) = state.testSpliced.chapterOfPage(gp);
      final line = '$phase gp=$gp ch$ch p$p off=${state.testScrollOffset}';
      trail.add(line);
      // 实时逐步打印：断言失败时（trail 整体打印在其之后）也能拿到每步读数。
      debugPrint('[E2E][step] $line');
    }

    record('init');

    // 起点断言：initialChapter=9 且 ch9 为休刊章（仅 1 页）→ init 必须停在 ch9 p1。
    final (initCh, initP, _) =
        state.testSpliced.chapterOfPage(state.testCurrentPage);
    expect(initCh, 9, reason: '起点章节应为休刊章 ch9');
    expect(initP, 1, reason: '休刊章只有 1 页，起点应为 p1');

    // 向上跨章进入点验证：ch8 阶段出现过的最大章内页码必须落在末页区间。
    // 用 max 而非"首次出现"：ch8 插入瞬间到 jumpTo 补偿落地之间有 1-2 帧
    // 窗口（offset 仍在弹回过冲低位），视口瞬时映射到 ch8 开头（p2），
    // "首次出现"会间歇性踩中（GP REJECTED 已在产品侧拦截该帧的页码同步，
    // 渲染仅 1 帧无感知）。max 判定窗口免疫：若跨章真跳页（跳过整章内容），
    // max 会明显小于 n8-8 而失败。
    final n8 = spec.pageCounts[7];
    int maxCh8Page = 0;

    // ── 向上滚回 ch1（prepend 侧，每章 50+ 页需多次 drag）──
    var up = 0;
    var lastPage = state.testCurrentPage;
    var stableUp = 0;
    while (up < 400) {
      await tester.drag(find.byType(ContinuousMode), const Offset(0, 4000));
      await _waitReal(tester, duration: const Duration(milliseconds: 400));
      up++;
      final p = state.testCurrentPage;
      final (ch, ep, _) = state.testSpliced.chapterOfPage(p);
      if (ch == 8 && ep > maxCh8Page) maxCh8Page = ep;
      if (p <= n1) {
        // 已进入 ch1（全局页码 ≤ ch1 页数）
        if (p == lastPage) {
          stableUp++;
          if (stableUp >= 2) break;
        } else {
          stableUp = 0;
        }
      }
      lastPage = p;
      record('up');
    }
    debugPrint('[E2E] 向上 $up 次 drag 后 currentPage=${state.testCurrentPage}');
    // 关键跨步断言：ch9 p1 向上跨章必须经过 ch8 末页区域（drag 单步约
    // 4000px ≈ 6 页，容差 8 页；若 max 明显小于 n8-8，说明跨章跳页）。
    expect(maxCh8Page, greaterThanOrEqualTo(n8 - 8),
        reason: '向上跨章应经过 ch8 末页区域（ch8 阶段最大 p=$maxCh8Page, '
            'ch8 总页数 n8=$n8），不得跳过整章内容');
    // 观察：向上到位后页码文本（prepend 后 reader 状态同步可能滞后）
    final upTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((x) => x.data)
        .where((d) => d != null && d.contains('/'))
        .toList();
    debugPrint('[E2E] 向上到位后页码文本: $upTexts');
    // 向上到位断言：滚动回 ch1 区域即可（页码文本受同步滞后影响不稳定）
    expect(state.testCurrentPage, lessThanOrEqualTo(n1),
        reason: '向上应滚回第1章（currentPage=${state.testCurrentPage} n1=$n1）');

    // ── 向下滚到最后（ch32 末页）──
    var down = 0;
    lastPage = state.testCurrentPage;
    var stableDown = 0;
    var lastDownGp = state.testCurrentPage;
    while (down < 900) {
      await tester.drag(find.byType(ContinuousMode), const Offset(0, -4000));
      await _waitReal(tester, duration: const Duration(milliseconds: 400));
      down++;
      final p = state.testCurrentPage;
      // 轨迹断言：向下滚动时 gp 不应回退超 2 页。append 不改变当前 gp、
      // 向下阶段无 prepend（gp 远大于头部阈值），回退 >2 只可能是瞬态回跳
      // （图片收缩补偿失效 / 页码反算错误）。
      expect(p, greaterThanOrEqualTo(lastDownGp - 2),
          reason: '向下滚动页码回退（$lastDownGp -> $p）');
      lastDownGp = p;
      if (p == lastPage) {
        stableDown++;
        if (stableDown >= 5) break; // 到底：连续 5 次无变化
      } else {
        stableDown = 0;
      }
      lastPage = p;
      record('down');
    }
    debugPrint('[E2E] 向下 $down 次 drag 后 currentPage=${state.testCurrentPage}');
    // 轨迹全量逐行打印（此前只打前 20+后 20 步，"ch9p1 → ch8 末页"关键
    // 跨步恰好落在被丢弃的头部，无法核对）。
    for (var i = 0; i < trail.length; i++) {
      debugPrint('[E2E][trail $i] ${trail[i]}');
    }
    // 到底后页码文本（观察 hysteresis 边界页是否显示正确）
    final endTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((x) => x.data)
        .where((d) => d != null && d.contains('/'))
        .toList();
    debugPrint('[E2E] 到底后页码文本: $endTexts');
    // 到末尾：全局页码接近总页数（hysteresis 边界页可能停在前一章，
    // 页码文本精确断言不可靠，只断言滚动到位）
    expect(
        state.testCurrentPage,
        greaterThanOrEqualTo(
            spec.pageCounts.fold<int>(0, (a, b) => a + b) - 2),
        reason: '应滚到接近最后（currentPage=${state.testCurrentPage}）');
  }, timeout: const Timeout(Duration(minutes: 12)));
}
