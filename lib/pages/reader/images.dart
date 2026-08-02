part of 'reader.dart';

class _ReaderImages extends StatefulWidget {
  const _ReaderImages();

  @override
  State<_ReaderImages> createState() => _ReaderImagesState();
}

class _ReaderImagesState extends State<_ReaderImages> {
  late _ReaderState reader;

  @override
  void initState() {
    reader = context.reader;
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    ImageDownloader.cancelAllLoadingImages();
  }

  @override
  Widget build(BuildContext context) {
    if (reader.isLoading) {
      return const Center(child: CircularProgressIndicator());
    } else if (reader.error != null) {
      return GestureDetector(
        onTap: () {
          context.readerScaffold.openOrClose();
        },
        child: SizedBox.expand(
          child: NetworkError(
            message: reader.error!,
            retry: () {
              reader.changeChapter(reader.chapter);
            },
          ),
        ),
      );
    } else {
      if (reader.mode.isGallery) {
        var showComments =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true;
        var showCommentsAtEnd =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
        return _GalleryMode(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${showComments}_$showCommentsAtEnd',
          ),
        );
      } else {
        return _ContinuousMode(key: Key(reader.mode.key));
      }
    }
  }
}

class _GalleryMode extends StatefulWidget {
  const _GalleryMode({super.key});

  @override
  State<_GalleryMode> createState() => _GalleryModeState();
}

class _GalleryModeState extends State<_GalleryMode>
    implements _ImageViewController {
  late PageController controller;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  var photoViewControllers = <int, PhotoViewController>{};

  late _ReaderState reader;

  bool get showChapterCommentsAtEnd {
    if (reader.mode != ReaderMode.galleryLeftToRight &&
        reader.mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (reader.widget.chapters == null) return false;
    var source = ComicSource.find(reader.type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  int get totalImagePages {
    return !reader.showSingleImageOnFirstPage()
        ? (reader.images!.length / reader.imagesPerPage).ceil()
        : 1 + ((reader.images!.length - 1) / reader.imagesPerPage).ceil();
  }

  int get totalPages => reader.totalPages;

  bool isChapterCommentsPage(int pageIndex) {
    return showChapterCommentsAtEnd && pageIndex == totalImagePages + 1;
  }

  var imageStates = <State<ComicImage>>{};

  bool isLongPressing = false;

  int fingers = 0;

  @override
  void initState() {
    reader = context.reader;
    controller = PageController(initialPage: reader.page);
    reader._imageViewController = this;
    Future.microtask(() {
      context.readerScaffold.setFloatingButton(0);
    });
    super.initState();
  }

  /// Get the range of images for the given page. [page] is 1-based.
  (int start, int end) getPageImagesRange(int page) {
    var imagesPerPage = reader.imagesPerPage;
    if (reader.showSingleImageOnFirstPage()) {
      if (page == 1) {
        return (0, 1);
      } else {
        int startIndex = (page - 2) * imagesPerPage + 1;
        int endIndex = math.min(
          startIndex + imagesPerPage,
          reader.images!.length,
        );
        return (startIndex, endIndex);
      }
    } else {
      int startIndex = (page - 1) * imagesPerPage;
      int endIndex = math.min(
        startIndex + imagesPerPage,
        reader.images!.length,
      );
      return (startIndex, endIndex);
    }
  }

  /// Get the image indices for current page. Returns null if no images.
  /// Returns a single index if only one image, or a range if multiple images.
  (int, int)? getCurrentPageImageRange() {
    if (reader.images == null || reader.images!.isEmpty) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(reader.page);
    return (startIndex, endIndex);
  }

  void cache(int startPage) {
    for (int i = startPage - 1; i <= startPage + preCacheCount; i++) {
      if (i == startPage ||
          i <= 0 ||
          i > totalPages ||
          isChapterCommentsPage(i)) {
        continue;
      }
      _cachePage(i, i == startPage + 1 || i == startPage - 1);
    }
  }

  void _cachePage(int page, bool shouldPreCache) {
    if (isChapterCommentsPage(page)) return;
    var (startIndex, endIndex) = getPageImagesRange(page);
    for (int i = startIndex; i < endIndex; i++) {
      shouldPreCache
          ? _precacheImage(i + 1, context)
          : _preDownloadImage(i + 1, context);
    }
  }

  Widget _buildChapterCommentsPage() {
    var source = ComicSource.find(reader.type.sourceKey);
    var chapters = reader.widget.chapters;
    if (source == null || chapters == null) return const SizedBox();
    var chapterIndex = reader.chapter - 1;
    return _EmbeddedChapterCommentsPage(
      comicId: reader.cid,
      epId: chapters.ids.elementAt(chapterIndex),
      source: source,
      comicTitle: reader.widget.name,
      chapterTitle: chapters.titles.elementAt(chapterIndex),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        fingers++;
      },
      onPointerUp: (event) {
        fingers--;
      },
      onPointerCancel: (event) {
        fingers--;
      },
      onPointerMove: (event) {
        if (isLongPressing) {
          var controller = photoViewControllers[reader.page]!;
          Offset value = event.delta;
          if (isLongPressing) {
            controller.updateMultiple(position: controller.position + value);
          }
        }
      },
      child: PhotoViewGallery.builder(
        backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
        reverse: reader.mode == ReaderMode.galleryRightToLeft,
        scrollDirection: reader.mode == ReaderMode.galleryTopToBottom
            ? Axis.vertical
            : Axis.horizontal,
        itemCount: totalPages + 2,
        builder: (BuildContext context, int index) {
          if (index == 0 || index == totalPages + 1) {
            return PhotoViewGalleryPageOptions.customChild(
              child: const SizedBox(),
            );
          } else if (isChapterCommentsPage(index)) {
            return PhotoViewGalleryPageOptions.customChild(
              child: _buildChapterCommentsPage(),
            );
          } else {
            var (startIndex, endIndex) = getPageImagesRange(index);
            List<String> pageImages = reader.images!.sublist(
              startIndex,
              endIndex,
            );

            cache(index);

            photoViewControllers[index] ??= PhotoViewController();

            if (reader.imagesPerPage == 1 || pageImages.length == 1) {
              return PhotoViewGalleryPageOptions(
                filterQuality: FilterQuality.medium,
                controller: photoViewControllers[index],
                imageProvider: _createImageProviderFromKey(
                  pageImages[0],
                  context,
                  startIndex + 1,
                ),
                fit: BoxFit.contain,
                errorBuilder: (_, error, s, retry) {
                  return NetworkError(message: error.toString(), retry: retry);
                },
              );
            }

            final viewportSize = MediaQuery.of(context).size;
            return PhotoViewGalleryPageOptions.customChild(
              childSize: viewportSize,
              controller: photoViewControllers[index],
              minScale: PhotoViewComputedScale.contained * 1.0,
              maxScale: PhotoViewComputedScale.covered * 10.0,
              child: buildPageImages(pageImages, startIndex),
            );
          }
        },
        pageController: controller,
        loadingBuilder: (context, event) {
          return PhotoView.customChild(
            childSize: MediaQuery.of(context).size,
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained * 1.0,
            maxScale: PhotoViewComputedScale.covered * 10.0,
            backgroundDecoration: BoxDecoration(
              color: context.colorScheme.surface,
            ),
            child: Center(
              child: SizedBox(
                width: 20.0,
                height: 20.0,
                child: CircularProgressIndicator(
                  backgroundColor: context.colorScheme.surfaceContainerHigh,
                  value: event == null || event.expectedTotalBytes == null
                      ? null
                      : event.cumulativeBytesLoaded / event.expectedTotalBytes!,
                ),
              ),
            ),
          );
        },
        onPageChanged: (i) {
          if (i == 0) {
            if (reader.isFirstChapterOfGroup || !reader.toPrevChapter(toLastPage: true)) {
              controller.jumpToPage(1);
            }
          } else if (i == totalPages + 1) {
            if (reader.isLastChapterOfGroup || !reader.toNextChapter()) {
              controller.jumpToPage(totalPages);
            }
          } else {
            reader.setPage(i);
            context.readerScaffold.update();
            // Auto close toolbar when entering chapter comments page
            if (isChapterCommentsPage(i) && context.readerScaffold.isOpen) {
              context.readerScaffold.openOrClose();
            }
          }
          // Remove other pages' controllers to reset their state.
          var keys = photoViewControllers.keys.toList();
          for (var key in keys) {
            if (key != i) {
              photoViewControllers.remove(key);
            }
          }
        },
      ),
    );
  }

  Widget buildPageImages(List<String> images, int startIndex) {
    Axis axis = (reader.mode == ReaderMode.galleryTopToBottom)
        ? Axis.vertical
        : Axis.horizontal;

    bool reverse = reader.mode == ReaderMode.galleryRightToLeft;
    if (reverse) {
      images = images.reversed.toList();
    }

    List<Widget> imageWidgets;

    if (images.length == 2) {
      imageWidgets = [
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              images[0],
              context,
              startIndex + 1,
            ),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.bottomCenter
                : Alignment.centerRight,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              images[1],
              context,
              startIndex + 2,
            ),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
      ];
    } else {
      imageWidgets = images.map((imageKey) {
        startIndex++;
        ImageProvider imageProvider = _createImageProviderFromKey(
          imageKey,
          context,
          startIndex,
        );
        return Expanded(
          child: ComicImage(
            image: imageProvider,
            fit: BoxFit.contain,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        );
      }).toList();
    }

    return axis == Axis.vertical
        ? Column(children: imageWidgets)
        : Row(children: imageWidgets);
  }

  @override
  Future<void> animateToPage(int page) {
    if ((page - controller.page!.round()).abs() > 1) {
      controller.jumpToPage(page > controller.page! ? page - 1 : page + 1);
    }
    return controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void toPage(int page) {
    controller.jumpToPage(page);
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    var controller = photoViewControllers[reader.page]!;
    controller.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || fingers != 1) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || !isLongPressing) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    isLongPressing = false;
  }

  Timer? keyRepeatTimer;

  @override
  void handleKeyEvent(KeyEvent event) {
    bool? forward;
    if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (event is KeyDownEvent) {
      if (keyRepeatTimer != null) {
        keyRepeatTimer!.cancel();
        keyRepeatTimer = null;
      }
      if (forward == true) {
        reader.toPage(reader.page + 1);
      } else if (forward == false) {
        reader.toPage(reader.page - 1);
      }
    }
    if (event is KeyRepeatEvent && keyRepeatTimer == null) {
      keyRepeatTimer = Timer.periodic(
        reader.enablePageAnimation(reader.cid, reader.type)
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 50),
        (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          } else if (forward == true) {
            reader.toPage(reader.page + 1);
          } else if (forward == false) {
            reader.toPage(reader.page - 1);
          }
        },
      );
    }
    if (event is KeyUpEvent && keyRepeatTimer != null) {
      keyRepeatTimer!.cancel();
      keyRepeatTimer = null;
    }
  }

  @override
  bool handleOnTap(Offset location) {
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      return (await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      ))!.readAsBytes();
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    var range = getCurrentPageImageRange();
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return reader.images![startIndex];
    }

    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        var imageKey =
            (imageState.widget.image as ReaderImageProvider).imageKey;
        int index = reader.images!.indexOf(imageKey);
        if (index >= startIndex && index < endIndex) {
          return imageKey;
        }
      }
    }

    return reader.images![startIndex];
  }

  @override
  void onChapterLoaded() {
    // Gallery mode: jump the page controller to the target page after reload.
    if (mounted) controller.jumpToPage(reader.page);
  }
}

