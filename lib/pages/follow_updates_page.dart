import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';
import '../foundation/global_state.dart';
import 'package:venera/foundation/follow_updates.dart';

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;

  List<String> get folders => LocalFavoritesManager().followUpdateFolders;

  Map<String, dynamic>? get _pendingNotification =>
      appdata.settings["pendingUpdateNotification"];

  void getCount() {
    var f = folders;
    if (f.isEmpty) {
      _count = 0;
      return;
    }
    int count = 0;
    for (var folder in f) {
      if (!LocalFavoritesManager().folderNames.contains(folder)) continue;
      var updates = LocalFavoritesManager().getUpdates(folder);
      count += updates
          .where((c) => c.type.comicSource?.hidden != true)
          .length;
    }
    _count = count;
  }

  void updateCount() {
    setState(() {
      getCount();
    });
  }

  void _dismissNotification() {
    appdata.settings["pendingUpdateNotification"] = null;
    appdata.saveData();
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    getCount();
  }

  @override
  Widget build(BuildContext context) {
    var notification = _pendingNotification;
    return SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (notification != null) _buildNotificationBanner(context, notification),
          _buildFollowUpdatesCard(context),
        ],
      ),
    );
  }

  Widget _buildNotificationBanner(BuildContext context, Map<String, dynamic> notification) {
    var count = notification['count'] as int? ?? 0;
    var time = notification['time'] as int?;
    String timeStr = '';
    if (time != null) {
      var dt = DateTime.fromMillisecondsSinceEpoch(time);
      var now = DateTime.now();
      var diff = now.difference(dt);
      if (diff.inMinutes < 1) {
        timeStr = 'Just now'.tl;
      } else if (diff.inMinutes < 60) {
        timeStr = '${diff.inMinutes} ${'min ago'.tl}';
      } else if (diff.inHours < 24) {
        timeStr = '${diff.inHours} ${'h ago'.tl}';
      } else {
        timeStr = '${diff.inDays} ${'d ago'.tl}';
      }
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          _dismissNotification();
          context.to(() => FollowUpdatesPage());
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.notifications_active,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '@c updates'.tlParams({'c': count}),
                      style: ts.s16.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (timeStr.isNotEmpty)
                      Text(timeStr, style: ts.s12),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: _dismissNotification,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFollowUpdatesCard(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          context.to(() => FollowUpdatesPage());
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  Center(
                    child: Text('Follow Updates'.tl, style: ts.s18),
                  ),
                  const Spacer(),
                  const Icon(Icons.arrow_right),
                ],
              ),
            ).paddingHorizontal(16),
            if (_count > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                margin: const EdgeInsets.only(bottom: 16, left: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Theme.of(context).colorScheme.primaryContainer,
                ),
                child: Text(
                  '@c updates'.tlParams({
                    'c': _count,
                  }),
                  style: ts.s16,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Object? get key => 'FollowUpdatesWidget';
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage> {
  List<String> get folders => LocalFavoritesManager().followUpdateFolders;

  var updatedComics = <FavoriteItemWithUpdateInfo>[];
  var allComics = <FavoriteItemWithUpdateInfo>[];

  /// Load comics from all follow-updates folders, filtering out comics from
  /// hidden sources.
  void _loadAllFolders() {
    var f = folders;
    if (f.isEmpty) {
      allComics = [];
      updatedComics = [];
      return;
    }
    var comics = <FavoriteItemWithUpdateInfo>[];
    for (var folder in f) {
      if (!LocalFavoritesManager().folderNames.contains(folder)) continue;
      comics.addAll(LocalFavoritesManager().getComicsWithUpdatesInfo(folder));
    }
    comics = comics
        .where((c) => c.type.comicSource?.hidden != true)
        .toList();
    allComics = comics;
    sortComics();
    updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
  }

  /// Sort comics by update time in descending order with nulls at the end.
  void sortComics() {
    allComics.sort((a, b) {
      if (a.updateTime == null && b.updateTime == null) {
        return 0;
      } else if (a.updateTime == null) {
        return -1;
      } else if (b.updateTime == null) {
        return 1;
      }
      try {
        var aNums = a.updateTime!.split('-').map(int.parse).toList();
        var bNums = b.updateTime!.split('-').map(int.parse).toList();
        for (int i = 0; i < aNums.length; i++) {
          if (aNums[i] != bNums[i]) {
            return bNums[i] - aNums[i];
          }
        }
        return 0;
      } catch (_) {
        return 0;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // Clear the persistent notification when user views the page
    if (appdata.settings["pendingUpdateNotification"] != null) {
      appdata.settings["pendingUpdateNotification"] = null;
      appdata.saveData();
    }
    _loadAllFolders();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('Follow Updates'.tl)),
          if (folders.isEmpty)
            buildNotConfigured(context)
          else
            buildConfigured(context),
          SliverPadding(padding: const EdgeInsets.only(top: 8)),
          buildUpdatedComics(),
          buildAllComics(),
        ],
      ),
    );
  }

  Widget buildNotConfigured(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text("Not Configured".tl),
            ),
            Text(
              "Choose a folder to follow updates.".tl,
              style: ts.s16,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: showSelector,
              child: Text("Choose Folder".tl),
            ).paddingHorizontal(16).toAlign(Alignment.centerRight),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildConfigured(BuildContext context) {
    var folderList = folders;
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(Icons.stars_outlined),
              title: Text(folderList.join(", ")),
            ),
            Text(
              "Automatic update checking enabled.".tl,
              style: ts.s14,
            ).paddingHorizontal(16),
            Text(
              "@n folders are being tracked.".tlParams({'n': folderList.length}),
              style: ts.s14,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: showSelector,
                  child: Text("Change Folder".tl),
                ),
                FilledButton.tonal(
                  onPressed: checkNow,
                  child: Text("Check Now".tl),
                ),
                const SizedBox(width: 16),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildUpdatedComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.update),
                const SizedBox(width: 8),
                Text(
                  "Updates".tl,
                  style: ts.s18,
                ),
                const Spacer(),
                if (updatedComics.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.clear_all),
                    onPressed: () {
                      showConfirmDialog(
                        context: App.rootContext,
                        title: "Mark all as read".tl,
                        content: "Do you want to mark all as read?".tl,
                        onConfirm: () {
                          for (var comic in updatedComics) {
                            LocalFavoritesManager().markAsRead(
                              comic.id,
                              comic.type,
                            );
                          }
                          updateFollowUpdatesUI();
                          appdata.saveData();
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        if (updatedComics.isNotEmpty)
          SliverToBoxAdapter(
            child: Text(
                    "The comic will be marked as no updates as soon as you read it."
                        .tl)
                .paddingHorizontal(16)
                .paddingVertical(4),
          ),
        if (updatedComics.isNotEmpty)
          SliverGridComics(comics: updatedComics)
        else
          SliverToBoxAdapter(
            child: Row(
              children: [
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "No updates found".tl,
                        style: ts.s16,
                      ),
                    ],
                  ),
                )
              ],
            ),
          ),
      ],
    );
  }

  Widget buildAllComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.list),
                const SizedBox(width: 8),
                Text(
                  "All Comics".tl,
                  style: ts.s18,
                ),
              ],
            ),
          ),
        ),
        SliverGridComics(comics: allComics),
      ],
    );
  }

  void showSelector() {
    var allFolders = LocalFavoritesManager().folderNames;
    if (allFolders.isEmpty) {
      context.showMessage(message: "No folders available".tl);
      return;
    }
    var selectedFolders = Set<String>.from(folders);
    showDialog(
      context: App.rootContext,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "Choose Folder".tl,
            content: SizedBox(
              width: 320,
              height: 420,
              child: ListView(
                children: allFolders.map((f) {
                  return CheckboxListTile(
                    dense: true,
                    title: Text(f),
                    value: selectedFolders.contains(f),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          selectedFolders.add(f);
                        } else {
                          selectedFolders.remove(f);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() {
                    selectedFolders.clear();
                  });
                },
                child: Text("Clear".tl),
              ),
              if (folders.isNotEmpty)
                TextButton(
                  onPressed: () {
                    disable();
                    context.pop();
                  },
                  child: Text("Disable".tl),
                ),
              FilledButton(
                onPressed: selectedFolders.isEmpty
                    ? null
                    : () {
                        context.pop();
                        setFolders(selectedFolders.toList());
                      },
                child: Text("Confirm".tl),
              ),
            ],
          );
        });
      },
    );
  }

  void disable() {
    appdata.settings["followUpdatesFolders"] = null;
    appdata.settings["followUpdatesFolder"] = null;
    appdata.saveData();
    updateFollowUpdatesUI();
  }

  void setFolders(List<String> newFolders) async {
    FollowUpdatesService._cancelChecking?.call();

    for (var folder in newFolders) {
      LocalFavoritesManager().prepareTableForFollowUpdates(folder);
    }

    bool isCanceled = false;

    final progressNotifier = ValueNotifier<UpdateProgress?>(
      UpdateProgress(0, 0, 0, 0),
    );

    var dialogRoute = DialogRoute(
      context: App.rootContext,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return ContentDialog(
          title: "Checking Updates".tl,
          content: ValueListenableBuilder<UpdateProgress?>(
            valueListenable: progressNotifier,
            builder: (context, progress, _) {
              var current = progress?.current ?? 0;
              var total = progress?.total ?? 0;
              var updated = progress?.updated ?? 0;
              var errors = progress?.errors ?? 0;
              var comicName = progress?.comic?.name;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (comicName != null && !isCanceled)
                    Text(
                      comicName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s14,
                    ).paddingVertical(4),
                  LinearProgressIndicator(
                    value: total > 0 ? current / total : null,
                    backgroundColor: context.colorScheme.surfaceContainer,
                  ).paddingVertical(8),
                  Row(
                    children: [
                      Text("$current / $total", style: ts.s14),
                      const Spacer(),
                      if (updated > 0)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Row(
                            children: [
                              Icon(Icons.update, size: 16,
                                  color: context.colorScheme.primary),
                              const SizedBox(width: 4),
                              Text("$updated", style: ts.s14),
                            ],
                          ),
                        ),
                      if (errors > 0)
                        Row(
                          children: [
                            Icon(Icons.error_outline, size: 16,
                                color: context.colorScheme.error),
                            const SizedBox(width: 4),
                            Text("$errors", style: ts.s14),
                          ],
                        ),
                    ],
                  ),
                ],
              ).paddingVertical(8);
            },
          ).paddingHorizontal(16),
          actions: [
            TextButton(
              onPressed: () {
                isCanceled = true;
                Navigator.of(context, rootNavigator: true).pop();
              },
              child: Text("Cancel".tl),
            ),
          ],
        );
      },
    );

    var navigator = Navigator.of(App.rootContext, rootNavigator: true);
    navigator.push(dialogRoute);

    for (var folder in newFolders) {
      var count = LocalFavoritesManager().count(folder);
      if (count > 0) {
        await for (var progress in updateFolder(folder, true)) {
          if (isCanceled) {
            navigator.removeRoute(dialogRoute);
            progressNotifier.dispose();
            return;
          }
          progressNotifier.value = progress;
        }
      }
    }

    navigator.removeRoute(dialogRoute);
    progressNotifier.dispose();

    setState(() {
      appdata.settings["followUpdatesFolders"] = newFolders;
      appdata.settings["followUpdatesFolder"] = null;
      _loadAllFolders();
    });
    appdata.saveData();
  }

  void checkNow() async {
    FollowUpdatesService._cancelChecking?.call();

    bool isCanceled = false;

    final progressNotifier = ValueNotifier<UpdateProgress?>(
      UpdateProgress(0, 0, 0, 0),
    );

    var dialogRoute = DialogRoute(
      context: App.rootContext,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return ContentDialog(
          title: "Checking Updates".tl,
          content: ValueListenableBuilder<UpdateProgress?>(
            valueListenable: progressNotifier,
            builder: (context, progress, _) {
              var current = progress?.current ?? 0;
              var total = progress?.total ?? 0;
              var updated = progress?.updated ?? 0;
              var errors = progress?.errors ?? 0;
              var comicName = progress?.comic?.name;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (comicName != null && !isCanceled)
                    Text(
                      comicName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s14,
                    ).paddingVertical(4),
                  LinearProgressIndicator(
                    value: total > 0 ? current / total : null,
                    backgroundColor: context.colorScheme.surfaceContainer,
                  ).paddingVertical(8),
                  Row(
                    children: [
                      Text("$current / $total", style: ts.s14),
                      const Spacer(),
                      if (updated > 0)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Row(
                            children: [
                              Icon(Icons.update, size: 16,
                                  color: context.colorScheme.primary),
                              const SizedBox(width: 4),
                              Text("$updated", style: ts.s14),
                            ],
                          ),
                        ),
                      if (errors > 0)
                        Row(
                          children: [
                            Icon(Icons.error_outline, size: 16,
                                color: context.colorScheme.error),
                            const SizedBox(width: 4),
                            Text("$errors", style: ts.s14),
                          ],
                        ),
                    ],
                  ),
                ],
              ).paddingHorizontal(0).paddingVertical(8);
            },
          ).paddingHorizontal(16),
          actions: [
            TextButton(
              onPressed: () {
                isCanceled = true;
                Navigator.of(context, rootNavigator: true).pop();
              },
              child: Text("Cancel".tl),
            ),
          ],
        );
      },
    );

    var navigator = Navigator.of(App.rootContext, rootNavigator: true);
    navigator.push(dialogRoute);

    int updated = 0;

    for (var folder in folders) {
      if (!LocalFavoritesManager().folderNames.contains(folder)) continue;
      await for (var progress in updateFolder(folder, true)) {
        if (isCanceled) {
          navigator.removeRoute(dialogRoute);
          progressNotifier.dispose();
          return;
        }
        progressNotifier.value = progress;
        updated += progress.updated;
      }
    }

    navigator.removeRoute(dialogRoute);
    progressNotifier.dispose();

    if (updated > 0) {
      GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
      updateComics();
    }
  }

  void updateComics() {
    setState(() {
      _loadAllFolders();
    });
  }

  @override
  Object? get key => 'FollowUpdatesPage';
}

