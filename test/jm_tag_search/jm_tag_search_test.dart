import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/search_query.dart';

/// JM（禁漫天堂）tag 搜索集成测试。
///
/// 跑**真实的 `book source/jm.js`**（QuickJS 引擎），只 mock 掉两个外部依赖：
///   1. HTTP 层 —— `sendMessage({method: 'http'})` 拦截，返回按 JM 协议
///      （AES-ECB + base64）加密的罐头 JSON，并记录所有请求 URL 供断言；
///   2. Convert 层 —— utf8/md5/base64/aes-ecb 用 Dart 实现（对照生产
///      `js_engine.dart` 的 `_convert` 行为）。
///
/// 验证完整管线（与 SearchResultPage.loadPage 相同的分支逻辑）：
///   `keyword tag:xxx` → SearchQuery.parse → firstTagFilter 下推
///   → jm.search.tagSearch（main_tag=3）→ stripFirstTagFilter → filterResult
///
/// 运行前置：PATH 需含 app 构建产物目录（flutter_qjs_plugin.dll 所在），如
///   $env:Path = "build\windows\x64\runner\Release;$env:Path"
///   flutter test test/jm_tag_search/
void main() {
  late _JmHarness harness;

  /// 罐头 JM 搜索响应：2 本漫画，tags 只有 JM 分类（"短篇"/"連載"），
  /// 与真实 JM search API 一致 —— 搜索结果的 tags **不含实际标签**（全彩等）。
  const cannedSearchJson = '''
    {
      "total": 2,
      "content": [
        {
          "id": 441686,
          "author": "测试作者A",
          "name": "全彩后宫测试本(上)",
          "description": "这是用于测试的描述",
          "category": {"title": "短篇"},
          "category_sub": {"title": ""}
        },
        {
          "id": 441687,
          "author": "测试作者B",
          "name": "全彩后宫测试本(下)",
          "description": "这是用于测试的描述2",
          "category": {"title": "連載"},
          "category_sub": {"title": ""}
        }
      ]
    }''';

  setUpAll(() async {
    harness = _JmHarness();
    await harness.init();
  });

  tearDownAll(() {
    harness.dispose();
  });

  setUp(() {
    // 每个用例灌入罐头搜索响应
    harness.searchResponseJson = cannedSearchJson;
    harness.httpRequests.clear();
  });

  group('jm.js search.load（普通全文搜索，不应带 main_tag）', () {
    test('构造正确的搜索 URL 并解析结果', () async {
      final res = await harness.callSearch('后宫', ['mr'], 1);

      expect(harness.httpRequests, hasLength(1));
      final url = harness.httpRequests.single.url;
      expect(url, startsWith('https://www.jmapinodeudzn.org/search?'));
      expect(url, contains('search_query=%E5%90%8E%E5%AE%AB')); // "后宫"
      expect(url, contains('o=mr'));
      // 普通搜索绝不能带 main_tag（否则变成 tag 精确搜索）
      expect(url.contains('main_tag'), isFalse);

      expect(res['comics'], hasLength(2));
      expect(res['maxPage'], 1);
      final first = res['comics'][0] as Map;
      expect(first['id'], '441686');
      expect(first['title'], '全彩后宫测试本(上)');
      expect(first['subTitle'], '测试作者A');
      // JM parseComic 的 tags 只含分类
      expect(first['tags'], ['短篇']);
    });
  });

  group('jm.js search.tagSearch（tag 精确搜索，main_tag=3）', () {
    test('keyword + tag：search_query 带「+keyword」必含语法', () async {
      final res =
          await harness.callTagSearch('全彩', '后宫', ['mr'], 1);

      expect(harness.httpRequests, hasLength(1));
      final url = harness.httpRequests.single.url;
      expect(url, contains('main_tag=3'));
      expect(url, contains('o=mr'));
      // "全彩 +后宫" 的 URL 编码（%20 被替换为 +）
      // JM 高级语法：tag 后跟「+keyword」表示必含关键词
      expect(url, contains('search_query=%E5%85%A8%E5%BD%A9+%2B%E5%90%8E%E5%AE%AB'));

      expect(res['comics'], hasLength(2));
      expect(res['maxPage'], 1);
    });

    test('纯 tag（keyword 为空）：search_query 只有标签本身', () async {
      final res = await harness.callTagSearch('全彩', '', ['mv'], 1);

      final url = harness.httpRequests.single.url;
      expect(url, contains('main_tag=3'));
      expect(url, contains('search_query=%E5%85%A8%E5%BD%A9')); // 只有 "全彩"
      expect(url.contains('%2B'), isFalse); // 没有必含语法
      expect(res['comics'], hasLength(2));
    });

    test('第 2 页带 page 参数', () async {
      await harness.callTagSearch('全彩', '', ['mr'], 2);
      expect(harness.httpRequests.single.url, contains('page=2'));
    });
  });

  group('App 搜索层管线（SearchQuery + tagSearch 下推 + 客户端兜底）', () {
    test('"后宫 tag:全彩" 下推 tag=全彩、keyword=后宫 给书源', () async {
      final query = SearchQuery.parse('后宫 tag:全彩');
      expect(query.firstTagFilter, '全彩');
      expect(query.plainKeyword, '后宫');

      final jsRes = await harness.callTagSearch(
          query.firstTagFilter!, query.plainKeyword, ['mr'], 1);

      // URL 走的是 main_tag=3 精确标签通道
      expect(harness.httpRequests.single.url, contains('main_tag=3'));

      // 转 Res<List<Comic>>（与 parser.dart 相同的转换方式）
      final res = Res(
        [for (final c in jsRes['comics'] as List) Comic.fromJson(c, 'jm')],
        subData: jsRes['maxPage'],
      );

      // 复现旧 bug：不剥离过滤器直接 filterResult ——
      // JM 结果 tags 只有分类（"短篇"），不含"全彩"，全部被滤空！
      final buggy = query.filterResult(res);
      expect(buggy.data, isEmpty,
          reason: '旧实现的双重过滤 bug：服务器已按 tag 过滤，'
              '客户端再用 tag:全彩 过滤分类字段会滤空结果');

      // 修复后：stripFirstTagFilter 剥离已下推的 tag，结果保留
      final fixed = query.stripFirstTagFilter().filterResult(res);
      expect(fixed.data, hasLength(2));
      expect(fixed.data.first.title, '全彩后宫测试本(上)');
      expect(fixed.subData, 1); // maxPage 透传
    });

    test('多个 tag: 下推首个，剩余的继续客户端过滤', () async {
      final query = SearchQuery.parse('tag:全彩 tag:短篇');
      expect(query.firstTagFilter, '全彩');
      expect(query.plainKeyword, '');

      final jsRes =
          await harness.callTagSearch(query.firstTagFilter!, '', ['mr'], 1);
      final res = Res(
        [for (final c in jsRes['comics'] as List) Comic.fromJson(c, 'jm')],
        subData: jsRes['maxPage'],
      );

      // 首个 tag 已下推；第二个 tag:短篇 仍由客户端按分类过滤 → 只剩"短篇"那本
      final result = query.stripFirstTagFilter().filterResult(res);
      expect(result.data, hasLength(1));
      expect(result.data.single.tags, contains('短篇'));
    });

    test('纯 tag 搜索词也能走下推（对应搜索页只填标签框的场景）', () async {
      final query = SearchQuery.parse('tag:全彩');
      expect(query.firstTagFilter, '全彩');
      expect(query.plainKeyword, '');

      final jsRes =
          await harness.callTagSearch(query.firstTagFilter!, '', ['mr'], 1);
      final res = Res(
        [for (final c in jsRes['comics'] as List) Comic.fromJson(c, 'jm')],
        subData: jsRes['maxPage'],
      );

      // 修复后的管线：纯 tag 搜索不再被客户端过滤器滤空
      final result = query.stripFirstTagFilter().filterResult(res);
      expect(result.data, hasLength(2));
    });
  });
}

