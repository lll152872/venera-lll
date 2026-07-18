class _ContinuousModeState extends State<_ContinuousMode>
    implements _ImageViewController {
  late _ReaderState reader;

  var itemScrollController = ItemScrollController();
  var itemPositionsListener = ItemPositionsListener.create();
  var photoViewController = PhotoViewController();
  ScrollController? _scrollController;

  ScrollController get scrollController => _scrollController!;

  var isCTRLPressed = false;
  static var _isMouseScrolling = false;
  var fingers = 0;
  bool disableScroll = false;

  late List<bool> cached;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  /// Build an [ImageProvider] for the [index]-th item in [_splicedImages].
  /// Used by [_ContinuousMode] in place of the per-chapter
  /// [reader.images] list.
  ImageProvider _splicedImageProvider(int index, BuildContext context) {
    if (index < 1 || index > _splicedImages.length) {
      return _createImageProvider(1, context);
    }
    final key = _splicedImages[index - 1];
    return _createImageProviderFromKey(key, context, index);
  }

  @override
  (int, int)? chapterOfPage(int globalPage) {
    if (globalPage < 1) return null;
    final gp = globalPage - 1;
    int? bestChapter;
    int? bestOffset;
    _chapterOffsets.forEach((chapter, offset) {
      if (offset <= gp && (bestOffset == null || offset > bestOffset!)) {
        bestChapter = chapter;
        bestOffset = offset;
      }
    });
    if (bestChapter == null || bestOffset == null) return null;
    return (bestChapter!, gp - bestOffset! + 1);
  }

  /// Whether the user was scrolling the page.
  /// The gesture detector has a delay to detect tap event.
  /// To handle the tap event, we need to know if the user was scrolling before the delay.
  bool delayedIsScrolling = false;

  var imageStates = <State<ComicImage>>{};

  void delayedSetIsScrolling(bool value) {
    Future.delayed(
      const Duration(milliseconds: 300),
      () => delayedIsScrolling = value,
    );
  }

  bool prepareToPrevChapter = false;
  bool prepareToNextChapter = false;
  bool jumpToNextChapter = false;
  bool jumpToPrevChapter = false;

  /// Number of images left to trigger loading the next chapter in continuous
  /// mode. Mirrors legacy-reader (legado) behaviour: a few images before the
  /// boundary we already request the next chapter and splice its images onto
  /// the end of the current list.
  static const int _seamlessPreloadAhead = 3;

  /// True while [loadNextChapter] is in flight, so the scroll listener does
  /// not fire it twice in a row.
  bool _loadingNextChapter = false;

  /// Spliced image list used by [_ContinuousMode] in place of
  /// [reader.images]. Starts as a shallow copy of [reader.images] and grows
  /// as we seamlessly pre-append subsequent chapters.
  late List<String> _splicedImages;

  /// For every chapter whose images are currently part of [_splicedImages],
  /// the start index of that chapter inside the spliced list. Used to map
  /// a global page index back to `(chapter, pageInChapter)` for history
  /// recording.
  final Map<int, int> _chapterOffsets = {};

  void _tryJumpToNextChapter() {
    // In continuous (legado-style) mode, the chapter boundary is hidden by
    // splicing the next chapter's images onto the end of the current list
    // (see [_appendNextChapter]). The user simply keeps scrolling, so we
    // must NOT call [reader.toNextChapter] here 鈥?doing so would replace
    // the spliced list with the new chapter's images and yank the user
    // back to page 1 of the next chapter (the "璺崇珷" bug).
    //
    // We still make sure the splice is kicked off in case the user reached
    // the very end before [onPositionChanged] had a chance to fire.
    if (reader.isLastChapterOfGroup) return;
    if (_loadingNextChapter) return;
    _appendNextChapter();
  }

  /// Asynchronously fetch the next chapter and splice its image list onto the
  /// end of the current [reader.images] buffer. After this completes, the
  /// ListView naturally grows and the user keeps scrolling seamlessly.
  Future<void> _appendNextChapter() async {
    if (_loadingNextChapter) return;
    if (reader.isLastChapterOfGroup) return;
    if (!mounted) return;
    _loadingNextChapter = true;
    final nextChapter = reader.chapter + 1;
    try {
      // 1. Update [reader.chapter] so that downstream lookups (cid, sourceKey,
      //    history...) use the new chapter context.
      // 2. Use the existing local / network load path.
      // 3. Splice the returned image list onto the end of the existing
      //    [reader.images] buffer and rebuild.
      final list = await _fetchChapterImages(nextChapter);
      if (!mounted) return;
      if (list == null || list.isEmpty) return;
      setState(() {
        // Append the next chapter's images onto the end of the in-memory
        // spliced list. The user's view is a single ListView that grows
        // naturally; the chapter boundary becomes invisible.
        _splicedImages.addAll(list);
        // Track the chapter offset so we can map a global page index back
        // to (chapter, pageInChapter) for history purposes.
        reader.chapter = nextChapter;
        _chapterOffsets[nextChapter] = _splicedImages.length - list.length;
        // Do NOT replace `reader.images` with the spliced list. The page
        // indicator in the UI is "pageInChapter / maxPage" (e.g. "1 12/36"
        // then "2 1/6") and `maxPage` is derived from `reader.images.length`.
        // Keeping `reader.images` as the *current chapter's* image list means
        // `maxPage` automatically resets to the new chapter's length when
        // the user scrolls across the boundary, which is what the user
        // expects.
        // Grow the precache bitmap to cover the newly appended images.
        cached = List<bool>.from(cached)
          ..addAll(List<bool>.filled(list.length, false));
      });
    } finally {
      _loadingNextChapter = false;
    }
  }

  /// Fetch image keys for chapter [c] without mutating [reader.images]. This
  /// mirrors the load paths used by [_ReaderImagesState.load] for the active
  /// chapter, but is read-only with respect to the global buffer.
  Future<List<String>?> _fetchChapterImages(int c) async {
    final type = reader.type;
    if (type == ComicType.local) {
      try {
        return await LocalManager().getImages(reader.cid, type, c);
      } catch (_) {
        return null;
      }
    }
    final cp = reader.widget.chapters?.ids.elementAtOrNull(c - 1);
    if (cp == null) return null;
    final source = type.comicSource;
    if (source?.loadComicPages == null) return null;
    try {
      final res = await source!.loadComicPages!(reader.widget.cid, cp);
      if (res.error) return null;
      return res.data;
    } catch (_) {
      return null;
    }
  }

  bool isZoomedIn = false;
  bool isLongPressing = false;

  @override
  void initState() {
    reader = context.reader;
    reader._imageViewController = this;
    itemPositionsListener.itemPositions.addListener(onPositionChanged);
    _splicedImages = List<String>.from(reader.images ?? const <String>[]);
    _chapterOffsets[reader.chapter] = 0;
    _currentChapterSnapshot = reader.chapter;
    final initialLen = _splicedImages.length;
    cached = List.filled(initialLen + 2, false);
    Future.delayed(
      const Duration(milliseconds: 100),
      () => cacheImages(reader.page),
    );
    super.initState();
  }

  /// Snapshot of the chapter this state was last synchronised to. Used to
  /// detect user-driven chapter changes (e.g. the chapter picker) and rebuild
  /// the spliced image buffer from scratch.
  late int _currentChapterSnapshot;

  @override
  void dispose() {
    itemPositionsListener.itemPositions.removeListener(onPositionChanged);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reader.chapter != _currentChapterSnapshot) {
      // User manually switched to a different chapter via the chapter picker
      // or by some other non-seamless path. Reset the spliced list to mirror
      // the reader's per-chapter buffer; seamless scroll continues from here.
      _splicedImages = List<String>.from(reader.images ?? const <String>[]);
      _chapterOffsets
        ..clear()
        ..[reader.chapter] = 0;
      _currentChapterSnapshot = reader.chapter;
      cached = List<bool>.filled(_splicedImages.length + 2, false);
      // Reset the cache bitmap and tell the scroll controller to jump to the
      // first page so we don't accidentally show stale chapter offsets.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        itemScrollController.jumpTo(index: reader.page);
        cacheImages(reader.page);
      });
    }
  }

  void onPositionChanged() {
    if (itemPositionsListener.itemPositions.value.isEmpty) {
      return;
    }
    // The ListView has a leading and trailing SizedBox (see itemBuilder), so
    // item index 0 is the head spacer and item index total+1 is the tail.
    // The first visible image therefore has item index 1 for chapter 1's
    // first image, 2 for chapter 1's second image, etc. We translate that
    // into a "global image index" (0-based) into [_splicedImages].
    final itemIndex = itemPositionsListener.itemPositions.value.first.index;
    var splicedIndex = (itemIndex - 1).clamp(0, _splicedImages.length - 1);
    // Map the global index back to (chapter, pageInChapter) so that the UI
    // can show "chapter N  pageInChapter / chapter.length" rather than
    // running the counter across the chapter boundary.
    final chapterStart = _chapterOffsets[reader.chapter] ?? 0;
    var page = (splicedIndex - chapterStart + 1).clamp(1, reader.maxPage);
    if (page != reader.page) {
      reader.setPage(page);
      context.readerScaffold.update();
    }
    // `cacheImages` works in 1-based [splicedImages] coordinates, so pass
    // the global image index (splicedIndex + 1) rather than the chapter-
    // local page.
    cacheImages(splicedIndex + 1);
    // Continuous mode: when the user is within _seamlessPreloadAhead of the
    // very end of the spliced image list, start loading the next chapter so
    // the boundary becomes invisible. [page] is the chapter-local 1-based
    // page, while [splicedIndex] is the global 0-based index; the trigger
    // is global (we want the splice to begin as soon as we approach the
    // end of the currently visible buffer regardless of which chapter that
    // buffer ends in).
    if (splicedIndex >= _splicedImages.length - 1 - _seamlessPreloadAhead &&
        !_loadingNextChapter &&
        !reader.isLastChapterOfGroup) {
      _appendNextChapter();
    }
  }

  double? _futurePosition;

  void smoothTo(double offset) {
    if (HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    var currentLocation = scrollController.position.pixels;
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
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
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
    scrollController
        .animateTo(_futurePosition!, duration: duration, curve: Curves.linear)
        .then((_) {
          var current = scrollController.position.pixels;
          if (current == target && current == _futurePosition) {
            _futurePosition = null;
          }
        });
  }

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

  void cacheImages(int current) {
    final total = _splicedImages.length;
    if (cached.length < total + 2) {
      cached = List<bool>.from(cached)
        ..addAll(List<bool>.filled(total + 2 - cached.length, false));
    }
    for (int i = current + 1; i <= current + preCacheCount; i++) {
      if (i <= total && !cached[i]) {
        _preDownloadImage(i, context);
        cached[i] = true;
      }
    }
  }

  void onScroll() {
    if (prepareToPrevChapter) {
      jumpToNextChapter = false;
      jumpToPrevChapter = true;
    } else if (prepareToNextChapter) {
      jumpToNextChapter = true;
      jumpToPrevChapter = false;
    }
  }

  bool onScaleUpdate([double? scale]) {
    if (prepareToNextChapter || prepareToPrevChapter) {
      setState(() {
        prepareToPrevChapter = false;
        prepareToNextChapter = false;
      });
      context.readerScaffold.setFloatingButton(0);
    }
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
    Widget widget = ScrollablePositionedList.builder(
      initialScrollIndex: reader.page,
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      scrollControllerCallback: (scrollController) {
        if (_scrollController != null) {
          _scrollController!.removeListener(onScroll);
        }
        _scrollController = scrollController;
        _scrollController!.addListener(onScroll);
      },
      itemCount: _splicedImages.length + 2,
      addSemanticIndexes: false,
      scrollDirection: reader.mode == ReaderMode.continuousTopToBottom
          ? Axis.vertical
          : Axis.horizontal,
      reverse: reader.mode == ReaderMode.continuousRightToLeft,
      physics: isCTRLPressed || _isMouseScrolling || disableScroll
          ? const NeverScrollableScrollPhysics()
          : isZoomedIn
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      itemBuilder: (context, index) {
        final total = _splicedImages.length;
        if (index == 0 || index == total + 1) {
          return const SizedBox();
        }
        double? width, height;
        if (reader.mode == ReaderMode.continuousLeftToRight ||
            reader.mode == ReaderMode.continuousRightToLeft) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }

        ImageProvider image = _splicedImageProvider(index, context);

        return ColoredBox(
          color: context.colorScheme.surface,
          child: ComicImage(
            filterQuality: FilterQuality.medium,
            image: image,
            width: width,
            height: height,
            fit: BoxFit.contain,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        );
      },
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: _kTouchLikeDeviceTypes,
      ),
    );

    widget = Stack(
      children: [
        Positioned.fill(child: buildBackground(context)),
        Positioned.fill(child: widget),
      ],
    );

    widget = Listener(
      onPointerDown: (event) {
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
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
        if (fingers == 0) {
          if (jumpToPrevChapter) {
            context.readerScaffold.setFloatingButton(0);
            // In continuous mode we don't jump back to the previous
            // chapter's first page; the user just stops scrolling and the
            // spliced list is the source of truth. The "swipe back" hint is
            // still shown but the actual chapter switch is suppressed.
          } else if (jumpToNextChapter) {
            context.readerScaffold.setFloatingButton(0);
            // Same: continuous mode keeps the spliced list and never calls
            // [reader.toNextChapter], which would yank the user back to
            // page 1 of the next chapter.
          }
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
        var sp = scrollController.position;
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
          if (!scrollController.hasClients) return false;
          if (scrollController.position.pixels <=
                  scrollController.position.minScrollExtent &&
              !reader.isFirstChapterOfGroup) {
            if (!prepareToPrevChapter) {
              jumpToPrevChapter = true;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(-1);
              setState(() {
                prepareToPrevChapter = true;
              });
            } else {
              jumpToPrevChapter = true;
            }
          } else if (scrollController.position.pixels >=
                  scrollController.position.maxScrollExtent) {
            _tryJumpToNextChapter();
          } else {
            context.readerScaffold.setFloatingButton(0);
            if (prepareToPrevChapter || prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              setState(() {
                prepareToPrevChapter = false;
                prepareToNextChapter = false;
              });
            }
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
    return Column(
      children: [
        SizedBox(height: context.padding.top + 16),
        if (prepareToPrevChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: true,
          ),
        const Spacer(),
        if (prepareToNextChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: false,
          ),
        SizedBox(height: 36),
      ],
    );
  }

  @override
  Future<void> animateToPage(int page) {
    return itemScrollController.scrollTo(
      index: page,
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
    itemScrollController.jumpTo(index: page);
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
      scrollController.animateTo(
        scrollController.offset + context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else if (forward == false) {
      scrollController.animateTo(
        scrollController.offset - context.height * 0.25,
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

