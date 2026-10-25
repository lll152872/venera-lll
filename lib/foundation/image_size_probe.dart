import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Size;
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

/// 探测图片的真实像素尺寸（**只读文件头，不解码整图**）。
///
/// 为什么需要：
/// 连续滚动模式下，"第 N 页"没有固定像素位置——每页高度 = 图片高宽比 × 显示宽，
/// 而图片加载前这个值不存在（未加载的页只能用"视口高"占位）。跳转偏移是逐页累加
/// 高度算出来的，占位高一旦偏大/偏小，跳到第 N 页就会落在 N±若干页。
/// 宽高就写在图片文件头里，读前 64KB 就能拿到，于是"点第 N 页 → 精确落在第 N 页"。
///
/// 支持的格式：WebP(VP8X/VP8L/VP8) / JPEG(SOFn) / PNG(IHDR) / GIF / BMP / AVIF·HEIF(ispe)。
/// 探测失败一律返回 null，由调用方回退到占位高（不崩、不阻塞）。
class ImageSizeProbe {
  const ImageSizeProbe._();

  /// 读取的头部字节数。64KB 足够覆盖所有格式的头信息（PNG 的 IHDR 在
  /// 24 字节处、WebP 的 VP8X 在 30 字节处、JPEG 的 SOFn 一般在几 KB 内、
  /// AVIF 的 ispe box 通常也在头部几十 KB 内），远小于整图。
  static const int kHeaderBytes = 64 * 1024;

  /// 探测单个图片的像素尺寸。失败返回 null。
  ///
  /// [imageKey] 形态与 `ReaderImageProvider.imageKey` 一致：
  /// 本地文件是 `file://<绝对路径>`，网络图片是 http(s) URL。
  ///
  /// [headers] 是书源自定义的请求头（Referer 等）。有些图床必须带
  /// Referer，否则探测请求会被拒 → 返回 null → 回退占位高（不影响阅读）。
  static Future<Size?> probe(
    String imageKey, {
    Map<String, dynamic>? headers,
  }) async {
    try {
      if (imageKey.startsWith('file://')) {
        return await _probeLocalFile(imageKey.substring(7));
      }
      if (imageKey.startsWith('http://') || imageKey.startsWith('https://')) {
        return await _probeRemote(imageKey, headers);
      }
      return null;
    } catch (e) {
      Log.error("ImageSizeProbe", "probe failed for $imageKey: $e");
      return null;
    }
  }