/// 记录到的一次 HTTP 请求。
class _RecordedRequest {
  final String url;
  final Map<String, dynamic> headers;

  _RecordedRequest(this.url, this.headers);
}

/// 测试 harness：真实 QuickJS 引擎 + 真实 jm.js + mock HTTP/Convert。
class _JmHarness {
  final engine = FlutterQjs();

  /// 所有经 mock HTTP 层发出的请求（按顺序）。
  final httpRequests = <_RecordedRequest>[];

  /// 罐头搜索响应明文（每次 setUpAll 前设置）。
  String searchResponseJson = '{}';

  Future<void> init() async {
    engine.dispatch();

    // 1. 注入 mock sendMessage（替代生产 JsEngine._messageReceiver）
    final setGlobal = engine.evaluate('(key, value) => { this[key] = value; }');
    (setGlobal as JSInvokable)(['sendMessage', _messageReceiver]);
    setGlobal.free();

    // 2. 生产 init.js（提供 Network/Convert/ComicSource 基类）
    engine.evaluate(_readFile('assets/init.js'), name: '<init>');
    engine.evaluate('ComicSource.sources = {};');

    // 3. 真实 jm.js（与 parser.dart 相同的注册方式）
    final jmJs = _readFile('book source/jm.js');
    // class JM 是块级作用域，static 字段需经实例 constructor 注入；
    // 逗号表达式让 evaluate 返回 undefined，避免 flutter_qjs 为
    // 返回值（JM 实例）建立 Dart 侧引用 → close() 时报 reference leak
    engine.evaluate('(() => { $jmJs\n'
        'this["temp"] = new JM();\n'
        // apiDomains 生产由 init() 远端拉取，测试直接注入
        'this["temp"].constructor.apiDomains = ["www.jmapinodeudzn.org"];\n'
        '})(), undefined');
    engine.evaluate('ComicSource.sources.jm = this["temp"], undefined');
  }

  void dispose() {
    // 解除全局引用（ComicSource.sources / this['temp'] 持有 JM 实例），
    // 避免 engine.close() 报 reference leak
    engine.evaluate(
        "ComicSource.sources = null; this['temp'] = null; this['sendMessage'] = null;");
    engine.close();
    engine.port.close();
  }

