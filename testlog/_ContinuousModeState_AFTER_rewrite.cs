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

  // === Seamless-scroll data model (legado-style) ===
  //
  // A single ListView renders a *global* image list that grows as the user
  // scrolls across chapter boundaries. The chapter boundary is hidden because
  // we never call [reader.toNextChapter] / [reader.toPrevChapter] / [reader.setChapter]
  // from this state — the user simply keeps scrolling and the next chapter's
  // images appear at the end of the list.
  //
  //   _allImages       : concatenation of every chapter that has been
  //                      loaded so far, in order.
  //   _chapterStarts   : _chapterStarts[i] is the 0-based index in
  //                      _allImages where chapter (i+1) begins. Length is
  //                      the number of chapters currently in _allImages.
  //   _loadedChapters  : the highest chapter number loaded so far.
  //   _currentChapter  : the chapter the user is currently reading,
  //                      determined from the scroll position.
  //
  // Invariants:
  //   * _chapterStarts[0] == 0
  //   * _allImages.length == sum of loaded chapter sizes
  //   * reader.images always reflects the *current* chapter (not the
  //     spliced list), so the page indicator shows
  //     "pageInChapter / chapterLength" and maxPage resets automatically
  //     when the user crosses a chapter boundary.
  //   * reader.chapter always reflects _currentChapter so downstream
  //     lookups (cid, sourceKey, history) use the right context.
  late List<String> _allImages;
  late List<int> _chapterStarts;
  int _loadedChapters = 0;
  int _currentChapter = 0;

  /// True while [loadNextChapter] is in flight.
  bool _loadingNextChapter = false;

  /// Number of images from the very end of [_allImages] at which we
  /// kick off loading the next chapter. Mirrors the behaviour of the
  /// legado web reader.
  static const int _kPreloadAhead = 3;

  /// Resolved image provider for [_allImages][i]. Replaces the old
  /// [_splicedImageProvider] helper.
  ImageProvider _imageForAllIndex(int i, BuildContext context) {
    if (i < 0 || i >= _allImages.length) {
      return _createImageProvider(1, context);
    }
    return _createImageProviderFromKey(_allImages[i], context, i + 1);
  }

  /// Map a global image index (0-based in [_allImages]) to
  /// `(chapter, pageInChapter)` where both are 1-based. Returns null when
  /// the buffer is empty.
  (int, int)? _chapterAndPageOf(int globalIndex) {
    if (_allImages.isEmpty) return null;
    final gi = globalIndex.clamp(0, _allImages.length - 1);
    for (int c = _loadedChapters; c >= 1; c--) {
      if (gi >= _chapterStarts[c - 1]) {
        return (c, gi - _chapterStarts[c - 1] + 1);
      }
    }
    return null;
  }

  /// Image list of the chapter the user is currently in, used for
  /// [reader.images] / `maxPage` so the page indicator resets when crossing
  /// a boundary.
  List<String> _currentChapterImages() {
    if (_allImages.isEmpty || _currentChapter <= 0) return const [];
    final start = _chapterStarts[_currentChapter - 1];
    final end = _currentChapter == _loadedChapters
        ? _allImages.length
        : _chapterStarts[_currentChapter];
    return _allImages.sublist(start, end);
  }

  @override
  (int, int)? chapterOfPage(int globalPage) {
    // [globalPage] here is 1-based: 1 == first image in [_allImages],
    // _allImages.length == last image. This matches the contract of
    // [updateHistory] in reader.dart.
    if (globalPage < 1) return null;
    return _chapterAndPageOf(globalPage - 1);
  }

  // === Gesture / scroll state ===
  bool delayedIsScrolling = false;
  var imageStates = <State<ComicImage>>{};
  double? _futurePosition;

  void delayedSetIsScrolling(bool value) {
    Future.delayed(
      const Duration(milliseconds: 300),
      () => delayedIsScrolling = value,
    );
  }

  bool isZoomedIn = false;
  bool isLongPressing = false;

  // === Lifecycle ===
  @override
  void initState() {
    super.initState();
    reader = context.reader;
    reader._imageViewController = this;
    itemPositionsListener.itemPositions.addListener(_onScrollPosition);
    _resetToChapter(reader.chapter);
  }

  @override
  void dispose() {
    itemPositionsListener.itemPositions.removeListener(_onScrollPosition);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // User-driven chapter switch (chapter picker, "next chapter" button,
    // keyboard, etc.) — re-seed the buffer with that chapter's images.
    if (reader.chapter != _currentChapter) {
      _resetToChapter(reader.chapter);
    }
  }

  /// Replace the spliced buffer with the images of [chapter] (1-based).
  /// Resets [reader.images] to that chapter so the page indicator shows
  /// "1 / chapterLength" and `maxPage` reflects the new chapter's length.
  void _resetToChapter(int chapter) {
    final baseImages = reader.images ?? const <String>[];
    _allImages = List<String>.from(baseImages);
    _chapterStarts = [0];
    _loadedChapters = chapter;
    _currentChapter = chapter;
    cached = List<bool>.filled(_allImages.length, false);
    reader.page = 1;
    reader.images = _currentChapterImages();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = (reader.page - 1).clamp(0, _allImages.length - 1);
      itemScrollController.jumpTo(index: target);
      _precache(reader.page);
    });
  }

  // === Seamless pre-load ===
  Future<void> _appendNextChapter() async {
    if (_loadingNextChapter) return;
    if (reader.isLastChapterOfGroup) return;
    if (!mounted) return;
    _loadingNextChapter = true;
    final nextChapter = _loadedChapters + 1;
    try {
      final list = await _fetchChapterImages(nextChapter);
      if (!mounted) return;
      if (list == null || list.isEmpty) return;
      setState(() {
        _allImages.addAll(list);
        _chapterStarts.add(_allImages.length - list.length);
        _loadedChapters = nextChapter;
        cached = List<bool>.from(cached)
          ..addAll(List<bool>.filled(list.length, false));
      });
    } finally {
      _loadingNextChapter = false;
    }
  }

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

  // === Scroll position handling ===
  void _onScrollPosition() {
    if (!mounted) return;
    if (_allImages.isEmpty) return;
    final positions = itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    // The ListView has no leading or trailing spacers; image index == item
    // index.
    final globalIndex = positions.first.index.clamp(0, _allImages.length - 1);
    final info = _chapterAndPageOf(globalIndex);
    if (info == null) return;
    final (chapter, pageInChapter) = info;
    if (chapter != _currentChapter) {
      // User has crossed into the next (or previous) chapter. Update the
      // displayed chapter / images synchronously so the page indicator
      // and `maxPage` reflect the new chapter.
      setState(() {
        _currentChapter = chapter;
        reader.chapter = chapter;
        reader.images = _currentChapterImages();
      });
    }
    if (pageInChapter != reader.page) {
      reader.setPage(pageInChapter);
      context.readerScaffold.update();
    }
    // 1-based for precache (see [_preDownloadImage])
    _precache(globalIndex + 1);
    // Pre-load the next chapter if the user is near the bottom of the
    // currently loaded buffer.
    if (!_loadingNextChapter &&
        !reader.isLastChapterOfGroup &&
        globalIndex >= _allImages.length - 1 - _kPreloadAhead) {
      _appendNextChapter();
    }
  }

  void _precache(int current) {
    final total = _allImages.length;
    if (cached.length < total) {
      cached = List<bool>.from(cached)
        ..addAll(List<bool>.filled(total - cached.length, false));
    }
    for (int i = current + 1; i <= current + preCacheCount; i++) {
      if (i >= 1 && i <= total && !cached[i - 1]) {
        _preDownloadImage(i, context);
        cached[i - 1] = true;
      }
    }
  }

  // === Smooth scroll + mouse wheel ===
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

  bool onScaleUpdate([double? scale]) {
    var isZoomedIn = (scale ?? photoViewController.scale) != 1.0;
    if (isZoomedIn != this.isZoomedIn) {
      setState(() {
        this.isZoomedIn = isZoomedIn;
      });
    }
    return false;
  }

  // === Build ===
  @override
  Widget build(BuildContext context) {
    Widget widget = ScrollablePositionedList.builder(
      initialScrollIndex: (reader.page - 1).clamp(0, _allImages.length - 1),
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      itemCount: _allImages.length,
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
        double? width, height;
        if (reader.mode == ReaderMode.continuousLeftToRight ||
            reader.mode == ReaderMode.continuousRightToLeft) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }
        return ColoredBox(
          color: context.colorScheme.surface,
          child: ComicImage(
            filterQuality: FilterQuality.medium,
            image: _imageForAllIndex(index, context),
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
        return false;
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

  // === _ImageViewController interface ===
  @override
  Future<void> animateToPage(int page) {
    return itemScrollController.scrollTo(
      index: (page - 1).clamp(0, _allImages.length - 1),
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
    // page is 1-based; the ListView is 0-based. Clamp to a valid index.
    final index = (page - 1).clamp(0, _allImages.length - 1);
    itemScrollController.jumpTo(index: index);
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