  /// 本地文件：直接读前 kHeaderBytes 字节，零网络零解码。
  static Future<Size?> _probeLocalFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final handle = await file.open();
    try {
      final length = await handle.length();
      final size = length < kHeaderBytes ? length : kHeaderBytes;
      final bytes = await handle.read(size);
      return parseImageSize(bytes);
    } finally {
      await handle.close();
    }
  }

  /// 网络图片：Range 请求只取头部。服务器不支持 Range 时会退化成整流，
  /// 但我们读够 kHeaderBytes 就取消订阅，不会下整张图。
  static Future<Size?> _probeRemote(
    String url,
    Map<String, dynamic>? extraHeaders,
  ) async {
    final headers = <String, dynamic>{
      if (extraHeaders != null) ...extraHeaders,
      'user-agent': webUA,
      // range 放最后：不能被书源自定义头覆盖。
      'range': 'bytes=0-${kHeaderBytes - 1}',
    };
    final dio = AppDio(
      BaseOptions(
        headers: headers,
        method: 'GET',
        responseType: ResponseType.stream,
      ),
    );
    final res = await dio.request<ResponseBody>(url);
    final stream = res.data?.stream;
    if (stream == null) return null;
    final buffer = <int>[];
    await for (final chunk in stream) {
      buffer.addAll(chunk);
      if (buffer.length >= kHeaderBytes) break; // break 会取消订阅
    }
    return parseImageSize(Uint8List.fromList(buffer));
  }

  /// 从图片头部字节解析像素尺寸。格式不认识 / 数据损坏返回 null。
  @visibleForTesting
  static Size? parseImageSize(Uint8List b) {
    // 各格式的最小头长度不同（GIF 10 字节就够），这里只挡住明显太短的。
    if (b.length < 10) return null;
    // WebP: 'RIFF' .... 'WEBP'
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return _parseWebP(b);
    }
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
        b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) {
      return _parsePng(b);
    }
    // JPEG: FF D8
    if (b[0] == 0xFF && b[1] == 0xD8) {
      return _parseJpeg(b);
    }
    // GIF: 'GIF87a' / 'GIF89a'
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return _parseGif(b);
    }
    // BMP: 'BM'
    if (b[0] == 0x42 && b[1] == 0x4D) {
      return _parseBmp(b);
    }
    // ISO-BMFF (AVIF / HEIF): 找 'ispe' box
    if (b.length >= 12 && b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
      return _parseIsoBmff(b);
    }
    return null;
  }

  static int _u24le(Uint8List b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);

  static int _u32be(Uint8List b, int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

  static int _u16le(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

  static int _u16be(Uint8List b, int i) => (b[i] << 8) | b[i + 1];

  static int _u32le(Uint8List b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

  /// WebP: RIFF 容器，三个可能的 chunk 头
  /// - VP8X: 扩展格式，宽高各 24bit little-endian（存在 +1 偏移）
  /// - VP8L: 无损，位打包
  /// - VP8 : 有损，关键帧头（3 字节帧标记 + 3 字节同步码）
  static Size? _parseWebP(Uint8List b) {
    if (b.length < 16) return null;
    final chunk = String.fromCharCodes(b.sublist(12, 16));
    if (chunk == 'VP8X') {
      // RIFF(12) + 'VP8X'(4) + 尺寸(4) + flags(4) + 宽(3) + 高(3) = 30
      if (b.length < 30) return null;
      final w = 1 + _u24le(b, 24);
      final h = 1 + _u24le(b, 27);
      return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
    }
    if (chunk == 'VP8L') {
      // RIFF(12) + 'VP8L'(4) + 尺寸(4) + 签名(1) + 位域(4) = 25
      if (b.length < 25) return null;
      // 位布局: 1 签名位 + 14bit 宽-1 + 14bit 高-1 + ...
      final bits = _u32le(b, 21);
      final w = 1 + (bits & 0x3FFF);
      final h = 1 + ((bits >> 14) & 0x3FFF);
      return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
    }
    if (chunk == 'VP8 ') {
      // RIFF(12) + 'VP8 '(4) + 尺寸(4) + 帧标记(3) + 同步码(3)
      //       + 宽(2) + 高(2) = 30
      if (b.length < 30) return null;
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
      final w = _u16le(b, 26) & 0x3FFF;
      final h = _u16le(b, 28) & 0x3FFF;
      return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
    }
    return null;
  }

  /// PNG: 8 字节签名 + IHDR(长度4 + 类型4 + 宽4 + 高4)
  static Size? _parsePng(Uint8List b) {
    if (b.length < 24) return null;
    if (b[12] != 0x49 || b[13] != 0x48 || b[14] != 0x44 || b[15] != 0x52) {
      return null; // 不是 IHDR
    }
    final w = _u32be(b, 16);
    final h = _u32be(b, 20);
    return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
  }

  /// JPEG: 逐段扫描，找 SOF0/1/2/3/5/6/7/9/10/11/13/14/15（排除 DHT/DAC/RST）
  static Size? _parseJpeg(Uint8List b) {
    var i = 2;
    while (i + 3 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      // 填充字节
      if (marker == 0xFF) {
        i++;
        continue;
      }
      // 无长度字段的标记
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
        i += 2;
        continue;
      }
      if (i + 3 >= b.length) break;
      final len = _u16be(b, i + 2);
      if (len < 2) return null;
      final isSof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 && // DHT
          marker != 0xC8 && // JPG 扩展
          marker != 0xCC; // DAC
      if (isSof) {
        if (i + 9 > b.length) return null;
        final h = _u16be(b, i + 5);
        final w = _u16be(b, i + 7);
        return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
      }
      i += 2 + len;
    }
    return null;
  }

  /// GIF: 逻辑屏宽高
  static Size? _parseGif(Uint8List b) {
    if (b.length < 10) return null;
    final w = _u16le(b, 6);
    final h = _u16le(b, 8);
    return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
  }

  /// BMP: 'BM' + 文件头(14) + DIB header
  static Size? _parseBmp(Uint8List b) {
    if (b.length < 26) return null;
    final dibSize = _u32le(b, 14);
    int w, h;
    if (dibSize == 12) {
      // BITMAPCOREHEADER
      w = _u16le(b, 18);
      h = _u16le(b, 20);
    } else {
      // BITMAPINFOHEADER (40) 及以后
      if (b.length < 26) return null;
      w = _u32le(b, 18);
      h = _u32le(b, 22);
      if (h < 0) h = -h; // 负数表示顶向
    }
    return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
  }

  /// ISO-BMFF (AVIF/HEIF): 在头部里找 'ispe' box（宽高各 4 字节 BE）
  static Size? _parseIsoBmff(Uint8List b) {
    for (var i = 0; i + 12 < b.length; i++) {
      if (b[i] != 0x69 || b[i + 1] != 0x73 || b[i + 2] != 0x70 || b[i + 3] != 0x65) {
        continue; // 'ispe'
      }
      if (i + 16 > b.length) return null;
      final w = _u32be(b, i + 8);
      final h = _u32be(b, i + 12);
      return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
    }
    return null;
  }
}
