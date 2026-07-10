import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

/// A saved quick-search entry.
///
/// The user long-presses a tag or author on the comic details page and
/// saves it as a quick search. Tapping the entry later jumps straight to
/// the search results in the originating source.
class QuickSearchEntry {
  final String keyword;

  final String sourceKey;

  final String sourceName;

  /// "tag" or "author".
  final String searchType;

  final DateTime time;

  QuickSearchEntry({
    required this.keyword,
    required this.sourceKey,
    required this.sourceName,
    required this.searchType,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'keyword': keyword,
        'sourceKey': sourceKey,
        'sourceName': sourceName,
        'searchType': searchType,
        'time': time.toIso8601String(),
      };

  static QuickSearchEntry fromJson(Map<String, dynamic> json) {
    return QuickSearchEntry(
      keyword: json['keyword'] as String,
      sourceKey: json['sourceKey'] as String,
      sourceName: json['sourceName'] as String,
      searchType: json['searchType'] as String? ?? 'tag',
      time: json['time'] != null
          ? DateTime.parse(json['time'] as String)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is QuickSearchEntry &&
      other.keyword == keyword &&
      other.sourceKey == sourceKey;

  @override
  int get hashCode => keyword.hashCode ^ sourceKey.hashCode;
}

/// Singleton manager that persists [QuickSearchEntry] items to
/// `quick_search.json` in the app data directory.
class QuickSearchManager with ChangeNotifier {
  QuickSearchManager._create();

  static final QuickSearchManager _instance = QuickSearchManager._create();

  factory QuickSearchManager() => _instance;

  List<QuickSearchEntry> _entries = [];

  List<QuickSearchEntry> get entries => List.unmodifiable(_entries);

  Future<void> init() async {
    try {
      var file = File(FilePath.join(App.dataPath, 'quick_search.json'));
      if (await file.exists()) {
        var json = jsonDecode(await file.readAsString()) as List;
        _entries = json
            .map((e) => QuickSearchEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      Log.error("QuickSearch", "Failed to load quick search entries: $e");
    }
  }

  Future<void> _save() async {
    try {
      var file = File(FilePath.join(App.dataPath, 'quick_search.json'));
      await file.writeAsString(jsonEncode(_entries.map((e) => e.toJson()).toList()));
    } catch (e) {
      Log.error("QuickSearch", "Failed to save quick search entries: $e");
    }
    notifyListeners();
  }

  /// Adds [entry]. If an entry with the same keyword+sourceKey already
  /// exists, it is replaced.
  void add(QuickSearchEntry entry) {
    _entries.removeWhere(
        (e) => e.keyword == entry.keyword && e.sourceKey == entry.sourceKey);
    _entries.insert(0, entry);
    _save();
  }

  void remove(String keyword, String sourceKey) {
    _entries.removeWhere(
        (e) => e.keyword == keyword && e.sourceKey == sourceKey);
    _save();
  }

  void removeAt(int index) {
    if (index >= 0 && index < _entries.length) {
      _entries.removeAt(index);
      _save();
    }
  }

  bool contains(String keyword, String sourceKey) {
    return _entries.any(
        (e) => e.keyword == keyword && e.sourceKey == sourceKey);
  }
}
