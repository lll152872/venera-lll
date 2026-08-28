import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/search_query.dart';

/// 搜索增强 tag 层（SearchQuery）解析逻辑测试
/// 覆盖 `tag:` 语法下推给书源（firstTagFilter）与客户端过滤的解析行为
void main() {
  group('SearchQuery.parse - tag: 语法', () {
    test('纯 tag: 搜索 → firstTagFilter 取到标签', () {
      final query = SearchQuery.parse('tag:巨乳');
      expect(query.firstTagFilter, '巨乳');
      // cleanKeyword 带原有回退语义（回退为原始输入）；下推书源用 plainKeyword
      expect(query.cleanKeyword, 'tag:巨乳');
      expect(query.hasFilters, isTrue);
      expect(query.fieldFilters.length, 1);
      expect(query.fieldFilters.first.key, 'tag');
    });

    test('tag: + 普通关键词 → 标签下推书源，剩余词作 keyword', () {
      final query = SearchQuery.parse('tag:巨乳 姐姐');
      expect(query.firstTagFilter, '巨乳');
      expect(query.cleanKeyword, '姐姐');
    });

    test('多个 tag: 过滤 → 首个下推书源，其余客户端兜底', () {
      final query = SearchQuery.parse('tag:巨乳 tag:人妻');
      expect(query.firstTagFilter, '巨乳');
      expect(query.fieldFilters.length, 2);
    });

    test('-tag: 是排除过滤器 → 不参与 firstTagFilter 下推', () {
      final query = SearchQuery.parse('-tag:ntr 姐姐');
      expect(query.firstTagFilter, isNull);
      expect(query.excludeFieldFilters.length, 1);
      expect(query.excludeFieldFilters.first.key, 'tag');
      expect(query.cleanKeyword, '姐姐');
    });

    test('author: 不算 tag 过滤 → firstTagFilter 为 null', () {
      final query = SearchQuery.parse('author:某某');
      expect(query.firstTagFilter, isNull);
      expect(query.fieldFilters.first.key, 'author');
    });

    test('无特殊语法的普通搜索 → firstTagFilter 为 null，零开销', () {
      final query = SearchQuery.parse('姐姐');
      expect(query.firstTagFilter, isNull);
      expect(query.hasFilters, isFalse);
      expect(query.cleanKeyword, '姐姐');
    });

    test('tag: 值统一转小写（与客户端过滤行为一致）', () {
      final query = SearchQuery.parse('tag:Vanilla');
      expect(query.firstTagFilter, 'vanilla');
    });

    test('纯 tag: 时 plainKeyword 为空串（不回退为语法字面量），下推书源不会带上 tag: 前缀', () {
      final query = SearchQuery.parse('tag:巨乳');
      expect(query.plainKeyword, '');
      // cleanKeyword 保持原有回退行为（普通全文通道语义不变）
      expect(query.cleanKeyword, 'tag:巨乳');
    });

    test('tag: + 普通词时 plainKeyword 只含普通词', () {
      final query = SearchQuery.parse('tag:巨乳 姐姐 -ntr');
      expect(query.plainKeyword, '姐姐');
      expect(query.cleanKeyword, '姐姐');
    });
  });
}
