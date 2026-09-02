// App 真实链路并发测试（阅读页并发加载图片的场景）
//
// 背景：串行请求只能体现连接复用的收益，但阅读页是并发拉多张图。
// 共享 client 后，同 host 的并发请求会复用同一条连接；若协商到 h2，
// 就变成单连接多路复用 —— 一旦丢包就是队头阻塞，表现为「卡」而不是「慢」。
//
// 三组对照：
//   A. 每请求新建 client（改造前行为）
//   B. 共享 client + 默认版本偏好（改造后行为，可能协商到 h2）
//   C. 共享 client + 强制 HTTP/1.1（验证是不是 h2 队头阻塞的锅）
//
// 运行：flutter test test/appdio_concurrent_test.dart
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:flutter_rust_bridge/src/platform_types/_io.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:rhttp/src/rust/frb_generated.dart' as frb;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';

// 包子真实章节 API（App 里 loadEp 就打这个域，ALPN 协商为 h2）
const comicId = 'haizeiwang-weitianrongyilang';
const epHost = 'https://appcn.baozimh.com/baozimhapp/comic/chapter/$comicId';
// 漫蛙吧图床（同为 h2，用户反馈这个反而变快了）
const mwHost = 'https://tu.mhttu.cc/en_images/20254/6566/371468';

const ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

final targets = <String>[
  for (var i = 0; i < 8; i++) '$epHost/0_$i.html',
];

final targetsMw = <String>[
  for (var i = 0; i < 8; i++) '$mwHost/$i.jpg',
];

class Res {
  Res.status(this.ms, this.status);
  final int ms;
  final int status; // -1 表示异常
  bool get ok => status == 200;
}

Future<Res> _get(String url, {rhttp.RhttpClient? client, String? referer}) async {
  final headers = <String, String>{
    'user-agent': ua,
    if (referer != null) 'referer': referer,
  };
  final sw = Stopwatch()..start();
  try {
    final rhttp.HttpResponse res;
    if (client == null) {
      res = await rhttp.Rhttp.request(
        method: rhttp.HttpMethod.get,
        url: url,
        headers: rhttp.HttpHeaders.rawMap(headers),
        expectBody: rhttp.HttpExpectBody.bytes,
      );
    } else {
      res = await client.request(
        method: rhttp.HttpMethod.get,
        url: url,
        headers: rhttp.HttpHeaders.rawMap(headers),
        expectBody: rhttp.HttpExpectBody.bytes,
      );
    }
    // throwOnStatusCode: false —— 403/429 不会抛异常，必须自己看状态码，
    // 否则「被限流秒回」会被误判成「很快」
    return Res.status(sw.elapsedMilliseconds, res.statusCode);
  } catch (_) {
    return Res.status(sw.elapsedMilliseconds, -1);
  }
}

/// 并发跑一轮，返回总墙钟耗时与每个请求耗时
Future<(int, List<int>, int)> runBatch(
  List<String> urls, {
  rhttp.RhttpClient? client,
  String? referer,
}) async {
  final sw = Stopwatch()..start();
  final results = await Future.wait(
    urls.map((u) => _get(u, client: client, referer: referer)).toList(),
  );
  sw.stop();
  return (
    sw.elapsedMilliseconds,
    results.map((r) => r.ms).toList(),
    results.where((r) => r.ok).length // 真正成功(200)的个数
  );
}

/// 走 App 真实链路：AppDio -> RHttpAdapter
///
/// 注意：settings['proxy'] 默认 'system'，会走 MethodChannel 取系统代理，
/// flutter test 里没有原生实现会抛异常 —— 测试前先设成 'direct' 绕过。
Future<(int, List<int>, int)> runBatchWithAppDio(
    List<String> urls, String referer) async {
  appdata.settings['proxy'] = 'direct';
  final sw = Stopwatch()..start();
  final times = <int>[];
  var oks = 0;
  await Future.wait(urls.map((u) async {
    final t0 = Stopwatch()..start();
    try {
      final dio = AppDio(BaseOptions(
        headers: {'user-agent': ua, 'referer': referer},
        validateStatus: (_) => true,
      ));
      final resp = await dio.request<Uint8List>(u,
          options: Options(responseType: ResponseType.bytes));
      t0.stop();
      times.add(t0.elapsedMilliseconds);
      if (resp.statusCode == 200) oks++;
    } catch (_) {
      t0.stop();
      times.add(t0.elapsedMilliseconds);
    }
  }).toList());
  sw.stop();
  return (sw.elapsedMilliseconds, times, oks);
}

