import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';

/// 持久化的图片尺寸缓存（legado 式"预排版预测量"的 fallback 层）。
///
/// 用于解决连续滚动阅读模式下，图片异步加载完成导致 item 高度突变、
/// 进而引发页码/章节随机乱跳的 bug。
///
/// 三层缓存协同：
///   1. Flutter ImageCache（进程级，ComicImage._cache）—— 命中即用，最快
///   2. ImageSizeCache 内存层（本类，进程级）—— 启动时从 JSON 加载，命中即用
///   3. ImageSizeCache JSON 文件（持久化）—— App 重启后仍可恢复
///
/// 工作流：
///   - [init] 在 App 启动时异步加载 JSON 到内存 [_cache]
///   - [get] 同步查内存层，供 _buildSplicedItem 在 build 前调用
///   - [put] 在 ComicImage._handleImageFrame 拿到真实尺寸时调用，
///     更新内存层并 debounce 写入 JSON
///
/// 优雅降级：未 init 完成或文件读取失败时，[get] 返回 null，
/// 调用方退回占位高度 + pixels 补偿兜底，不会引发崩溃。
class ImageSizeCache {
  ImageSizeCache._();

  static final ImageSizeCache _instance = ImageSizeCache._();

  static ImageSizeCache get instance => _instance;

  /// 内存层：imageKey → 真实像素尺寸。
  /// 与 ComicImage._cache（key=imageProvider.hashCode）不同，这里用 imageKey
  /// 作 key，便于跨进程重启后从 JSON 恢复（hashCode 在不同进程间不稳定）。
  final Map<String, Size> _cache = {};

  bool _initialized = false;

  /// JSON 持久化文件路径（App 数据目录下）。
  String get _filePath => "${App.dataPath}/image_sizes.json";

  /// 启动时异步加载 JSON 到内存。不阻塞 UI，加载完成前 [get] 返回 null。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final file = File(_filePath);
      if (await file.exists()) {
        final raw = await file.readAsString();
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          for (final entry in json.entries) {
            final v = entry.value;
            if (v is List && v.length == 2) {
              _cache[entry.key] = Size(
                (v[0] as num).toDouble(),
                (v[1] as num).toDouble(),
              );
            }
          }
        }
      }
    } catch (e, s) {
      Log.error("ImageSizeCache", "init failed: $e\n$s");
    }
  }

  /// 同步查询图片尺寸。未命中返回 null。
  Size? get(String imageKey) => _cache[imageKey];

  /// 记录图片真实尺寸。更新内存层并 debounce 写入 JSON。
  /// 在 ComicImage._handleImageFrame 拿到尺寸时调用。
  void put(String imageKey, int width, int height) {
    final size = Size(width.toDouble(), height.toDouble());
    final existing = _cache[imageKey];
    if (existing != null &&
        (existing.width - size.width).abs() < 0.5 &&
        (existing.height - size.height).abs() < 0.5) {
      return; // 尺寸未变，跳过
    }
    _cache[imageKey] = size;
    _scheduleFlush();
  }

  Timer? _flushTimer;
  bool _flushing = false;

  void _scheduleFlush() {
    _flushTimer?.cancel();
    // 2 秒 debounce：积累多次 put 后批量写一次，避免高频写文件
    _flushTimer = Timer(const Duration(seconds: 2), _flush);
  }

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      // 序列化当前内存层全量写入（简单可靠，文件预计 < 1MB）
      final Map<String, List<double>> serialized = {
        for (final e in _cache.entries) e.key: [e.value.width, e.value.height]
      };
      final file = File(_filePath);
      await file.writeAsString(jsonEncode(serialized));
    } catch (e, s) {
      Log.error("ImageSizeCache", "flush failed: $e\n$s");
    } finally {
      _flushing = false;
    }
  }

  /// 清空缓存（调试/重置用）。
  Future<void> clear() async {
    _cache.clear();
    _flushTimer?.cancel();
    try {
      final file = File(_filePath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