/// Background service for checking updates
abstract class FollowUpdatesService {
  static bool _isChecking = false;

  static void Function()? _cancelChecking;

  static bool _isInitialized = false;

  static void _check() async {
    if (_isChecking) {
      return;
    }
    var folders = LocalFavoritesManager().followUpdateFolders;
    if (folders.isEmpty) {
      return;
    }
    bool isCanceled = false;
    _cancelChecking = () {
      isCanceled = true;
    };

    _isChecking = true;

    while (DataSync().isDownloading) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    int updated = 0;
    try {
      for (var folder in folders) {
        if (!LocalFavoritesManager().existsFolder(folder)) continue;
        await for (var progress in updateFolder(folder, false)) {
          if (isCanceled) {
            return;
          }
          updated += progress.updated;
        }
      }
    } finally {
      _cancelChecking = null;
      _isChecking = false;
      if (updated > 0) {
        updateFollowUpdatesUI();
        _showUpdateNotification(updated);
      }
    }
  }

  static void _showUpdateNotification(int count) {
    if (count <= 0) return;
    // Re-count updates excluding comics from hidden sources.
    var visibleCount = 0;
    for (var folder in LocalFavoritesManager().followUpdateFolders) {
      visibleCount += LocalFavoritesManager()
          .getUpdates(folder)
          .where((c) => c.type.comicSource?.hidden != true)
          .length;
    }
    if (visibleCount <= 0) return;
    // Store as persistent notification so it survives app restarts
    // and stays visible until the user acts on it.
    appdata.settings['pendingUpdateNotification'] = {
      'count': visibleCount,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
    appdata.saveData();
    updateFollowUpdatesUI();
  }

  /// Initialize the checker.
  static void initChecker() {
    if (_isInitialized) return;
    _isInitialized = true;
    // Make sure all follow-updates folder tables have the required columns.
    for (var folder in LocalFavoritesManager().followUpdateFolders) {
      if (LocalFavoritesManager().existsFolder(folder)) {
        LocalFavoritesManager().prepareTableForFollowUpdates(folder, false);
      }
    }
    _check();
    DataSync().addListener(updateFollowUpdatesUI);
    // A short interval will not affect the performance since every comic has a check time.
    Timer.periodic(const Duration(minutes: 10), (timer) {
      _check();
    });
  }
}

/// Update the UI of follow updates.
void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  GlobalState.findOrNull<_FollowUpdatesPageState>()?.updateComics();
}
