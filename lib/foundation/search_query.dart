import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

/// Parses a search query string with optional syntax and provides
/// client-side filtering on [Comic] results returned by sources.
///
/// Supported syntax:
///   `keyword`        — plain search term, sent to the source as-is.
///   `-term`          — exclude results whose text blob contains *term*.
///   `"exact phrase"` — require the phrase to appear as-is (not split).
///   `tag:value`      — only keep results whose tags contain *value*.
///   `-tag:value`     — exclude results whose tags contain *value*.
///   `author:value`   — only keep results whose author field contains *value*.
///   `-author:value`  — exclude results whose author field contains *value*.
///
/// Tokens that don't match any special syntax are joined with spaces
/// and become [cleanKeyword], which is what gets sent to the source.
class SearchQuery {
  /// The keyword to send to the source (special syntax stripped).
  final String cleanKeyword;

  /// Lowercased terms that must NOT appear anywhere in the comic's text.
  final List<String> excludes;

  /// Lowercased phrases that MUST appear (not split into words).
  final List<String> exactPhrases;

  /// (field, value) pairs for include filters, e.g. ("tag", "action").
  final List<MapEntry<String, String>> fieldFilters;

  /// (field, value) pairs for exclude filters, e.g. ("tag", "ntr").
  final List<MapEntry<String, String>> excludeFieldFilters;

  /// True when there are client-side filters to apply.
  bool get hasFilters =>
      excludes.isNotEmpty ||
      exactPhrases.isNotEmpty ||
      fieldFilters.isNotEmpty ||
      excludeFieldFilters.isNotEmpty;

  const SearchQuery._({
    required this.cleanKeyword,
    this.excludes = const [],
    this.exactPhrases = const [],
    this.fieldFilters = const [],
    this.excludeFieldFilters = const [],
  });

  /// Parse [input] into a [SearchQuery].
  /// If the input contains no special syntax, [cleanKeyword] equals the
  /// trimmed input and [hasFilters] is false — zero overhead.
  static SearchQuery parse(String input) {
    final excludes = <String>[];
    final exactPhrases = <String>[];
    final fieldFilters = <MapEntry<String, String>>[];
    final excludeFieldFilters = <MapEntry<String, String>>[];
    final keywordParts = <String>[];

    // 1. Extract "exact phrases" first so they don't get split by whitespace.
    final quoteRegex = RegExp(r'"([^"]*)"');
    for (final m in quoteRegex.allMatches(input)) {
      final phrase = m.group(1)!;
      if (phrase.isNotEmpty) {
        exactPhrases.add(phrase.toLowerCase());
        keywordParts.add(phrase); // also send to source as plain text
      }
    }
    String remaining = input.replaceAll(quoteRegex, ' ');

    // 2. Tokenise by whitespace.
    final tokens = remaining
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    for (final token in tokens) {
      if (token.startsWith('-')) {
        final term = token.substring(1);
        if (term.isEmpty) continue;

        final entry = _parseField(term);
        if (entry != null) {
          excludeFieldFilters.add(entry);
        } else {
          excludes.add(term.toLowerCase());
        }
      } else {
        final entry = _parseField(token);
        if (entry != null) {
          fieldFilters.add(entry);
        } else {
          keywordParts.add(token);
        }
      }
    }

    var clean = keywordParts.join(' ').trim();
    // If everything was stripped (e.g. user typed only filters), fall back
    // to the original input so the source gets something to search with.
    if (clean.isEmpty && input.trim().isNotEmpty) {
      clean = input.trim();
    }

    return SearchQuery._(
      cleanKeyword: clean,
      excludes: excludes,
      exactPhrases: exactPhrases,
      fieldFilters: fieldFilters,
      excludeFieldFilters: excludeFieldFilters,
    );
  }

  /// Try to parse `field:value` into a MapEntry. Returns null if the token
  /// is not a recognised field filter.
  static MapEntry<String, String>? _parseField(String token) {
    final idx = token.indexOf(':');
    if (idx <= 0 || idx == token.length - 1) return null;
    final field = token.substring(0, idx).toLowerCase();
    final value = token.substring(idx + 1).toLowerCase();
    if (value.isEmpty) return null;
    if (field == 'tag' || field == 'author') {
      return MapEntry(field, value);
    }
    return null;
  }

  /// Returns true if [comic] passes all client-side filters.
  bool matches(Comic comic) {
    if (!hasFilters) return true;

    final tags = comic.tags ?? <String>[];
    final titleLower = comic.title.toLowerCase();
    final subtitleLower = comic.subtitle?.toLowerCase() ?? '';
    final descLower = comic.description.toLowerCase();

    // Full-text blob for exclude / exact-phrase matching.
    final blob = StringBuffer()
      ..write(titleLower)
      ..write(' ')
      ..write(subtitleLower)
      ..write(' ')
      ..write(descLower)
      ..write(' ');
    for (final t in tags) {
      blob.write(t.toLowerCase());
      blob.write(' ');
    }
    final blobStr = blob.toString();

    // Excludes (full-text)
    for (final ex in excludes) {
      if (blobStr.contains(ex)) return false;
    }

    // Exact phrases
    for (final phrase in exactPhrases) {
      if (!blobStr.contains(phrase)) return false;
    }

    // Field include filters
    for (final f in fieldFilters) {
      if (!_fieldMatches(f, tags, subtitleLower, descLower)) {
        return false;
      }
    }

    // Field exclude filters
    for (final f in excludeFieldFilters) {
      if (_fieldMatches(f, tags, subtitleLower, descLower)) {
        return false;
      }
    }

    return true;
  }

  static bool _fieldMatches(
    MapEntry<String, String> f,
    List<String> tags,
    String subtitleLower,
    String descLower,
  ) {
    switch (f.key) {
      case 'tag':
        for (final t in tags) {
          if (t.toLowerCase().contains(f.value)) return true;
        }
        return false;
      case 'author':
        return subtitleLower.contains(f.value) || descLower.contains(f.value);
      default:
        return false;
    }
  }

  /// Filter a [Res<List<Comic>>] in-place (returns a new [Res]).
  /// If no filters are active, returns [res] unchanged.
  Res<List<Comic>> filterResult(Res<List<Comic>> res) {
    if (!hasFilters || res.error) return res;
    final filtered = res.data.where(matches).toList();
    return Res(filtered, subData: res.subData);
  }
}
