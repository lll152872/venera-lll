part of 'comic_source.dart';

/// 书源由用户脚本提供，字段类型写错不应让整个 App 崩溃。
/// 下面这组转换只做归一化，不改变正常数据的语义。
String? _asStr(dynamic v) => v == null ? null : (v is String ? v : v.toString());

String _asStrOr(dynamic v, String def) =>
    v == null ? def : (v is String ? v : v.toString());

int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

List<String> _asStrList(dynamic v) {
  if (v is! Iterable) return const [];
  return v.map((e) => e.toString()).toList();
}

bool? _asBool(dynamic v) {
  if (v == null) return null;
  if (v is bool) return v;
  if (v is num) return v != 0;
  var s = v.toString().toLowerCase();
  if (s == 'true' || s == '1') return true;
  if (s == 'false' || s == '0') return false;
  return null;
}

/// 时间字段容错：数字按秒/毫秒时间戳格式化为 `yyyy-MM-dd HH:mm:ss`，其余原样转字符串。
String? _asTimeStr(dynamic v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num) {
    var n = v.toInt();
    if (n <= 0) return null;
    return n < 10000000000
        ? DateTime.fromMillisecondsSinceEpoch(
            n * 1000,
          ).toString().substring(0, 19)
        : DateTime.fromMillisecondsSinceEpoch(n).toString().substring(0, 19);
  }
  return v.toString();
}

class Comment {
  final String userName;
  final String? avatar;
  final String content;
  final String? time;
  final int? replyCount;
  final String? id;
  int? score;
  final bool? isLiked;
  int? voteStatus; // 1: upvote, -1: downvote, 0: none

  static String? parseTime(dynamic value) => _asTimeStr(value);

  Comment.fromJson(Map<String, dynamic> json)
      : userName = _asStrOr(json["userName"], ""),
        avatar = _asStr(json["avatar"]),
        content = _asStrOr(json["content"], ""),
        time = _asTimeStr(json["time"]),
        replyCount = _asInt(json["replyCount"]),
        id = json["id"]?.toString(),
        score = _asInt(json["score"]),
        isLiked = _asBool(json["isLiked"]),
        voteStatus = _asInt(json["voteStatus"]);
}

class Comic {
  final String title;

  final String cover;

  final String id;

  final String? subtitle;

  final List<String>? tags;

  final String description;

  final String sourceKey;

  final int? maxPage;

  final String? language;

  final String? favoriteId;

  /// 0-5
  final double? stars;

  const Comic(
    this.title,
    this.cover,
    this.id,
    this.subtitle,
    this.tags,
    this.description,
    this.sourceKey,
    this.maxPage,
    this.language,
  )   : favoriteId = null,
        stars = null;

  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "maxPage": maxPage,
      "language": language,
      "favoriteId": favoriteId,
    };
  }

  Comic.fromJson(Map<String, dynamic> json, this.sourceKey)
      : title = _asStrOr(json["title"], ""),
        subtitle = _asStr(json["subtitle"]) ?? _asStr(json["subTitle"]) ?? "",
        cover = _asStrOr(json["cover"], ""),
        id = _asStrOr(json["id"], ""),
        tags = _asStrList(json["tags"]),
        description = _asStrOr(json["description"], ""),
        maxPage = _asInt(json["maxPage"]),
        language = _asStr(json["language"]),
        favoriteId = _asStr(json["favoriteId"]),
        stars = _asDouble(json["stars"]);

  @override
  bool operator ==(Object other) {
    if (other is! Comic) return false;
    return other.id == id && other.sourceKey == sourceKey;
  }

  @override
  int get hashCode => id.hashCode ^ sourceKey.hashCode;

  @override
  toString() => "$sourceKey@$id";
}

class ComicID {
  final ComicType type;

  final String id;

  const ComicID(this.type, this.id);

  @override
  bool operator ==(Object other) {
    if (other is! ComicID) return false;
    return other.type == type && other.id == id;
  }

  @override
  int get hashCode => type.hashCode ^ id.hashCode;

  @override
  String toString() => "$type@$id";
}

class ComicDetails with HistoryMixin {
  @override
  final String title;

  @override
  final String? subTitle;

  @override
  final String cover;

  final String? description;

  final Map<String, List<String>> tags;

  /// id-name
  final ComicChapters? chapters;

  final List<String>? thumbnails;

  final List<Comic>? recommend;

  final String sourceKey;

  final String comicId;

  final bool? isFavorite;

  final String? subId;

  final bool? isLiked;

  final int? likesCount;

  final int? commentCount;

  final String? uploader;

  final String? uploadTime;

  final String? updateTime;

  final String? url;

  final double? stars;

  @override
  final int? maxPage;

  final List<Comment>? comments;

  static Map<String, List<String>> _generateMap(dynamic map) {
    var res = <String, List<String>>{};
    if (map is! Map) return res;
    map.forEach((key, value) {
      if (key == null || value == null) return;
      List<String> list = value is Iterable
          ? value.map((e) => e.toString()).toList()
          : [value.toString()];
      list = list.where((e) => e.isNotEmpty).toList();
      if (list.isNotEmpty) {
        res[key.toString()] = list;
      }
    });
    return res;
  }