/// Manages the cross-chapter seamless scrolling data model.
///
/// Holds the spliced image list and chapter offset/length metadata.
/// _ContinuousModeState delegates all data access here, keeping UI logic
/// separate from chapter splicing logic.
class SplicedChapters {
  List<String> images = [];
  List<int> _offsets = [];
  List<int> _chapNums = [];
  List<int> _chapLens = [];

  bool appendingNext = false;
  bool prependingPrev = false;
  bool allNextLoaded = false;
  bool allPrevLoaded = false;

  static const int kPreloadAhead = 10;
  static const int kMaxChaptersInMemory = 10;

  int get length => images.length;
  int get chapterCount => _chapNums.length;

  String operator [](int index) => images[index];

  void reset(List<String> initialImages, int chapterNum) {
    images = List.from(initialImages);
    _offsets = [0];
    _chapNums = [chapterNum];
    _chapLens = [initialImages.length];
    appendingNext = false;
    prependingPrev = false;
    allNextLoaded = false;
    allPrevLoaded = false;
  }

  /// Returns (chapterNum, localPage, chapterLen) for the given global page.
  (int chapter, int localPage, int len) chapterOfPage(int gp) {
    // 严格大于：边界 gp 归前一章（legado 式 [i] < x <= [i+1]）。
    // 例如 ch48 占 gp [11,21]，offset=11；ch49 offset=22。
    // gp=21 -> 21>11 且 21 不大于 22 -> ch48（正确，ch48 最后一页）。
    // gp=22 -> 22>22 否，进入 i-1 检查 -> ch49（ch49 第一页）。
    for (int i = _offsets.length - 1; i >= 0; i--) {
      if (gp > _offsets[i]) {
        return (_chapNums[i], gp - _offsets[i], _chapLens[i]);
      }
    }
    return (_chapNums[0], gp, _chapLens[0]);
  }

  /// Returns the image sublist for a given chapter number.
  List<String> imagesForChapter(int chapterNum) {
    int idx = _chapNums.indexOf(chapterNum);
    if (idx < 0) return [];
    int start = _offsets[idx];
    return images.sublist(start, start + _chapLens[idx]);
  }

  /// 章节内 page(1-based) → 拼接列表的全局 gp(1-based)。
  /// 连续模式多章拼接后滚动位置是全局的，点击翻页需用全局 gp。
  int globalGpForChapterPage(int chapterNum, int page) {
    int idx = _chapNums.indexOf(chapterNum);
    if (idx < 0) return page; // 当前章不在 spliced 里，fallback
    return _offsets[idx] + page;
  }

  /// Appends the next chapter's images to the end of the spliced list.
  /// Returns the number of images added, or 0 if none.
  int append(List<String> imgs, int chapterNum) {
    _offsets.add(images.length);
    _chapNums.add(chapterNum);
    _chapLens.add(imgs.length);
    images.addAll(imgs);
    return imgs.length;
  }

