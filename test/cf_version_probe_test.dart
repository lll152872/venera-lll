// CF 弹窗诱因排查：rhttp 的 http1_1 vs http2 vs all 对 appcn.baozimh.com 的表现
// 用户反馈：手机 APK（h2/默认版本）不弹 CF 验证，本地 exe（我改成 h1.1 后）弹。
// 假设：rustls + h1.1 的握手特征在 CF 眼里比 h2 更可疑。
// 低频请求（每组 2 次、间隔 3s），避免加深出口 IP 的 CF 黑名单。
import 'dart:io';

import 'package:flutter_rust_bridge/src/platform_types/_io.dart'
    show ExternalLibrary; // ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:rhttp/src/rust/frb_generated.dart' as frb;

const url =
    'https://appcn.baozimh.com/baozimhapp/comic/chapter/haizeiwang-weitianrongyilang/0_0.html';
const ua =
    'Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rhttp http1_1 vs http2 vs all -> CF 判定', () async {
    final dll = File('build/windows/x64/runner/Release/rhttp.dll').existsSync()
        ? File('build/windows/x64/runner/Release/rhttp.dll').absolute.path
        : 'build/windows/x64/plugins/rhttp/cargokit_build/x86_64-pc-windows-msvc/release/rhttp.dll';
    await frb.RustLib.init(externalLibrary: ExternalLibrary.open(dll));

    final rows = <String>[];
    for (final (label, pref) in <(String, rhttp.HttpVersionPref)>[
      ('http1_1', rhttp.HttpVersionPref.http1_1),
      ('http2', rhttp.HttpVersionPref.http2),
      ('all(默认)', rhttp.HttpVersionPref.all),
    ]) {
      final client = await rhttp.RhttpClient.create(
        settings: rhttp.ClientSettings(
          httpVersionPref: pref,
          throwOnStatusCode: false,
          timeoutSettings: rhttp.TimeoutSettings(connectTimeout: Duration(seconds: 15)),
        ),
      );
      final codes = <int>[];
      final ms = <int>[];
      for (var i = 0; i < 2; i++) {
        final sw = Stopwatch()..start();
        final res = await client.request(
          method: rhttp.HttpMethod.get,
          url: url,
          headers: rhttp.HttpHeaders.rawMap({'user-agent': ua}),
          expectBody: rhttp.HttpExpectBody.bytes,
        );
        codes.add(res.statusCode);
        ms.add(sw.elapsedMilliseconds);
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      client.dispose();
      rows.add('$label  ->  ${codes.join('/')}  ${ms.join('ms, ')}ms');
    }

    // ignore: avoid_print
    print('\n===== CF 判定对照（appcn，2 次/组）=====');
    for (final r in rows) {
      // ignore: avoid_print
      print(r);
    }
    // ignore: avoid_print
    print('======================================\n');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
