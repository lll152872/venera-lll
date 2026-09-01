// 连接池复用效果实测（真实网络）
// 对比两种模式连续拉 5 张同一图床的图：
//   A. 每请求隐式新建 reqwest client（原 RHttpAdapter 的行为，rhttp 静态 API）
//   B. 共享 RhttpClient（Rust 侧连接池，改造后的行为）
// 运行：flutter test test/network_pool_bench_test.dart
import 'dart:io';

import 'package:flutter_rust_bridge/src/platform_types/_io.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:rhttp/src/rust/frb_generated.dart' as frb;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rhttp 连接池对比：一次性 client vs 共享 client', () async {
    // flutter test 跑在 Dart VM 上不会自动加载 Flutter 构建出的 rhttp.dll，
    // 手动指到构建产物（先 flutter build windows 一次就有）。Rhttp.init() 不透传
    // externalLibrary，直接调 frb 层的 RustLib.init。
    final dll = File('build/windows/x64/runner/Release/rhttp.dll').existsSync()
        ? File('build/windows/x64/runner/Release/rhttp.dll').absolute.path
        : 'build/windows/x64/plugins/rhttp/cargokit_build/x86_64-pc-windows-msvc/release/rhttp.dll';
    await frb.RustLib.init(
      externalLibrary: ExternalLibrary.open(dll),
    );

    // 漫蛙吧图床真实图片（AES 加密体也无所谓，这里只测传输耗时）
    const url = 'https://tu.mhttu.cc/en_images/20254/6566/371468/0.jpg';
    const headers = {
      'user-agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'referer': 'https://manwaba.com/',
    };
    const rounds = 5;

    int sum(List<int> xs) => xs.reduce((a, b) => a + b);

    // ---- 模式 A：每请求一次性 client（旧实现路径） ----
    final timesA = <int>[];
    for (var i = 0; i < rounds; i++) {
      final sw = Stopwatch()..start();
      final res = await rhttp.Rhttp.request(
        method: rhttp.HttpMethod.get,
        url: url,
        headers: rhttp.HttpHeaders.rawMap(headers),
        expectBody: rhttp.HttpExpectBody.bytes,
      );
      sw.stop();
      expect(res.statusCode, 200, reason: '模式A 第${i}次');
      timesA.add(sw.elapsedMilliseconds);
    }

    // ---- 模式 B：共享 RhttpClient（新实现路径） ----
    final client = await rhttp.RhttpClient.create(
      settings: const rhttp.ClientSettings(
        timeoutSettings: rhttp.TimeoutSettings(
          connectTimeout: Duration(seconds: 15),
          keepAliveTimeout: Duration(seconds: 60),
        ),
        throwOnStatusCode: false,
      ),
    );
    final timesB = <int>[];
    for (var i = 0; i < rounds; i++) {
      final sw = Stopwatch()..start();
      final res = await client.request(
        method: rhttp.HttpMethod.get,
        url: url,
        headers: rhttp.HttpHeaders.rawMap(headers),
        expectBody: rhttp.HttpExpectBody.bytes,
      );
      sw.stop();
      expect(res.statusCode, 200, reason: '模式B 第${i}次');
      timesB.add(sw.elapsedMilliseconds);
    }
    client.dispose();

    String fmt(List<int> xs) =>
        '[${xs.join(', ')}] 合计 ${sum(xs)}ms 均值 ${sum(xs) ~/ xs.length}ms';
    // ignore: avoid_print
    print('\n========== 连接池对比（$rounds 张同图床图片） ==========');
    // ignore: avoid_print
    print('A 一次性 client（旧）: ${fmt(timesA)}');
    // ignore: avoid_print
    print('B 共享连接池  （新）: ${fmt(timesB)}');
    final oldAvg = sum(timesA) ~/ timesA.length;
    final newAvg = sum(timesB) ~/ timesB.length;
    // ignore: avoid_print
    print('每张图节省 ~${oldAvg - newAvg}ms（${(100 * (oldAvg - newAvg) / oldAvg).toStringAsFixed(0)}%）');
    // ignore: avoid_print
    print('======================================================\n');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
