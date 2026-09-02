// 连接池空闲退化诊断
// 假设：共享 client 时会复用「服务端已悄悄关闭、但客户端还没感知」的空闲连接，
//       请求发出后才发现连接已断 → 等待/重试 → 表现为偶发极端慢（十几秒）。
// 实验：共享 client 下一次请求建立连接，间隔 X 秒后再请求，量第二次耗时。
//       对照：每请求新建 client（不存在复用脏连接的问题）。
// 运行：flutter test test/pool_idle_probe_test.dart
import 'dart:io';

import 'package:flutter_rust_bridge/src/platform_types/_io.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:rhttp/src/rust/frb_generated.dart' as frb;

// Cloudflare + 跨太平洋，对空闲连接最敏感
const url = 'https://tu.mhttu.cc/en_images/20254/6566/371468/0.jpg';
const headers = <String, String>{
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'referer': 'https://manwaba.com/',
};

const idleGaps = <int>[2, 10, 25, 45, 70];

Future<int> once(rhttp.RhttpClient? client) async {
  final sw = Stopwatch()..start();
  try {
    if (client == null) {
      await rhttp.Rhttp.request(
        method: rhttp.HttpMethod.get,
        url: url,
        headers: rhttp.HttpHeaders.rawMap(headers),
        expectBody: rhttp.HttpExpectBody.bytes,
      );
    } else {
      await client.request(
        method: rhttp.HttpMethod.get,
        url: url,
        headers: rhttp.HttpHeaders.rawMap(headers),
        expectBody: rhttp.HttpExpectBody.bytes,
      );
    }
  } catch (_) {
    // 失败也算一次耗时，记真实等待
  }
  return sw.elapsedMilliseconds;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('空闲间隔 vs 复用耗时', () async {
    final dll = File('build/windows/x64/runner/Release/rhttp.dll').existsSync()
        ? File('build/windows/x64/runner/Release/rhttp.dll').absolute.path
        : 'build/windows/x64/plugins/rhttp/cargokit_build/x86_64-pc-windows-msvc/release/rhttp.dll';
    await frb.RustLib.init(externalLibrary: ExternalLibrary.open(dll));

    final rows = <String>[];
    for (final gap in idleGaps) {
      // A 对照：一次性 client（间隔后必然新建连接）
      await once(null);
      await Future<void>.delayed(Duration(seconds: gap));
      final aSecond = await once(null);

      // B：共享 client（间隔后尝试复用池中连接）
      final client = await rhttp.RhttpClient.create(
        settings: const rhttp.ClientSettings(
          timeoutSettings: rhttp.TimeoutSettings(
            connectTimeout: Duration(seconds: 15),
            keepAliveTimeout: Duration(seconds: 60),
          ),
          throwOnStatusCode: false,
        ),
      );
      await once(client);
      await Future<void>.delayed(Duration(seconds: gap));
      final bSecond = await once(client);
      client.dispose();

      final flag = bSecond > aSecond * 1.5
          ? '  ← 复用退化'
          : (bSecond < aSecond * 0.7 ? '  ← 复用受益' : '');
      rows.add('间隔${'$gap'.padLeft(3)}s   '
          'A(新建连接) ${'$aSecond'.padLeft(6)}ms   '
          'B(复用连接) ${'$bSecond'.padLeft(6)}ms$flag');
    }

    // ignore: avoid_print
    print('\n========= 空闲间隔 vs 复用耗时（第二次请求）=========');
    for (final r in rows) {
      // ignore: avoid_print
      print(r);
    }
    // ignore: avoid_print
    print('=====================================================\n');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