  ComicDetails.fromJson(Map<String, dynamic> json)
      : title = _asStrOr(json["title"], ""),
        subTitle = _asStr(json["subtitle"]),
        cover = _asStrOr(json["cover"], ""),
        description = _asStr(json["description"]),
        tags = _generateMap(json["tags"]),
        chapters = ComicChapters.fromJsonOrNull(json["chapters"]),
        sourceKey = _asStrOr(json["sourceKey"], ""),
        comicId = _asStrOr(json["comicId"], ""),
        thumbnails = json["thumbnails"] is Iterable
            ? (json["thumbnails"] as Iterable)
                  .map((e) => e.toString())
                  .toList()
            : null,
        recommend = json["recommend"] is Iterable
            ? (json["recommend"] as Iterable)
                  .whereType<Map>()
                  .map(
                    (e) => Comic.fromJson(
                      Map<String, dynamic>.from(e),
                      _asStrOr(json["sourceKey"], ""),
                    ),
                  )
                  .toList()
            : null,
        isFavorite = _asBool(json["isFavorite"]),
        subId = _asStr(json["subId"]),
        likesCount = _asInt(json["likesCount"]),
        isLiked = _asBool(json["isLiked"]),
        commentCount = _asInt(json["commentCount"]),
        uploader = _asStr(json["uploader"]),
        uploadTime = _asTimeStr(json["uploadTime"]),
        updateTime = _asTimeStr(json["updateTime"]),
        url = _asStr(json["url"]),
        stars = _asDouble(json["stars"]),
        maxPage = _asInt(json["maxPage"]),
        comments = json["comments"] is Iterable
            ? (json["comments"] as Iterable)
                  .whereType<Map>()
                  .map((e) => Comment.fromJson(Map<String, dynamic>.from(e)))
                  .toList()
            : null;

  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "subTitle": subTitle,
      "cover": cover,
      "description": description,
      "tags": tags,
      "chapters": chapters,
      "thumbnails": thumbnails,
      "recommend": null,
      "sourceKey": sourceKey,
      "comicId": comicId,
      "isFavorite": isFavorite,
      "subId": subId,
      "isLiked": isLiked,
      "likesCount": likesCount,
      "commentsCount": commentCount,
      "uploader": uploader,
      "uploadTime": uploadTime,
      "updateTime": updateTime,
      "url": url,
    };
  }

  @override
  HistoryType get historyType => HistoryType(sourceKey.hashCode);

  @override
  String get id => comicId;

  ComicType get comicType => ComicType(sourceKey.hashCode);

  /// Convert tags map to plain list
  List<String> get plainTags {
    var res = <String>[];
    tags.forEach((key, value) {
      res.addAll(value.map((e) => "$key:$e"));
    });
    return res;
  }

  /// Find the first author tag
  String? findAuthor() {
    var authorNamespaces = [
      "author",
      "authors",
      "artist",
      "artists",
      "作者",
      "画师"
    ];
    for (var entry in tags.entries) {
      if (authorNamespaces.contains(entry.key.toLowerCase()) &&
          entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }

  String? _validateUpdateTime(String time) {
    time = time.split(" ").first;
    var segments = time.split("-");
    if (segments.length != 3) return null;
    var year = int.tryParse(segments[0]);
    var month = int.tryParse(segments[1]);
    var day = int.tryParse(segments[2]);
    if (year == null || month == null || day == null) return null;
    if (year < 2000 || year > 3000) return null;
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    return "$year-$month-$day";
  }

  String? findUpdateTime() {
    if (updateTime != null) {
      return _validateUpdateTime(updateTime!);
    }
    const acceptedNamespaces = [
      "更新",
      "最後更新",
      "最后更新",
      "update",
      "last update",
    ];
    for (var entry in tags.entries) {
      if (acceptedNamespaces.contains(entry.key.toLowerCase()) &&
          entry.value.isNotEmpty) {
        var value = entry.value.first;
        return _validateUpdateTime(value);
      }
    }
    return null;
  }
}

class ArchiveInfo {
  final String title;
  final String description;
  final String id;

  ArchiveInfo.fromJson(Map<String, dynamic> json)
      : title = json["title"],
        description = json["description"],
        id = json["id"];
}

class ComicChapters {
  final Map<String, String>? _chapters;

  final Map<String, Map<String, String>>? _groupedChapters;

  /// Create a ComicChapters object with a flat map
  const ComicChapters(Map<String, String> this._chapters)
      : _groupedChapters = null;

  /// Create a ComicChapters object with a grouped map
  const ComicChapters.grouped(
      Map<String, Map<String, String>> this._groupedChapters)
      : _chapters = null;

  factory ComicChapters.fromJson(dynamic json) {
    if (json is! Map) throw ArgumentError("Invalid json type");
    var chapters = <String, String>{};
    var groupedChapters = <String, Map<String, String>>{};
    for (var entry in json.entries) {
      var key = entry.key;
      var value = entry.value;
      if (key is! String) throw ArgumentError("Invalid key type");
      if (value is Map) {
        var m = <String, String>{};
        value.forEach((k, v) {
          if (k == null || v == null) return;
          m[k.toString()] = v.toString();
        });
        groupedChapters[key] = m;
      } else {
        chapters[key] = value.toString();
      }
    }
    if (chapters.isNotEmpty) {
      return ComicChapters(chapters);
    } else if (groupedChapters.isNotEmpty) {
      return ComicChapters.grouped(groupedChapters);
    } else {
      // return a empty list.
      return ComicChapters(chapters);
    }
  }

  static fromJsonOrNull(dynamic json) {
    if (json == null) return null;
    return ComicChapters.fromJson(json);
  }

  Map<String, dynamic> toJson() {
    if (_chapters != null) {
      return _chapters;
    } else {
      return _groupedChapters!;
    }
  }

  /// Whether the chapters are grouped
  bool get isGrouped => _groupedChapters != null;

  /// All group names
  Iterable<String> get groups => _groupedChapters?.keys ?? [];

  /// All chapters.
  /// If the chapters are grouped, all groups will be merged.
  Map<String, String> get allChapters {
    if (_chapters != null) return _chapters;
    var res = <String, String>{};
    for (var entry in _groupedChapters!.values) {
      res.addAll(entry);
    }
    return res;
  }

  /// Get a group of chapters by name
  Map<String, String> getGroup(String group) {
    return _groupedChapters![group] ?? {};
  }

  /// Get a group of chapters by index(0-based)
  Map<String, String> getGroupByIndex(int index) {
    return _groupedChapters!.values.elementAt(index);
  }

  /// Get total number of chapters
  int get length {
    return isGrouped
        ? _groupedChapters!.values.map((e) => e.length).reduce((a, b) => a + b)
        : _chapters!.length;
  }

  /// Get the number of groups
  int get groupCount => _groupedChapters?.length ?? 0;

  /// Iterate all chapter ids
  Iterable<String> get ids sync* {
    if (isGrouped) {
      for (var entry in _groupedChapters!.values) {
        yield* entry.keys;
      }
    } else {
      yield* _chapters!.keys;
    }
  }

  /// Iterate all chapter titles
  Iterable<String> get titles sync* {
    if (isGrouped) {
      for (var entry in _groupedChapters!.values) {
        yield* entry.values;
      }
    } else {
      yield* _chapters!.values;
    }
  }

  String? operator [](String key) {
    if (isGrouped) {
      for (var entry in _groupedChapters!.values) {
        if (entry.containsKey(key)) return entry[key];
      }
      return null;
    } else {
      return _chapters![key];
    }
  }
}

class PageJumpTarget {
  final String sourceKey;

  final String page;

  final Map<String, dynamic>? attributes;

  const PageJumpTarget(this.sourceKey, this.page, this.attributes);

  static PageJumpTarget parse(String sourceKey, dynamic value) {
    if (value is Map) {
      if (value['page'] != null) {
        return PageJumpTarget(
          sourceKey,
          value["page"] ?? "search",
          value["attributes"],
        );
      } else if (value["action"] != null) {
        // old version `onClickTag`
        var page = value["action"];
        if (page == "search") {
          return PageJumpTarget(
            sourceKey,
            "search",
            {
              "text": value["keyword"],
            },
          );
        } else if (page == "category") {
          return PageJumpTarget(
            sourceKey,
            "category",
            {
              "category": value["keyword"],
              "param": value["param"],
            },
          );
        } else {
          return PageJumpTarget(sourceKey, page, null);
        }
      }
    } else if (value is String) {
      // old version string encoding. search: `search:keyword`, category: `category:keyword` or `category:keyword@param`
      var segments = value.split(":");
      var page = segments[0];
      if (page == "search") {
        return PageJumpTarget(
          sourceKey,
          "search",
          {
            "text": segments[1],
          },
        );
      } else if (page == "category") {
        var c = segments[1];
        if (c.contains('@')) {
          var parts = c.split('@');
          return PageJumpTarget(
            sourceKey,
            "category",
            {
              "category": parts[0],
              "param": parts[1],
            },
          );
        } else {
          return PageJumpTarget(
            sourceKey,
            "category",
            {
              "category": c,
            },
          );
        }
      } else {
        return PageJumpTarget(sourceKey, page, null);
      }
    }
    return PageJumpTarget(sourceKey, "Invalid Data", null);
  }

  void jump(BuildContext context) {
    if (page == "search") {
      context.to(
        () => SearchResultPage(
          text: attributes?["text"] ?? attributes?["keyword"] ?? "",
          sourceKey: sourceKey,
          options: List.from(attributes?["options"] ?? []),
        )
      );
    } else if (page == "category") {
      var key = ComicSource.find(sourceKey)!.categoryData!.key;
      context.to(
        () => CategoryComicsPage(
          categoryKey: key,
          category: attributes?["category"] ??
              (throw ArgumentError("Category name is required")),
          options: List.from(attributes?["options"] ?? []),
          param: attributes?["param"],
        ),
      );
    } else {
      Log.error("Page Jump", "Unknown page: $page");
    }
  }
}