  static String _readFile(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// 调用 jm.search.load —— 返回 JS 层结果（comics/maxPage）。
  Future<Map<String, dynamic>> callSearch(
      String keyword, List<String> options, int page) {
    httpRequests.clear();
    return _call('search.load', [keyword, options, page]);
  }

  /// 调用 jm.search.tagSearch —— 返回 JS 层结果（comics/maxPage）。
  Future<Map<String, dynamic>> callTagSearch(
      String tag, String keyword, List<String> options, int page) {
    httpRequests.clear();
    return _call('search.tagSearch', [tag, keyword, options, page]);
  }

  Future<Map<String, dynamic>> _call(String fn, List args) async {
    final argList = args.map((a) => jsonEncode(a)).join(', ');
    final res = await engine
        .evaluate('ComicSource.sources.jm.$fn($argList)') as Map;
    return Map<String, dynamic>.from(res);
  }

  // ---------------------------------------------------------------------------
  // mock sendMessage：http / convert / load_setting
  // ---------------------------------------------------------------------------

  dynamic _messageReceiver(dynamic message) {
    final m = Map<String, dynamic>.from(message as Map);
    switch (m['method']) {
      case 'http':
        return _mockHttp(m);
      case 'convert':
        return _mockConvert(m);
      case 'load_setting':
        // apiDomain 默认 "1"（settings.apiDomain.default），其余返回 null
        return m['setting_key'] == 'apiDomain' ? '1' : null;
      case 'log':
        return null;
      default:
        return null;
    }
  }

  /// mock HTTP：按 JM 协议返回加密罐头数据。
  /// 密钥与 jm.js 的 get() 保持一致 —— 从请求头 tokenparam 提取 time，
  /// secret = `${time}185Hcomic3PAPP7R`。
  Map<String, dynamic> _mockHttp(Map<String, dynamic> req) {
    httpRequests.add(_RecordedRequest(
      req['url'] as String,
      Map<String, dynamic>.from(req['headers'] ?? {}),
    ));

    // 从 tokenparam 头还原 time（与 JS 端 getApiHeaders(time) 同源）
    final headers = httpRequests.last.headers;
    final tokenparam = headers['tokenparam'] as String? ?? '';
    final time = tokenparam.split(',').first;

    // 加密链（对照 jm.js convertData）：
    // key = encodeUtf8(hexEncode(md5(encodeUtf8(secret))))
    final secret = '${time}185Hcomic3PAPP7R';
    final keyBytes = _jmKey(secret);

    final plain = utf8.encode(_searchResponseFor(req['url'] as String));
    final encrypted = _aesEcb(plain, keyBytes, encrypt: true);
    final b64 = base64Encode(encrypted);

    return {
      'status': 200,
      'headers': {'content-type': 'application/json'},
      'body': '{"data": "$b64"}',
      'error': null,
    };
  }

  /// 根据请求 URL 提供罐头响应（默认用通用搜索罐头）。
  String _searchResponseFor(String url) => searchResponseJson;

  /// mock Convert：对照生产 js_engine.dart _convert 的子集。
  dynamic _mockConvert(Map<String, dynamic> m) {
    final type = m['type'] as String;
    final isEncode = m['isEncode'] == true;
    final value = m['value'];
    switch (type) {
      case 'utf8':
        if (isEncode) {
          return Uint8List.fromList(utf8.encode(value as String));
        }
        return utf8.decode(value as Uint8List);
      case 'base64':
        if (isEncode) {
          return base64Encode(value as Uint8List);
        }
        return base64Decode(value as String);
      case 'md5':
        return Uint8List.fromList(md5.convert(value as Uint8List).bytes);
      case 'aes-ecb':
        return _aesEcb(
          value as Uint8List,
          m['key'] as Uint8List,
          encrypt: isEncode,
        );
      default:
        throw 'mock Convert: unsupported type $type';
    }
  }

  /// JM AES 密钥：md5(secret) 的 hex（32 字符）的 utf8 字节。
  static Uint8List _jmKey(String secret) =>
      Uint8List.fromList(utf8.encode(
          md5.convert(utf8.encode(secret)).toString()));

  /// AES-ECB 加解密（无 padding 处理，与生产 _convert 一致；
  /// 加密侧 zero-pad，JS 端 stripJsonPrefix 会截取 {..} 边界）。
  static Uint8List _aesEcb(Uint8List input, Uint8List key,
      {required bool encrypt}) {
    final cipher = ECBBlockCipher(AESEngine());
    cipher.init(encrypt, KeyParameter(key));
    // zero-pad 到块大小的整数倍
    final blocks = (input.length + 15) ~/ 16;
    final padded = Uint8List(blocks * 16);
    padded.setRange(0, input.length, input);
    final result = Uint8List(blocks * 16);
    var offset = 0;
    while (offset < padded.length) {
      offset += cipher.processBlock(padded, offset, result, offset);
    }
    return result;
  }
}
