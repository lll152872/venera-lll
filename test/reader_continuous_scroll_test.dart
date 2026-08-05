import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:venera/foundation/comic_type.dart';
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
/// at placeholder height (viewport 600). After [gCompleter] completes, all
/// built pages fire onImageLoaded at once and shrink to 400 (1x1 image scaled
/// to fit width 400) — emulating the production race "image finishes loading
/// while the user is scrolled mid-chapter" without any real I/O.
final Completer<void> gCompleter = Completer<void>();

/// Test-only image provider whose completion is gated by [gCompleter].
/// A unique instance per page index avoids ImageCache sync-completion paths
/// (production network images never complete synchronously, so ComicImage
/// must not be fed a cache-hit during build — that triggers setState-during-
/// build).
class _GatedImageProvider extends ImageProvider<_GatedImageProvider> {
  _GatedImageProvider(this.index);

  final int index;

  @override
  Future<_GatedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_GatedImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
      _GatedImageProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(
      gCompleter.future.then((_) => ImageInfo(image: gImage!)),
    );
  }
}

/// Minimal [ReaderView] fake: 1 chapter of 20 pages, vertical continuous
/// mode. All [dbg] output is collected into [logs].
class _FakeReader implements ReaderView {
  _FakeReader({required this.logs});

  final List<String> logs;

  late final List<String> _images =
      List<String>.generate(20, (i) => 'page_$i');

  @override
  Iterable<String>? get chapterIds => ['eid_0'];

  @override
  ComicType get type => ComicType.local;

  @override
  String get cid => 'test_comic';

  @override
  List<String>? get images => _images;

  @override
  set images(List<String>? value) {
    // Chapter switch re-assigns images; single-chapter test ignores it.
  }

  @override
  int chapter = 1;

  @override
  int page = 1;

  @override
  void setPage(int page) => this.page = page;

  @override
  ReaderMode get mode => ReaderMode.continuousTopToBottom;

  @override
  Size get size => const Size(400, 600);

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
    // ComicImage can hit the error/retry branch (uses "Retry".tl), which
    // requires the translation table that App normally initializes at boot.
    await AppTranslation.init();
    gImage = await decodeImageFromList(kTransparentPng);
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
    expect(offsetBefore, greaterThan(4000), reason: 'should be mid-scroll');

    // Let all page images "finish loading" now. Each page shrinks from 600
    // (placeholder) to 400 (1x1 image scaled to fit width 400) — this used to
    // reset the scroll position to 0 on re-measure (the rollback bug).
    gCompleter.complete();
    await tester.pump();

    final offsetAfter = state.testScrollOffset!;
    // Core regression assertion: height changes above/below must not roll the
    // position back to the start.
    expect(offsetAfter, greaterThanOrEqualTo(offsetBefore - 50),
        reason: 'scroll must not jump back after image load');
    expect(offsetAfter, greaterThan(4000), reason: 'must stay mid-scroll');
    expect(state.testCurrentPage, greaterThan(3),
        reason: 'page must not roll back to the beginning');
    expect(logs.where((l) => l.contains('GP JUMP')), isEmpty,
        reason: 'no rollback-detector alert expected');

    // Drain pending timers (init-cache delay 100ms, scrolling-flag 300ms).
    await tester.pump(const Duration(milliseconds: 400));
  });
}