  /// Prepends the previous chapter's images to the start of the spliced list.
  /// Returns the offset adjustment (number of images prepended) so the caller
  /// can fix scroll position.
  int prepend(List<String> imgs, int chapterNum) {
    int plen = imgs.length;
    images.insertAll(0, imgs);
    for (int i = 0; i < _offsets.length; i++) {
      _offsets[i] += plen;
    }
    _offsets.insert(0, 0);
    _chapNums.insert(0, chapterNum);
    _chapLens.insert(0, plen);
    return plen;
  }

  /// Unloads excess chapters from the front, keeping at most
  /// [kMaxChaptersInMemory] chapters in memory.
  /// Returns the number of images removed from the front.
  int unloadExcess() {
    if (_offsets.length <= kMaxChaptersInMemory) return 0;
    int totalRemoved = 0;
    while (_offsets.length > kMaxChaptersInMemory) {
      int removeCount = _chapLens[0];
      images.removeRange(0, removeCount);
      _offsets.removeAt(0);
      _chapNums.removeAt(0);
      _chapLens.removeAt(0);
      for (int i = 0; i < _offsets.length; i++) {
        _offsets[i] -= removeCount;
      }
      totalRemoved += removeCount;
    }
    return totalRemoved;
  }

  /// Whether the spliced list should try appending the next chapter.
  bool shouldAppendNext(int currentGp) {
    if (appendingNext || allNextLoaded) return false;
    if (images.length - currentGp > kPreloadAhead) return false;
    // 防重复：下一章若已在拼接列表中则不再 append
    int next = lastChapterNum + 1;
    if (_chapNums.contains(next)) return false;
    return true;
  }

  /// Whether the spliced list should try prepending the previous chapter.
  bool shouldPrependPrev(int currentGp, bool suppressed) {
    if (suppressed || prependingPrev || allPrevLoaded) return false;
    if (currentGp > kPreloadAhead + 1) return false;
    // 防重复：前一章若已在拼接列表中则不再 prepend
    int prev = firstChapterNum - 1;
    if (prev < 1 || _chapNums.contains(prev)) return false;
    return true;
  }

  void markAppending(bool v) => appendingNext = v;
  void markPrepending(bool v) => prependingPrev = v;
  void markAllNextLoaded() => allNextLoaded = true;
  void markAllPrevLoaded() => allPrevLoaded = true;

  int get lastChapterNum => _chapNums.last;
  int get firstChapterNum => _chapNums.first;

  /// Whether a chapter number is already spliced into the list.
  bool containsChapter(int n) => _chapNums.contains(n);
}

class _ContinuousMode extends StatefulWidget {
  const _ContinuousMode({super.key});

  @override
  State<_ContinuousMode> createState() => _ContinuousModeState();
}

/// 注册 item 的 BuildContext 到父级，用于 _currentPageFromViewport 遍历可见 item。
///
/// 在 item build 时通过 [onRegister] 注册 context，dispose 时通过 [onUnregister] 注销。
/// _ContinuousModeState._itemContexts 只保留当前可见（已 build）的 item，
/// _currentPageFromViewport 遍历它找视口中心对应的 item index（=页码）。
class _ItemContextRegistrar extends StatefulWidget {
  final int index;
  final void Function(int index, BuildContext context) onRegister;
  final void Function(int index) onUnregister;
  final Widget child;

  const _ItemContextRegistrar({
    required this.index,
    required this.onRegister,
    required this.onUnregister,
    required this.child,
  });

  @override
  State<_ItemContextRegistrar> createState() => _ItemContextRegistrarState();
}