Future<rhttp.RhttpClient> makeClient(rhttp.HttpVersionPref pref) =>
    rhttp.RhttpClient.create(
      settings: rhttp.ClientSettings(
        timeoutSettings: const rhttp.TimeoutSettings(
          connectTimeout: Duration(seconds: 20),
          keepAliveTimeout: Duration(seconds: 60),
        ),
        httpVersionPref: pref,
        throwOnStatusCode: false,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('并发加载：新建 client / 共享 h2 / 共享 h1', () async {
    final dll = File('build/windows/x64/runner/Release/rhttp.dll').existsSync()
        ? File('build/windows/x64/runner/Release/rhttp.dll').absolute.path
        : 'build/windows/x64/plugins/rhttp/cargokit_build/x86_64-pc-windows-msvc/release/rhttp.dll';
    await frb.RustLib.init(externalLibrary: ExternalLibrary.open(dll));

    final out = <String>[];
    for (final (label, urls, referer) in <(String, List<String>, String)>[
      ('包子章节API(h2)', targets, 'https://cn.bzmgcn.com/'),
      ('漫蛙吧图床(h2)', targetsMw, 'https://manwaba.com/'),
    ]) {
      // A：每请求新建 client
      final (wallA, listA, errA) = await runBatch(urls, referer: referer);
      // B：共享 client，默认版本偏好（可能 h2）
      final cB = await makeClient(rhttp.HttpVersionPref.all);
      final (wallB, listB, errB) =
          await runBatch(urls, client: cB, referer: referer);
      cB.dispose();
      // C：共享 client，强制 HTTP/1.1
      final cC = await makeClient(rhttp.HttpVersionPref.http1_1);
      final (wallC, listC, errC) =
          await runBatch(urls, client: cC, referer: referer);
      cC.dispose();
      // D：App 真实链路 AppDio（RHttpAdapter 改造后的实际行为）
      final (wallD, listD, errD) = await runBatchWithAppDio(urls, referer);

      int maxOf(List<int> l) => l.reduce((a, b) => a > b ? a : b);
      // runBatch 现在返回的是「成功(200)个数」，变量名沿用 errX 但语义是 ok 数
      String okNote(int ok, int total) =>
          ok == total ? '' : '  ⚠ 仅 $ok/$total 返回200（其余为限流/错误状态码）';
      out.add('$label  并发 ${urls.length} 个请求');
      out.add('  A 新建client  墙钟${'${wallA}ms'.padLeft(7)}  '
          '最慢${'${maxOf(listA)}ms'.padLeft(7)}  '
          '明细 ${listA.join(',')}${okNote(errA, urls.length)}');
      out.add('  B 共享(默认版本) 墙钟${'${wallB}ms'.padLeft(7)}  '
          '最慢${'${maxOf(listB)}ms'.padLeft(7)}  '
          '明细 ${listB.join(',')}${okNote(errB, urls.length)}');
      out.add('  C 共享(h1.1)  墙钟${'${wallC}ms'.padLeft(7)}  '
          '最慢${'${maxOf(listC)}ms'.padLeft(7)}  '
          '明细 ${listC.join(',')}${okNote(errC, urls.length)}');
      out.add('  D AppDio(现网) 墙钟${'${wallD}ms'.padLeft(7)}  '
          '最慢${'${maxOf(listD)}ms'.padLeft(7)}  '
          '明细 ${listD.join(',')}${errD > 0 ? '  异常$errD' : ''}');
    }

    // ignore: avoid_print
    print('\n===== App 并发加载对照（阅读页场景）=====');
    for (final line in out) {
      // ignore: avoid_print
      print(line);
    }
    // ignore: avoid_print
    print('==========================================\n');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
