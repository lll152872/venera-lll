// 目的：锁住「点第 N 页 → 精确落在第 N 页」。
//
// 背景：连续滚动里每页高度 = 图片高宽比 × 显示宽，而跳转偏移是**逐页累加
// 高度**算出来的。页高有三种来源：
//   1. 探测结果（读图片文件头拿到的真实宽高）
//   2. 图片解码后的真实高度
//   3. 占位高（视口高，纯估算值）
// 三者不一致时，落点就会偏几页到几十页（实测短横页偏 37 页、长条页偏 13 页）。
//
// 本测试覆盖：
//   1. 页高全部已知（= 探测已完成）→ 跳到第 30 页必须精确落在第 30 页
//   2. 页高未知 → 降级不崩，且「页码 == 实际落点」保持自洽
//
// 测试用 50 页、4 种长宽比交替（0.5 / 1.5 / 4.0 / 1.0），页高差异大到
// 占位高（600）几乎必然算错——占位高算出来的偏移和真实偏移差几千像素。

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_size_cache.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

/// 页面数量。
const int kPageCount = 50;

/// 目标页（1-based）。
const int kTargetPage = 30;

/// 阅读器视口尺寸（与 [ContinuousMode] 的 PhotoView 包装一致）。
const Size kViewport = Size(400, 600);

/// 每页的「原图像素宽高」。宽固定 100，高决定长宽比：
/// 0.5 / 1.5 / 4.0 / 1.0 交替 → 显示高 200 / 600 / 1600 / 400（显示宽 400）。
const List<(int, int)> kPixelSizes = [
  (100, 50),
  (100, 150),
  (100, 400),
  (100, 100),
];

/// 第 index 页（0-based）的原图像素尺寸。
(int, int) pixelSizeOf(int index) => kPixelSizes[index % kPixelSizes.length];

/// 第 index 页（0-based）的显示高度 = 显示宽 × 高宽比。
double displayHeightOf(int index) {
  final (w, h) = pixelSizeOf(index);
  return kViewport.width * h / w;
}

/// 各页对应的 ui.Image（按 [pixelSizeOf] 复用 4 张）。
final Map<(int, int), ui.Image> _images = {};

/// 生成一张指定尺寸的纯色图片（只用来提供真实的宽高）。
Future<ui.Image> makeImage(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF202020),
  );
  return recorder.endRecording().toImage(w, h);
}

/// 每页一个 provider 实例：避免 ImageCache 同步命中路径
/// （生产环境的网络图片不会同步完成，命中缓存会在 build 期间触发
/// setState-during-build）。
class _SizedImageProvider extends ImageProvider<_SizedImageProvider> {
  _SizedImageProvider(this.index, this.image);

  final int index;
  final ui.Image image;

  @override
  Future<_SizedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_SizedImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _SizedImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      Future<ImageInfo>.value(ImageInfo(image: image)),
    );
  }
}

/// 最小 [ReaderView] fake：单章 50 页。
class _FakeReader implements ReaderView {
  _FakeReader({required this.logs});

  final List<String> logs;

  @override
  Iterable<String>? get chapterIds => const ['eid_0'];

  @override
  ComicType get type => ComicType.local;

  @override
  String get cid => 'test_comic';

  @override
  int chapter = 1;

  @override
  int page = 1;

  @override
  List<String>? get images =>
      List.generate(kPageCount, (i) => 'p$i');

  @override
  set images(List<String>? value) {}

  @override
  void setPage(int page) => this.page = page;

  @override
  ReaderMode get mode => ReaderMode.continuousTopToBottom;

  @override
  Size get size => kViewport;

  @override
  bool get isLoading => false;

  @override
  int get maxChapter => 1;

  @override
  void dbg(String s) => logs.add(s);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ComicImage 的错误分支用 "Retry".tl，需要 App 启动时初始化的翻译表。
    await AppTranslation.init();
    for (final size in kPixelSizes) {
      _images[size] = await makeImage(size.$1, size.$2);
    }
  });

  setUp(() async {
    // 隔离各用例：清掉上一个用例写进 ImageSizeCache 的尺寸。
    await ImageSizeCache.instance.clear();
  });

  tearDown(() async {
    // put() 会挂一个 2 秒 debounce 落盘定时器，不清掉会让用例以
    // "A Timer is still pending" 失败。
    await ImageSizeCache.instance.clear();
  });

  /// 把 [ContinuousMode] 泵起来，返回它的 state。
  Future<ContinuousModeState> pumpReader(
    WidgetTester tester, {
    required List<String> logs,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContinuousMode(
            readerOverride: _FakeReader(logs: logs),
            imageProviderFactory: (key, index) => _SizedImageProvider(
              index,
              _images[pixelSizeOf(index - 1)]!,
            ),
            debugLog: logs.add,
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.state<ContinuousModeState>(find.byType(ContinuousMode));
  }

  testWidgets(
      '页高已知（探测已完成）：跳到第 $kTargetPage 页必须精确落在第 $kTargetPage 页',
      (tester) async {
    final logs = <String>[];

    // 模拟「探测已完成」：每页的真实像素尺寸都已在 ImageSizeCache 里。
    for (var i = 0; i < kPageCount; i++) {
      final (w, h) = pixelSizeOf(i);
      ImageSizeCache.instance.putForTest('p$i', w, h);
    }

    final state = await pumpReader(tester, logs: logs);
    // 让图片解码完成、布局稳定。
    await tester.pump();
    await tester.pump();

    // 期望落点：第 kTargetPage 页顶 = 前 kTargetPage-1 页显示高之和。
    var expectedOffset = 0.0;
    for (var i = 0; i < kTargetPage - 1; i++) {
      expectedOffset += displayHeightOf(i);
    }

    state.toPage(kTargetPage);
    await tester.pump();
    // 落点校正循环每轮等一帧，最多 3 轮 → 多泵几帧让它跑完。
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(
      state.testCurrentPage,
      kTargetPage,
      reason: '落点必须在第 $kTargetPage 页（页高已知时偏移是精确的）。'
          'logs: ${logs.where((l) => l.contains("align") || l.contains("probe"))}',
    );
    expect(
      state.testScrollOffset,
      closeTo(expectedOffset, 2),
      reason: '滚动偏移必须等于第 $kTargetPage 页的真实顶部像素',
    );
    // 滚动会挂一个 300ms 的「正在滚动」标志定时器（delayedSetIsScrolling），
    // 不等它落地用例会以 "A Timer is still pending" 失败。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('页高未知：降级不崩，且页码与实际落点自洽', (tester) async {
    final logs = <String>[];
    final state = await pumpReader(tester, logs: logs);
    await tester.pump();
    await tester.pump();

    state.toPage(kTargetPage);
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    // 页高未知时落点必然有偏差（占位高不是真实高），但必须：
    // 1) 不抛异常；
    // 2) 页码仍然是「视口里实际看到的那一页」（自洽，不悬空）。
    final landed = state.testCurrentPage;
    expect(landed, inInclusiveRange(1, kPageCount));
    expect(state.testScrollOffset, isNotNull);
    // 同步器读到的页码必须和视口实际落点一致（不能停在请求页上）。
    final synced = logs
        .where((l) => l.contains('_syncReaderState gp='))
        .map((l) => int.parse(RegExp(r'gp=(\d+)').firstMatch(l)!.group(1)!))
        .toList();
    if (synced.isNotEmpty) {
      expect(synced.last, landed,
          reason: 'reader 的页码必须与视口实际落点一致；logs: $logs');
    }
    await tester.pump(const Duration(milliseconds: 400));
  });
}