class _ItemContextRegistrarState extends State<_ItemContextRegistrar> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onRegister(widget.index, context);
  }

  @override
  void dispose() {
    widget.onUnregister(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ContinuousModeState extends State<_ContinuousMode>
    implements _ImageViewController {
  late _ReaderState reader;

  // 自有 ScrollController：完全掌控滚动位置，避免 ScrollablePositionedList
  // 在 item 重建时把 pixels 归零导致回退（legado 式：自己管滚动）。
  late final ScrollController _scrollController = ScrollController();
  var photoViewController = PhotoViewController();

  var isCTRLPressed = false;
  static var _isMouseScrolling = false;
  var fingers = 0;
  bool disableScroll = false;

  late List<bool> cached;
  int _cachedSize = 0;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  bool delayedIsScrolling = false;
  var imageStates = <State<ComicImage>>{};
  bool isZoomedIn = false;
  bool isLongPressing = false;

  /// ── Tunable constants (kept here so timing/sizing is easy to find) ──
  /// 解除 prepend 屏蔽的窗口：jumpTo 过渡帧约 2-3 帧后解除，
  /// 期间不会因过渡帧报旧 gp 而连锁触发 prepend（legado 式）。
  static const int kPrependSuppressWindowMs = 250;
  /// 滚动状态标志(用于禁双击翻页)的滞后设置窗口。
  static const int kScrollingFlagDelayMs = 300;
  /// 进入阅读器后首次预加载图片的延迟（等首帧布局完成再缓存）。
  static const int kInitCacheDelayMs = 100;
  /// cached[] 列表的缓冲余量：每次 grow 多留 16 格，减少频繁重建。
  static const int kCacheGrowthPadding = 16;

  /// ── Cross-chapter seamless scrolling data ──
  late final SplicedChapters _spliced = SplicedChapters();

  /// 恒定 GlobalKey：强制 ListView 的 element 永久复用，
  /// 避免每帧 build 时 element 销毁重建导致滚动位置(pixels)归零（回退）。
  final GlobalKey _listKey = GlobalKey();

  /// legado 式：每页 item 高度 = 图片真实显示高度（宽度撑满视口时按图片
  /// 比例算），页间固定间距 kPageSpacing。页码定位用「像素 → 累加每页高度
  /// + 间距 → 落在哪一页」，不依赖固定 itemSize（legado 用中心 item position，
  /// 同理：间距固定不影响页码判断）。
  ///
  /// _pageHeights[gp] 存每页真实显示高度（从 ComicImage 的 _cache 拿原图尺寸算）。
  /// 未加载时回退到 _placeholderPageHeight（视口高，图片出来后变真实高）。
  /// 注意：图片加载后高度变化会导致 ListView 重排，prepend/append 的 jumpTo
  /// 必须用 _offsetForGp（累加偏移）而非 gp*固定值。
  static const double kPageSpacing = 0.0; // 页间间距(dp)。legado 原版=0：图片首尾相接，零黑边零缝
  final Map<int, double> _pageHeights = {};
  double _placeholderPageHeight = 0; // 首帧占位（build 时赋视口高）

  /// 可见 item 的 BuildContext 映射（index → context）。
  /// 由 _ItemContextRegistrar 在 item build 时注册、dispose 时注销。
  /// _currentPageFromViewport 遍历它找视口中心对应的 item index（=页码），
  /// 替代 _gpFromPixels 像素累加反算，消除 _pageHeights 异步高度变化导致的页码错位。
  final Map<int, BuildContext> _itemContexts = {};

  /// 实际布局用的 cross-axis 尺寸（垂直模式=宽，水平模式=高）。
  /// 与 _placeholderPageHeight / _pageHeights 联合使用确保 item 渲染高度
  /// 和 _pageHeights 存储值源于同一宽度，消除双轨不一致导致的页间空白。
  double _layoutCrossAxis = 0;

  /// ── Download concurrency limiter ──
  /// Prevents launching too many parallel image downloads at once.
  static const int _kMaxConcurrentDownloads = 3;
  int _activeDownloads = 0;
  final List<void Function()> _downloadQueue = [];

  void _enqueueDownload(void Function() task) {
    if (_activeDownloads >= _kMaxConcurrentDownloads) {
      _downloadQueue.add(task);
    } else {
      _activeDownloads++;
      task();
    }
  }

  void _onDownloadComplete() {
    _activeDownloads--;
    if (_activeDownloads < _kMaxConcurrentDownloads && _downloadQueue.isNotEmpty) {
      _activeDownloads++;
      var task = _downloadQueue.removeAt(0);
      task();
    }
  }

  /// ── Legado-style adjacent chapter prefetch ──
  /// Stores prefetched page-URL lists for neighbor chapters so that switching
  /// to them is instant (no network wait at the boundary).
  final Map<int, List<String>> _prefetchedChapters = {};

  /// Prefetch the page list (and first few images) of [ch] in the background.
  /// Does nothing if already spliced or already prefetched.
  void _prefetchChapter(int ch) {
    if (ch < 1 || ch > reader.maxChapter) return;
    if (_spliced.containsChapter(ch)) return;
    if (_prefetchedChapters.containsKey(ch)) return;
    String eid = reader.widget.chapters?.ids.elementAtOrNull(ch - 1) ?? '';
    if (eid.isEmpty) return;
    _prefetchedChapters[ch] = const []; // mark in-flight to avoid dup
    reader.type.comicSource!.loadComicPages!(reader.cid, eid).then((res) {
      if (res.error || !mounted) return;
      _prefetchedChapters[ch] = res.data;
      // Pre-download the first few images of the prefetched chapter so that
      // switching to it is seamless (legado keeps prev/next in memory).
      int n = math.min(res.data.length, preCacheCount);
      for (int i = 0; i < n; i++) {
        var key = res.data[i];
        if (key.startsWith("file://")) continue;
        ImageDownloader.loadComicImage(
            key, reader.type.comicSource?.key, reader.cid, eid);
      }
    });
  }

  /// Prefetch both neighbors of the current spliced window's edges.
  void _prefetchNeighbors() {
    _prefetchChapter(_spliced.firstChapterNum - 1);
    _prefetchChapter(_spliced.lastChapterNum + 1);
  }

  /// ── Scroll direction aware preloading ──
  int? _lastGpForDirection;
  bool _scrollingForward = true;

  /// ── Chapter memory unloading ──
  /// Delegated to SplicedChapters.unloadExcess().
  /// cached[] markers for removed range are cleaned up here.

  /// True after a chapter jump (toChapter) or prepend to suppress prepend
  /// triggering during the jumpTo transition frames. Cleared after a fixed
  /// delay window (legado-style: no async listener reverse-calc).
  bool _suppressPrepend = false;
  void delayedSetIsScrolling(bool value) {
    Future.delayed(
      const Duration(milliseconds: kScrollingFlagDelayMs),
      () => delayedIsScrolling = value,
    );
  }

  void _resetSplicedState() {
    _spliced.reset(reader.images!, reader.chapter);
    // 关键修复：必须清空 _pageHeights，否则旧章的高度数据残留，
    // 新章页数/图片高度不同时 key 错位：
    //   - 旧章 16 页 → _pageHeights 有 key 1..16
    //   - 新章 10 页 → _spliced 重置为 10 页，但 _pageHeights[11..16] 仍是旧章数据
    //   - B1+B2 预测量只在 _pageHeights[index]==null 时填，不覆盖残留值
    //   - 用户滚到新章末尾继续到下一章(gp=11+)，_gpFromPixels 用旧章第 11 页高度算 gp
    //     → pixels 和实际渲染位置脱节 → "显示 p16 但内容到下一章"
    // 同时影响 unloadExcess：如果 _pageHeights 有残留，平移后补偿也不准。
    _pageHeights.clear();
    // 必须同步清空 _itemContexts：旧章 item 的 context 还挂在 ListView 上，
    // 若不清，_currentPageFromViewport 会用旧章 item 的渲染位置反算 gp，
    // 在新 spliced 上查错章节 → 点下一章回退到上一章。
    // 旧 State 的 dispose 仍会调 onUnregister（remove），无害。
    _itemContexts.clear();
    _lastSyncedGp = -1;
  }

  /// Syncs _ReaderState (chapter + page) from a global page position.
  /// Skips the chapter switch while a splice/jump transition is in flight
  /// (or suppressed) to avoid reverse-calculation glitches that cause jumps.
  /// Uses a boundary hysteresis: only switches chapter once the global page
  /// is clearly inside the middle of the target chapter, not on its edge.
  void _updateReaderStateForSpliced(int globalPage) {
    var (int chap, int localPage, int chapLen) = _spliced.chapterOfPage(globalPage);
    reader._dbg('[DBG] _updateReaderStateForSpliced IN gp=$globalPage -> chap=$chap localPage=$localPage chapLen=$chapLen curChapter=${reader.chapter} suppress=$_suppressPrepend append=${_spliced.appendingNext} prepend=${_spliced.prependingPrev} loading=${reader.isLoading}');
    // 拼接过渡/跳转过渡期间不更新 chapter（避免过渡帧反算错误导致回跳），
    // 只更新 page。legado 式：章节由显式切章持有，不靠 listener 反算。
    // !reader.isLoading：changeChapter 异步加载窗口期内（spliced 仍是旧章拼接、
    // _itemContexts 仍是旧章 item），反算出的 chap 是旧章，必须抑制切章，
    // 否则"点下一章 → 回退到上一章"（reader.chapter 被 listener 改回）。
    if (reader.chapter != chap &&
        !reader.isLoading &&
        !_spliced.prependingPrev &&
        !_spliced.appendingNext &&
        !_suppressPrepend) {
      // 滞后（hysteresis）：只在 gp 明确进入目标章中段（非边界页）时才切章，
      // 避免边界页归属抖动导致章节号反复回跳（legado 用连续 pageOffset 无此问题）。
      bool onBoundary = localPage <= 0 || localPage >= chapLen - 1;
      if (!onBoundary) {
        reader._dbg('[DBG] _updateReaderStateForSpliced chapter changed: ${reader.chapter} -> $chap, reader.images reassigned to ch$chap images');
        reader.chapter = chap;
        reader.images = _spliced.imagesForChapter(chap);
      }
    }
    // 窗口期（isLoading）内也不更新 page，保持 changeChapter 设置的 page=1，
    // 避免加载完成后 onChapterLoaded 的 jumpTo(_offsetForGp(reader.page)) 跳到错误页。
    if (!reader.isLoading && reader.page != localPage) {
      reader.setPage(localPage);
      context.readerScaffold.update();
    }
  }

  String _eidForPage(int globalPage) {
    int chapNum = _spliced.chapterOfPage(globalPage).$1;
    return reader.widget.chapters?.ids
            .elementAtOrNull(chapNum - 1) ??
        '0';
  }

  Future<void> _appendNextChapter() async {
    reader._dbg('[DBG] _appendNextChapter ENTER appendingNext=${_spliced.appendingNext} allNextLoaded=${_spliced.allNextLoaded} mounted=$mounted lastCh=${_spliced.lastChapterNum}');
    if (_spliced.appendingNext || _spliced.allNextLoaded || !mounted) return;
    if (_spliced.lastChapterNum >= reader.maxChapter) {
      _spliced.markAllNextLoaded();
      reader._dbg('[DBG] _appendNextChapter lastChapter>=maxChapter, markAllNextLoaded');
      return;
    }
    _spliced.markAppending(true);
    int nextCh = _spliced.lastChapterNum + 1;
    String eid = reader.widget.chapters?.ids.elementAtOrNull(nextCh - 1) ?? '';
    if (eid.isEmpty) {
      _spliced.markAppending(false);
      _spliced.markAllNextLoaded();
      reader._dbg('[DBG] _appendNextChapter eid empty');
      return;
    }
    // Legado-style: use prefetched page list if available (instant append),
    // otherwise fetch from network.
    List<String> pages;
    if (_prefetchedChapters.containsKey(nextCh) && _prefetchedChapters[nextCh]!.isNotEmpty) {
      pages = _prefetchedChapters[nextCh]!;
      reader._dbg('[DBG] _appendNextChapter using prefetched ch$nextCh (${pages.length} pages)');
    } else {
      var res = await reader.type.comicSource!.loadComicPages!(reader.cid, eid);
      if (!mounted) return;
      if (res.error) {
        _spliced.markAppending(false);
        reader._dbg('[DBG] _appendNextChapter loadComicPages ERROR ${res.errorMessage}');
        return;
      }
      pages = res.data;
    }
    setState(() {
      reader._dbg('[DBG] _appendNextChapter BEFORE setState itemCount=${_spliced.length}');
      _spliced.append(pages, nextCh);
      _spliced.markAppending(false);
      reader._dbg('[DBG] _appendNextChapter AFTER splice itemCount=${_spliced.length} offsets=${_spliced._offsets}');
    });
    reader._dbg('[DBG] _appendNextChapter DONE appendedCh=$nextCh splicedLen=${_spliced.length}');
    _prefetchNeighbors(); // legado: keep next chapter ready for seamless switch
    _growCache(_spliced.length + kCacheGrowthPadding);
    var removed = _spliced.unloadExcess();
    if (removed > 0) {
      // 平移 _pageHeights 的 key 保持与 spliced list 一致（用于 _offsetForGp 跳转估算）。
      // 不再补偿 pixels——页码由 _currentPageFromViewport（item 实际位置）决定，
      // 与 _pageHeights/pixels 解耦。
      if (cached.length > removed) cached.removeRange(0, removed);
      if (_pageHeights.isNotEmpty) {
        final Map<int, double> shifted = {};
        _pageHeights.forEach((k, v) {
          if (k > removed) shifted[k - removed] = v;
        });
        _pageHeights
          ..clear()
          ..addAll(shifted);
      }
    }
  }

  Future<void> _prependPrevChapter() async {
    // 读触发时的视口中心 gp（入口同步读，await 期间用户可能滚动，不能用之后的 gp）
    int oldGp = _currentCenterGp();
    reader._dbg('[DBG] _prependPrevChapter ENTER prependingPrev=${_spliced.prependingPrev} allPrevLoaded=${_spliced.allPrevLoaded} mounted=$mounted firstCh=${_spliced.firstChapterNum} oldGp=$oldGp');
    if (_spliced.prependingPrev || _spliced.allPrevLoaded || !mounted) return;
    if (_spliced.firstChapterNum <= 1) {
      _spliced.markAllPrevLoaded();
      reader._dbg('[DBG] _prependPrevChapter firstCh<=1, markAllPrevLoaded');
      return;
    }
    _spliced.markPrepending(true);
    int prevCh = _spliced.firstChapterNum - 1;
    String eid = reader.widget.chapters?.ids.elementAtOrNull(prevCh - 1) ?? '';
    if (eid.isEmpty) {
      _spliced.markPrepending(false);
      _spliced.markAllPrevLoaded();
      reader._dbg('[DBG] _prependPrevChapter eid empty');
      return;
    }
    // Legado-style: use prefetched page list if available (instant prepend),
    // otherwise fetch from network.
    List<String> pages;
    if (_prefetchedChapters.containsKey(prevCh) && _prefetchedChapters[prevCh]!.isNotEmpty) {
      pages = _prefetchedChapters[prevCh]!;
      reader._dbg('[DBG] _prependPrevChapter using prefetched ch$prevCh (${pages.length} pages)');
    } else {
      var res = await reader.type.comicSource!.loadComicPages!(reader.cid, eid);
      if (!mounted) return;
      if (res.error) {
        _spliced.markPrepending(false);
        reader._dbg('[DBG] _prependPrevChapter loadComicPages ERROR ${res.errorMessage}');
        return;
      }
      pages = res.data;
    }
    int plen = _spliced.prepend(pages, prevCh);
    // 头部插入 plen 张图后，所有 index 整体 +plen，平移 _pageHeights 的 key
    // 避免头部 stale 高度错配（legado 同步测量无此问题，这里手动维护）。
    if (_pageHeights.isNotEmpty) {
      final Map<int, double> shifted = {};
      _pageHeights.forEach((k, v) => shifted[k + plen] = v);
      _pageHeights
        ..clear()
        ..addAll(shifted);
    }
    // 显式设置 reader.chapter（对应 legado moveToPrevChapter 显式切章，不靠 listener 反算）
    reader.chapter = prevCh;
    reader.images = _spliced.imagesForChapter(prevCh);
    setState(() {
      _spliced.markPrepending(false);
    });
    // legado 式：prepend 完成后屏蔽后续 prepend 触发，固定延时窗口解除。
    // 防止 jumpTo 过渡帧（ScrollablePositionedList 当帧报旧 gp）连锁触发。
    _suppressPrepend = true;
    _prefetchNeighbors(); // legado: keep prev chapter ready for seamless switch
    reader._dbg('[DBG] _prependPrevChapter DONE prependedCh=$prevCh plen=$plen splicedLen=${_spliced.length} oldGp=$oldGp');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        int target = oldGp + plen;
        reader._dbg('[DBG] _prependPrevChapter postFrame jumpTo index=$target (oldGp=$oldGp plen=$plen)');
        _scrollController.jumpTo(_offsetForGp(target));
        // jumpTo 过渡帧（约 2-3 帧）后解除屏蔽，期间不会连锁触发
        Future.delayed(const Duration(milliseconds: kPrependSuppressWindowMs), () {
          if (mounted) _suppressPrepend = false;
        });
      }
    });
    _growCache(_spliced.length + kCacheGrowthPadding);
    var removed = _spliced.unloadExcess();
    if (removed > 0) {
      // 平移 _pageHeights（同 _appendNextChapter，不再补偿 pixels）
      if (_pageHeights.isNotEmpty) {
        final Map<int, double> shifted = {};
        _pageHeights.forEach((k, v) {
          if (k > removed) shifted[k - removed] = v;
        });
        _pageHeights
          ..clear()
          ..addAll(shifted);
      }
    }
  }

  void _growCache(int minSize) {
    if (_cachedSize < minSize) {
      int newSize = minSize + kCacheGrowthPadding;
      var nc = List.filled(newSize, false);
      for (int i = 0; i < cached.length; i++) { nc[i] = cached[i]; }
      cached = nc;
      _cachedSize = newSize;
    }
  }

  @override
  void initState() {
    reader = context.reader;
    reader._imageViewController = this;
    _scrollController.addListener(_syncReaderState);
    // Only reset now if images are already available (e.g. preloaded before
    // entering the reader). Otherwise onChapterLoaded() will reset after the
    // async load completes — avoids reading a null images list.
    if (reader.images != null) {
      _resetSplicedState();
      _cachedSize = _spliced.length + kCacheGrowthPadding;
      cached = List.filled(_cachedSize, false);
    }
    // Suppress prepend on fresh init (covers chapter jump via toChapter)
    _suppressPrepend = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _placeholderPageHeight > 0) {
        _scrollController.jumpTo(_offsetForGp(reader.page));
      }
    });
    Future.delayed(
      const Duration(milliseconds: kInitCacheDelayMs),
      () => _cacheSplicedImages(reader.page),
    );
    super.initState();
  }

  /// 通过遍历可见 item 的 RenderBox 实际渲染位置，找视口中心对应的 item index。
  ///
  /// 替代 _gpFromPixels（像素累加反算），从根本上消除 _pageHeights 异步高度变化
  /// 导致的页码错位——页码不再依赖 _pageHeights，而是由 item 在视口中的实际位置决定。
  /// 图片高度怎么变、加载顺序怎么乱，item 的 RenderBox 位置是实时准确的。
  /// 可见 item 通常 3-5 个，遍历成本可忽略。
  int _currentPageFromViewport() {
    if (_itemContexts.isEmpty || _spliced.length == 0) {
      return reader.page.clamp(1, _spliced.length > 0 ? _spliced.length : 1);
    }
    final bool horizontal = reader.mode != ReaderMode.continuousTopToBottom;
    // 视口中心在屏幕中的坐标
    final viewport = context.findRenderObject();
    double viewportCenter;
    if (viewport is RenderBox && viewport.attached) {
      final size = viewport.size;
      viewportCenter = horizontal
          ? viewport.localToGlobal(Offset(size.width / 2, 0)).dx
          : viewport.localToGlobal(Offset(0, size.height / 2)).dy;
    } else {
      viewportCenter = horizontal
          ? reader.size.width / 2
          : reader.size.height / 2;
    }
    int best = reader.page;
    double bestDist = double.infinity;
    _itemContexts.forEach((index, ctx) {
      if (!ctx.mounted) return;
      final ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.attached) return;
      final double itemCenter = horizontal
          ? ro.localToGlobal(Offset(ro.size.width / 2, 0)).dx
          : ro.localToGlobal(Offset(0, ro.size.height / 2)).dy;
      final dist = (itemCenter - viewportCenter).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = index;
      }
    });
    return best.clamp(1, _spliced.length);
  }

  /// 第 gp 页（1-based）的显示高度：从 _pageHeights 拿真实高，未加载回退占位。
  double _pageHeight(int gp) {
    return _pageHeights[gp] ?? _placeholderPageHeight;
  }

  /// 根据图片真实像素尺寸 (imgW, imgH) 和当前阅读模式，算出该页沿
  /// 滚动轴的显示尺寸（垂直模式=高度，水平模式=宽度）。
  /// 与 ComicImage 内部 build 的尺寸算法保持一致，确保 _pageHeights 存的值
  /// 和 item 实际渲染高度同源（消除双轨不一致导致的页间空白/跳变）。
  double _computeAxisSize(int imgW, int imgH) {
    final bool horizontal = reader.mode != ReaderMode.continuousTopToBottom;
    final double cellSize = horizontal ? reader.size.height : _layoutCrossAxis;
    return horizontal
        ? cellSize * imgW / imgH
        : cellSize * imgH / imgW;
  }

  /// 第 gp 页起始处的像素偏移 = Σ_{i=1}^{gp-1} (pageHeight(i) + kPageSpacing)。
  /// 头尾占位 SizedBox（index 0 / length+1）不计入（它们高度为 0）。
  /// 仅用于跳转估算（toPage/jumpTo），精度要求低——不准只影响跳转位置，
  /// 跳转后 _syncReaderState 用 _currentPageFromViewport 自动校正页码。
  double _offsetForGp(int gp) {
    double off = 0;
    for (int i = 1; i < gp; i++) {
      off += _pageHeight(i) + kPageSpacing;
    }
    return off;
  }

  /// Reads the global page at the viewport center synchronously.
  int _currentCenterGp() {
    if (_placeholderPageHeight <= 0) return 1;
    return _currentPageFromViewport();
  }

  /// Called by the reader after a chapter switch's images are ready.
  /// Resets the spliced list synchronously (no null window) and scrolls to
  /// the target page. Legado-style: the view stays alive, only its data reloads.
  @override
  void onChapterLoaded() {
    _resetSplicedState();
    _cachedSize = _spliced.length + kCacheGrowthPadding;
    cached = List.filled(_cachedSize, false);
    _suppressPrepend = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollController.jumpTo(_offsetForGp(reader.page));
      // 章节切换后延时解除屏蔽，避免 jumpTo 过渡帧连锁触发 prepend
      Future.delayed(const Duration(milliseconds: kPrependSuppressWindowMs), () {
        if (mounted) _suppressPrepend = false;
      });
      _appendNextChapter(); // immediately splice next chapter for seamless reading
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_syncReaderState);
    super.dispose();
  }

  /// 上一帧 gp，用于检测 gp 突变（无滚动时大跳 = 回退根因线索）
  int _lastSyncedGp = -1;

  /// Builds one list item (a single full-screen comic page) for the spliced
  /// list. Item size is forced to the screen size so the ListView never
  /// re-measures items when images load (that re-measure is what reset the
  /// scroll position and caused jumps before the legado-style rewrite).
  Widget _buildSplicedItem(BuildContext context, int index) {
        if (index == 0 || index == _spliced.length + 1) {
          return const SizedBox();
        }
        int imageIndex = index - 1;
        String imageKey = _spliced[imageIndex];
        String eid = _eidForPage(index);

        ImageProvider image = ReaderImageProvider(
          imageKey,
          reader.type.comicSource?.key,
          reader.cid,
          eid,
          index,
          enableResize: true,
        );

        double? width, height;
        if (reader.mode == ReaderMode.continuousLeftToRight ||
            reader.mode == ReaderMode.continuousRightToLeft) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }

        final double itemPlaceholder = reader.mode == ReaderMode.continuousTopToBottom
            ? reader.size.height
            : reader.size.width;
        return _ItemContextRegistrar(
          index: index,
          onRegister: (idx, ctx) => _itemContexts[idx] = ctx,
          onUnregister: (idx) => _itemContexts.remove(idx),
          child: ColoredBox(
            color: context.colorScheme.surface,
            child: ComicImage(
              key: ValueKey(imageKey),
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              image: image,
              width: width,
              height: height,
              fit: BoxFit.contain,
              placeholderHeight: itemPlaceholder,
              onInit: (state) {
                reader._dbg('[DBG] ComicImage onInit idx=$index key=$imageKey');
                imageStates.add(state);
              },
              onImageLoaded: (imgW, imgH) {
                // 仅更新 _pageHeights（用于 _offsetForGp 跳转估算）。
                // 不再补偿 pixels——页码由 _currentPageFromViewport（item 实际位置）决定，
                // 与 _pageHeights 解耦，异步高度变化不会导致页码错位。
                final double h = _computeAxisSize(imgW, imgH);
                if ((_pageHeights[index] ?? -1) != h) {
                  _pageHeights[index] = h;
                  setState(() {});
                }
              },
              onDispose: (state) {
                reader._dbg('[DBG] ComicImage onDispose idx=$index key=$imageKey');
                imageStates.remove(state);
              },
            ),
          ),
        );
  }

  void _syncReaderState() {
    if (_placeholderPageHeight <= 0) return;
    // 页码由 item 实际渲染位置决定（_currentPageFromViewport），
    // 不再依赖 _pageHeights 像素累加反算——彻底消除异步高度变化导致的页码错位。
    int gp = _currentPageFromViewport();
    String flag = '';
    if (_lastSyncedGp >= 0 && (gp - _lastSyncedGp).abs() > 3 && !_spliced.appendingNext && !_spliced.prependingPrev && !_suppressPrepend) {
      flag = ' <<< GP JUMP (delta=${gp - _lastSyncedGp}, no splice active)';
    }
    _lastSyncedGp = gp;
    reader._dbg('[DBG] _syncReaderState gp=$gp chapter=${reader.chapter} itemCount=${_spliced.length} items=${_itemContexts.length}$flag');
    _updateReaderStateForSpliced(gp);
    _cacheSplicedImages(gp);
  }

  void _cacheSplicedImages(int cp) {
    // Detect scroll direction
    if (_lastGpForDirection != null) {
      if (cp > _lastGpForDirection!) {
        _scrollingForward = true;
      } else if (cp < _lastGpForDirection!) {
        _scrollingForward = false;
      }
    }
    _lastGpForDirection = cp;

    int preload = preCacheCount;
    // Build list of pages to preload, prioritizing scroll direction
    List<int> pagesToLoad = [];
    if (_scrollingForward) {
      for (int i = cp + 1; i <= cp + preload; i++) {
        pagesToLoad.add(i);
      }
      // Also preload a few behind, but fewer
      for (int i = cp - 1; i >= cp - (preload ~/ 2) && i >= 1; i--) {
        pagesToLoad.add(i);
      }
    } else {
      for (int i = cp - 1; i >= cp - preload && i >= 1; i--) {
        pagesToLoad.add(i);
      }
      for (int i = cp + 1; i <= cp + (preload ~/ 2); i++) {
        pagesToLoad.add(i);
      }
    }

    for (int i in pagesToLoad) {
      if (i > _spliced.length || i < 1) continue;
      if (i < cached.length && cached[i]) continue;
      if (i >= cached.length) continue;
      var key = _spliced[i - 1];
      if (key.startsWith("file://")) { cached[i] = true; continue; }
      _enqueueDownload(() {
        ImageDownloader.loadComicImage(
            key, reader.type.comicSource?.key, reader.cid, _eidForPage(i));
        cached[i] = true;
        _onDownloadComplete();
      });
    }
  }

  void cacheImages(int current) => _cacheSplicedImages(current);

  double? _futurePosition;

  /// Mouse-wheel / trackpad smooth scrolling. Accumulates a target offset in
  /// [_futurePosition] and eases toward it; Shift disables it. Speed scales
  /// with the reader's scroll-speed setting.
  void smoothTo(double offset) {
    if (HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    var currentLocation = _scrollController.position.pixels;
    var old = _futurePosition;
    _futurePosition ??= currentLocation;
    double k = (_futurePosition! - currentLocation).abs() / 1600 + 1;
    final customSpeed = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      "readerScrollSpeed",
    );
    if (customSpeed is num) {
      k *= customSpeed;
    }
    _futurePosition = _futurePosition! + offset * k;
    var beforeOffset = (_futurePosition! - currentLocation).abs();
    _futurePosition = _futurePosition!.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    var afterOffset = (_futurePosition! - currentLocation).abs();
    if (_futurePosition == old) return;
    var target = _futurePosition!;
    var duration = const Duration(milliseconds: 160);
    if (afterOffset < beforeOffset) {
      duration = duration * (afterOffset / beforeOffset);
      if (duration < Duration(milliseconds: 10)) {
        duration = Duration(milliseconds: 10);
      }
    }
    _scrollController
        .animateTo(_futurePosition!, duration: duration, curve: Curves.linear)
        .then((_) {
          var current = _scrollController.position.pixels;
          if (current == target && current == _futurePosition) {
            _futurePosition = null;
          }
        });
  }

  /// Forwards mouse-wheel scroll events to [smoothTo] (Ctrl is reserved for
  /// zoom, so it's ignored here).
  void onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (!_isMouseScrolling) {
        setState(() {
          _isMouseScrolling = true;
        });
      }
      if (isCTRLPressed) {
        return;
      }
      smoothTo(event.scrollDelta.dy);
    }
  }

  void onScroll() {
    var pixels = _scrollController.position.pixels;
    var min = _scrollController.position.minScrollExtent;
    var max = _scrollController.position.maxScrollExtent;
    reader._dbg('[DBG] onScroll pixels=$pixels min=$min max=$max itemCount=${_spliced.length}');
  }

  bool onScaleUpdate([double? scale]) {
    var isZoomedIn = (scale ?? photoViewController.scale) != 1.0;
    if (isZoomedIn != this.isZoomedIn) {
      setState(() {
        this.isZoomedIn = isZoomedIn;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    reader._dbg('[DBG] BUILD called spliceLen=${_spliced.length} readerPage=${reader.page} readerChapter=${reader.chapter}');
    // legado 式：每页初始高度 = 视口高（对应 MATCH_PARENT），
    // 图片加载后缩小到图片真实高，内容上移 → 无间隙。
    _placeholderPageHeight = reader.mode == ReaderMode.continuousTopToBottom
        ? reader.size.height
        : reader.size.width;
    Widget widget = ListView.builder(
      key: _listKey,
      controller: _scrollController,
      itemCount: _spliced.length + 2,
      addSemanticIndexes: false,
      scrollDirection: reader.mode == ReaderMode.continuousTopToBottom
          ? Axis.vertical
          : Axis.horizontal,
      reverse: reader.mode == ReaderMode.continuousRightToLeft,
      // 恒定 physics：不能随 disableScroll/isZoomedIn 切换，否则 ListView
      // 在 physics 变化时重置 ScrollController.position.pixels 到 0 → 点击回退。
      // 缩放/禁用滚动改由手势层(photoViewController/onPointerSignal)处理。
      physics: const BouncingScrollPhysics(),
      // 禁用 ListView 自动消费 MediaQuery padding（手机 safe area inset）。
      // 否则 item 的 constrains.maxWidth < _layoutCrossAxis（父约束宽），
      // ComicImage 用 constrains.maxWidth 算渲染高 < _pageHeights 用
      // _layoutCrossAxis 算的存储高 → 累加偏移算大 → 页间可变白间隙。
      // 设 zero 后 item 约束宽 == 父约束宽 == _layoutCrossAxis，同源无间隙。
      padding: EdgeInsets.zero,
      itemBuilder: _buildSplicedItem,
    );

    widget = Stack(
      children: [
        Positioned.fill(child: buildBackground(context)),
        Positioned.fill(child: widget),
      ],
    );

    widget = Listener(
      onPointerDown: (event) {
        reader._dbg('[DBG] onPointerDown fingers=$fingers');
        fingers++;
        if (fingers > 1 && !disableScroll) {
          setState(() {
            disableScroll = true;
          });
        }
        _futurePosition = null;
        if (_isMouseScrolling) {
          setState(() {
            _isMouseScrolling = false;
          });
        }
      },
      onPointerUp: (event) {
        fingers--;
        reader._dbg('[DBG] onPointerUp fingers=$fingers');
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerCancel: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.scale == 1.0) {
          smoothTo(0 - event.panDelta.dy);
        }
      },
      onPointerMove: (event) {
        Offset value = event.delta;
        if (photoViewController.scale == 1 || fingers != 1) {
          return;
        }
        Offset offset;
        var sp = _scrollController.position;
        if (sp.pixels <= sp.minScrollExtent ||
            sp.pixels >= sp.maxScrollExtent) {
          offset = Offset(value.dx, value.dy);
        } else {
          if (reader.mode == ReaderMode.continuousTopToBottom) {
            offset = Offset(value.dx, 0);
          } else {
            offset = Offset(0, value.dy);
          }
        }
        if (isLongPressing) {
          offset += value;
        }
        photoViewController.updateMultiple(
          position: photoViewController.position + offset,
        );
      },
      onPointerSignal: onPointerSignal,
      child: widget,
    );

    widget = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          delayedSetIsScrolling(true);
        } else if (notification is ScrollEndNotification) {
          delayedSetIsScrolling(false);
        }

        var scale = photoViewController.scale ?? 1.0;

        if (notification is ScrollUpdateNotification &&
            (scale - 1).abs() < 0.05) {
          if (!_scrollController.hasClients) return false;
          if (_scrollController.position.pixels >=
                  _scrollController.position.maxScrollExtent) {
            reader._dbg('[DBG] scrollNotify MAX pixels=${_scrollController.position.pixels} max=${_scrollController.position.maxScrollExtent} allNextLoaded=${_spliced.allNextLoaded} appendingNext=${_spliced.appendingNext}');
            if (!_spliced.allNextLoaded && !_spliced.appendingNext) {
              _appendNextChapter();
            }
          } else if (_scrollController.position.pixels <=
                  _scrollController.position.minScrollExtent) {
            reader._dbg('[DBG] scrollNotify MIN pixels=${_scrollController.position.pixels} min=${_scrollController.position.minScrollExtent} allPrevLoaded=${_spliced.allPrevLoaded} prependingPrev=${_spliced.prependingPrev} suppressPrepend=$_suppressPrepend');
            if (!_spliced.allPrevLoaded && !_spliced.prependingPrev) {
              _prependPrevChapter();
            }
          } else {
            context.readerScaffold.setFloatingButton(0);
          }
        }

        return true;
      },
      child: widget,
    );
    var width = reader.size.width;
    var height = reader.size.height;
    if (appdata.settings['limitImageWidth'] &&
        width / height > 0.7 &&
        reader.mode == ReaderMode.continuousTopToBottom) {
      width = height * 0.7;
    }
    _layoutCrossAxis = reader.mode == ReaderMode.continuousTopToBottom
        ? width
        : height;

    return PhotoView.customChild(
      backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
      childSize: Size(width, height),
      minScale: 1.0,
      maxScale: 2.5,
      strictScale: true,
      controller: photoViewController,
      onScaleUpdate: onScaleUpdate,
      child: SizedBox(width: width, height: height, child: widget),
    );
  }

  Widget buildBackground(BuildContext context) {
    return const SizedBox.shrink();
  }

  @override
  Future<void> animateToPage(int page) {
    int gp = _spliced.globalGpForChapterPage(reader.chapter, page);
    return _scrollController.animateTo(
      _offsetForGp(gp),
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    double target;
    if (photoViewController.scale !=
        photoViewController.getInitialScale?.call()) {
      target = photoViewController.getInitialScale!.call()!;
    } else {
      target = photoViewController.getInitialScale!.call()! * 1.75;
    }
    var size = MediaQuery.of(context).size;
    photoViewController.animateScale?.call(
      target,
      Offset(size.width / 2 - location.dx, size.height / 2 - location.dy),
    );
    onScaleUpdate(target);
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || delayedIsScrolling) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    onScaleUpdate(target);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom']) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    onScaleUpdate(target);
    isLongPressing = false;
  }

  @override
  void toPage(int page) {
    int gp = _spliced.globalGpForChapterPage(reader.chapter, page);
    _scrollController.jumpTo(_offsetForGp(gp));
    _futurePosition = null;
  }

  @override
  void handleKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      setState(() {
        if (event is KeyDownEvent) {
          isCTRLPressed = true;
        } else if (event is KeyUpEvent) {
          isCTRLPressed = false;
        }
      });
    }
    if (event is KeyUpEvent) {
      return;
    }
    bool? forward;
    if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (forward == true) {
      _scrollController.animateTo(
        _scrollController.offset + context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else if (forward == false) {
      _scrollController.animateTo(
        _scrollController.offset - context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    }
  }

  @override
  bool handleOnTap(Offset location) {
    if (delayedIsScrolling) {
      return true;
    }
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      return (await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      ))!.readAsBytes();
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    String? imageKey;
    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        imageKey = (imageState.widget.image as ReaderImageProvider).imageKey;
      }
    }
    return imageKey;
  }
}

ImageProvider _createImageProviderFromKey(
  String imageKey,
  BuildContext context,
  int page,
) {
  var reader = context.reader;
  return ReaderImageProvider(
    imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    reader.eid,
    reader.page,
    enableResize: reader.mode.isContinuous, // For continuous mode, we need to resize the image to improve performance
  );
}

ImageProvider _createImageProvider(int page, BuildContext context) {
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  return _createImageProviderFromKey(imageKey, context, page);
}

/// [_precacheImage] is used to precache the image for the given page.
/// The image is cached using the flutter's [precacheImage] method.
/// The image will be downloaded and decoded into memory.
void _precacheImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  precacheImage(_createImageProvider(page, context), context);
}

/// [_preDownloadImage] is used to download the image for the given page.
/// The image is downloaded using the [CacheManager] and saved to the local storage.
void _preDownloadImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  if (imageKey.startsWith("file://")) {
    return;
  }
  var cid = reader.cid;
  var eid = reader.eid;
  var sourceKey = reader.type.comicSource?.key;
  ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid);
}


