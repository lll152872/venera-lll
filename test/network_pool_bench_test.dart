// 连接池复用效果实测（真实网络）
// 对同一 URL 串行请求 N 次，对比两种模式：
//   A. 每请求隐式新建 reqwest client（原 RHttpAdapter 的行为，rhttp 静态 API）
//   B. 共享 RhttpClient（Rust 侧连接池，改造后的行为）
// 运行：flutter test test/network_pool_bench_test.dart
import 'dart:io';

import 'package:flutter_rust_bridge/src/platform_types/_io.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:rhttp/src/rust/frb_generated.dart' as frb;

const targets = <(String, String)>[
  ('漫蛙吧图床', 'https://tu.mhttu.cc/en_images/20254/6566/371468/0.jpg'),
  ('包子详情页', 'https://cn.bzmgcn.com/comic/haizeiwang-weitianrongyilang'),
  ('包子章节API',
      'https://appcn.baozimh.com/baozimhapp/comic/chapter/haizeiwang-weitianrongyilang/0_0.html'),
  ('包子图片CDN',
      'https://s1.baozicdn.com/scomic/haizeiwang-weitianrongyilang/0/0-9uis/1.jpg'),
];

const ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

int sum(List<int> xs) => xs.fold(0, (a, b) => a + b);

String fmt(List<int> xs) => '[${xs.join(', ')}]';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rhttp 连接池对比：一次性 client vs 共享 client', () async {
    // flutter test 跑在 Dart VM 上不会自动加载 Flutter 构建出的 rhttp.dll，
    // 手动指到构建产物（先 flutter build windows 一次就有）。Rhttp.init() 不透传
    // externalLibrary，直接调 frb 层的 RustLib.init。
    final dll = File('build/windows/x64/runner/Release/rhttp.dll').existsSync()
        ? File('build/windows/x64/runner/Release/rhttp.dll').absolute.path
        : 'build/windows/x64/plugins/rhttp/cargokit_build/x86_64-pc-windows-msvc/release/rhttp.dll';
    await frb.RustLib.init(externalLibrary: ExternalLibrary.open(dll));

    const rounds = 4;
    final rows = <String>[];

    for (final (name, url) in targets) {
      final headers = url.contains('baozi') || url.contains('mhttu')
          ? <String, String>{
              'user-agent': ua,
              'referer': url.contains('mhttu')
                  ? 'https://manwaba.com/'
                  : 'https://cn.bzmgcn.com/',
            }
          : <String, String>{'user-agent': ua};

      // ---- A：每请求一次性 client ----
      final timesA = <int>[];
      final notesA = <String>[];
      for (var i = 0; i < rounds; i++) {
        final sw = Stopwatch()..start();
        String note;
        try {
          final res = await rhttp.Rhttp.request(
            method: rhttp.HttpMethod.get,
            url: url,
            headers: rhttp.HttpHeaders.rawMap(headers),
            expectBody: rhttp.HttpExpectBody.bytes,
          );
          note = '${res.statusCode}';
        } catch (e) {
          note = 'ERR:${e.runtimeType}';
        }
        sw.stop();
        timesA.add(sw.elapsedMilliseconds);
        notesA.add(note);
      }

      // ---- B：共享 client ----
      final client = await rhttp.RhttpClient.create(
        settings: const rhttp.ClientSettings(
          timeoutSettings: rhttp.TimeoutSettings(
            connectTimeout: Duration(seconds: 15),
            keepAliveTimeout: Duration(seconds: 60),
            keepAlivePing: Duration(seconds: 30),
          ),
          throwOnStatusCode: false,
        ),
      );
      final timesB = <int>[];
      final notesB = <String>[];
      for (var i = 0; i < rounds; i++) {
        final sw = Stopwatch()..start();
        String note;
        try {
          final res = await client.request(
            method: rhttp.HttpMethod.get,
            url: url,
            headers: rhttp.HttpHeaders.rawMap(headers),
            expectBody: rhttp.HttpExpectBody.bytes,
          );
          note = '${res.statusCode}';
        } catch (e) {
          note = 'ERR:${e.runtimeType}';
        }
        sw.stop();
        timesB.add(sw.elapsedMilliseconds);
        notesB.add(note);
      }
      client.dispose();

      final avgA = sum(timesA) ~/ timesA.length;
      final avgB = sum(timesB) ~/ timesB.length;
      final diff = avgB - avgA;
      final pct = avgA == 0 ? 0 : (100 * diff / avgA).round();
      rows.add('${name.padRight(12)} '
          'A=${fmt(timesA).padRight(30)} 均${'$avgA'.padLeft(5)}ms  '
          'B=${fmt(timesB).padRight(30)} 均${'$avgB'.padLeft(5)}ms  '
          '${diff > 0 ? '慢' : '快'} ${diff.abs().toString().padLeft(4)}ms (${pct.abs()}%)'
          '${notesA.any((n) => n != '200') || notesB.any((n) => n != '200') ? '  ⚠ A=$notesA B=$notesB' : ''}');
    }

    // ignore: avoid_print
    print('\n============ 连接池 A/B 对比（每目标串行 $rounds 次）============');
    for (final r in rows) {
      // ignore: avoid_print
      print(r);
    }
    // ignore: avoid_print
    print('================================================================\n');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
