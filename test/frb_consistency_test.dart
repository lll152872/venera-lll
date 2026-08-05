import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// 检测文档记载的 FRB（flutter_rust_bridge）版本脱节 bug。
///
/// 根因：中国镜像污染 `.dart_tool/package_config.json`，把
/// `flutter_rust_bridge` 指向镜像版（如 pub.flutter-io.cn/...-2.12.0），
/// 而 `pubspec.lock` 锁的是官方版（如 2.11.1），两者脱节会导致
/// 运行时所有网络请求报 "RustLib has not been initialized"。
///
/// 该测试直接对比两份文件，无需启动 App / 真机 / 点进漫画即可提前发现。
void main() {
  const mirrorDomain = 'pub.flutter-io.cn';

  String projectRoot() => Directory.current.path;

  Map<String, dynamic> parsePackageConfig(String root) {
    final file = File('$root/.dart_tool/package_config.json');
    expect(file.existsSync(), isTrue,
        reason: '.dart_tool/package_config.json 不存在，可能尚未 pub get');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return json;
  }

  Map<dynamic, dynamic> parsePubspecLock(String root) {
    final file = File('$root/pubspec.lock');
    expect(file.existsSync(), isTrue, reason: 'pubspec.lock 不存在');
    final yaml = loadYaml(file.readAsStringSync()) as Map<dynamic, dynamic>;
    return yaml;
  }

  test('pubspec.lock 与 package_config.json 必须来自同一 host（无镜像污染）', () {
    final root = projectRoot();
    final pkgConfig = parsePackageConfig(root);
    final packages = (pkgConfig['packages'] as List).cast<Map<String, dynamic>>();

    final polluted = <String>[];
    for (final p in packages) {
      final rootUri = (p['rootUri'] as String?) ?? '';
      if (rootUri.contains(mirrorDomain)) {
        polluted.add('${p['name']} -> $rootUri');
      }
    }

    expect(polluted, isEmpty,
        reason: '检测到 $mirrorDomain 镜像污染（共 ${polluted.length} 个包），'
            '会导致 FRB 版本脱节。修复：\n'
            '  rm .dart_tool/package_config.json\n'
            '  unset PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL\n'
            '  flutter pub get\n'
            '被污染的包：${polluted.take(10).join("\n  ")}');
  });

  test('flutter_rust_bridge 解析版本必须与 pubspec.lock 锁定的版本一致', () {
    final root = projectRoot();
    final pkgConfig = parsePackageConfig(root);
    final lock = parsePubspecLock(root);

    // 1. 从 pubspec.lock 取锁定版本
    final lockPkg = (lock['packages'] as Map)['flutter_rust_bridge'] as Map?;
    expect(lockPkg, isNotNull, reason: 'pubspec.lock 未包含 flutter_rust_bridge');
    final lockedVersion = lockPkg!['version'].toString();

    // 2. 从 package_config.json 取实际解析版本（rootUri 末尾 -x.y.z）
    final packages = (pkgConfig['packages'] as List).cast<Map<String, dynamic>>();
    final frb = packages.firstWhere(
      (p) => p['name'] == 'flutter_rust_bridge',
      orElse: () => <String, dynamic>{},
    );
    expect(frb.isNotEmpty, isTrue,
        reason: 'package_config.json 未包含 flutter_rust_bridge');

    final rootUri = (frb['rootUri'] as String?) ?? '';
    final match = RegExp(r'flutter_rust_bridge-(\d+\.\d+\.\d+)')
        .firstMatch(rootUri);
    expect(match, isNotNull,
        reason: '无法从 package_config.json 解析 flutter_rust_bridge 版本：$rootUri');
    final resolvedVersion = match!.group(1)!;

    expect(resolvedVersion, equals(lockedVersion),
        reason: 'FRB 版本脱节：pubspec.lock 锁 $lockedVersion，'
            '但 package_config.json 解析为 $resolvedVersion。'
            '这会导致运行时 "RustLib has not been initialized"。');
  });
}
