// 目的：锁住「读文件头拿图片真实宽高」的解析正确性。
// 覆盖：WebP(VP8X/VP8L/VP8 ) / JPEG(SOF0) / PNG(IHDR) / GIF / BMP / AVIF(ispe)，
// 以及垃圾数据必须返回 null（不能崩、不能瞎猜）。
//
// 这些字节都是按各格式规范手工拼出来的最小合法头。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_size_probe.dart';

Uint8List u8(List<int> v) => Uint8List.fromList(v);

/// 拼一个 4 字节 little-endian
List<int> le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

/// 拼一个 3 字节 little-endian
List<int> le24(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF];

/// 拼一个 4 字节 big-endian
List<int> be32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

/// 拼一个 2 字节 big-endian
List<int> be16(int v) => [(v >> 8) & 0xFF, v & 0xFF];

Uint8List webpVp8x(int w, int h) => u8([
  0x52, 0x49, 0x46, 0x46, // RIFF
  ...le32(30), // size
  0x57, 0x45, 0x42, 0x50, // WEBP
  0x56, 0x50, 0x38, 0x58, // VP8X
  ...le32(10), // chunk size
  0x10, 0x00, 0x00, 0x00, // flags
  ...le24(w - 1),
  ...le24(h - 1),
  0, 0, 0, 0, 0, 0,
]);

Uint8List webpVp8l(int w, int h) {
  final bits = (w - 1) | ((h - 1) << 14);
  return u8([
    0x52, 0x49, 0x46, 0x46,
    ...le32(25),
    0x57, 0x45, 0x42, 0x50,
    0x56, 0x50, 0x38, 0x4C, // VP8L
    ...le32(9),
    0x2F, // 签名
    ...le32(bits),
    0, 0, 0,
  ]);
}

Uint8List webpVp8(int w, int h) => u8([
  0x52, 0x49, 0x46, 0x46,
  ...le32(30),
  0x57, 0x45, 0x42, 0x50,
  0x56, 0x50, 0x38, 0x20, // "VP8 "
  ...le32(10),
  0x00, 0x00, 0x00, // 帧标记
  0x9D, 0x01, 0x2A, // 同步码
  w & 0xFF, (w >> 8) & 0xFF, // 宽（2 字节 LE，低 14 位有效）
  h & 0xFF, (h >> 8) & 0xFF, // 高（2 字节 LE，低 14 位有效）
]);

Uint8List jpeg(int w, int h) => u8([
  0xFF, 0xD8, // SOI
  // APP0: 段长度 = 长度字段(2) + 载荷(12) = 14
  0xFF, 0xE0, ...be16(14), 0x4A, 0x46, 0x49, 0x46, 0, 0, 0, 0, 0, 0, 0, 0, // APP0
  // SOF0: 段长度 = 长度字段(2) + 载荷(15) = 17
  0xFF, 0xC0, ...be16(17), 0x08, ...be16(h), ...be16(w), 0x03, 0, 0, 0, 0, 0, 0, 0,
]);

Uint8List png(int w, int h) => u8([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  ...be32(13),
  0x49, 0x48, 0x44, 0x52, // IHDR
  ...be32(w),
  ...be32(h),
  0x08, 0x06, 0, 0, 0,
]);

Uint8List gif(int w, int h) => u8([
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
  w & 0xFF, (w >> 8) & 0xFF,
  h & 0xFF, (h >> 8) & 0xFF,
  0xF7, 0x00, 0x00,
]);

Uint8List bmp(int w, int h) => u8([
  0x42, 0x4D, // BM
  ...le32(70),
  0, 0, 0, 0,
  ...le32(54),
  ...le32(40), // BITMAPINFOHEADER
  ...le32(w),
  ...le32(h),
  0x01, 0x00, 0x18, 0x00,
]);

Uint8List avif(int w, int h) => u8([
  0, 0, 0, 0x20, // box size
  0x66, 0x74, 0x79, 0x70, // ftyp
  0x61, 0x76, 0x69, 0x66,
  0, 0, 0, 0,
  0, 0, 0, 0x14, // ispe box size
  0x69, 0x73, 0x70, 0x65, // ispe
  0, 0, 0, 0, // version+flags
  ...be32(w),
  ...be32(h),
]);

void main() {
  group('图片头解析', () {
    test('WebP VP8X', () {
      final s = ImageSizeProbe.parseImageSize(webpVp8x(900, 1464));
      expect(s?.width, 900);
      expect(s?.height, 1464);
    });

    test('WebP VP8L', () {
      final s = ImageSizeProbe.parseImageSize(webpVp8l(1200, 800));
      expect(s?.width, 1200);
      expect(s?.height, 800);
    });

    test('WebP VP8（有损）', () {
      final s = ImageSizeProbe.parseImageSize(webpVp8(640, 480));
      expect(s?.width, 640);
      expect(s?.height, 480);
    });

    test('JPEG SOF0', () {
      final s = ImageSizeProbe.parseImageSize(jpeg(1080, 1920));
      expect(s?.width, 1080);
      expect(s?.height, 1920);
    });

    test('PNG IHDR', () {
      final s = ImageSizeProbe.parseImageSize(png(800, 1235));
      expect(s?.width, 800);
      expect(s?.height, 1235);
    });

    test('GIF', () {
      final s = ImageSizeProbe.parseImageSize(gif(320, 240));
      expect(s?.width, 320);
      expect(s?.height, 240);
    });

    test('BMP', () {
      final s = ImageSizeProbe.parseImageSize(bmp(200, 100));
      expect(s?.width, 200);
      expect(s?.height, 100);
    });

    test('AVIF/HEIF ispe', () {
      final s = ImageSizeProbe.parseImageSize(avif(1024, 768));
      expect(s?.width, 1024);
      expect(s?.height, 768);
    });
  });

  group('异常输入必须返回 null（不崩、不瞎猜）', () {
    test('全 0 字节', () {
      expect(ImageSizeProbe.parseImageSize(u8(List.filled(64, 0))), isNull);
    });

    test('随机垃圾', () {
      expect(
        ImageSizeProbe.parseImageSize(u8([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC])),
        isNull,
      );
    });

    test('太短', () {
      expect(ImageSizeProbe.parseImageSize(u8([0x89, 0x50])), isNull);
      expect(ImageSizeProbe.parseImageSize(u8([])), isNull);
    });

    test('PNG 签名但 IHDR 被截断', () {
      final b = png(800, 1235).sublist(0, 20);
      expect(ImageSizeProbe.parseImageSize(b), isNull);
    });

    test('JPEG 缺 SOF 段', () {
      final b = u8([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(ImageSizeProbe.parseImageSize(b), isNull);
    });

    test('WebP 头但 chunk 类型不认识', () {
      final b = u8([
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0,
        0x57, 0x45, 0x42, 0x50,
        0x58, 0x58, 0x58, 0x58,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ]);
      expect(ImageSizeProbe.parseImageSize(b), isNull);
    });
  });
}
