// 目的：锁住「底部进度条」这一组交互行为：
//   A. 点击轨道 → onChanged 收到指针所在位置的页码
//   B. 横向拖动 → 连续回调（原来只有 onVerticalDragUpdate，桌面端横向拖动无反应）
//   C. 拖动时滑块圆点跟手（本地立即更新，不等父组件重建）
//
// 这三条对应用户报的「点进度条 → 内容跳了但页码/滑块不动」。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/custom_slider.dart';

/// 滑块圆点：22x22 的圆形 Container。
/// Container 不暴露 width/height 字段，尺寸体现在 constraints 上。
Finder get thumbFinder => find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.constraints?.maxWidth == 22 &&
      w.constraints?.maxHeight == 22,
);

/// CustomSlider 内部 padding 左右各 24px，轨道宽度 = 控件宽度 - 48。
const double kPadX = 24;
const double kMin = 1;
const double kMax = 11;
const int kDivisions = 10;

void main() {
  testWidgets('点击轨道 → onChanged 收到该位置的页码', (tester) async {
    final emitted = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: CustomSlider(
                min: kMin,
                max: kMax,
                value: 1,
                divisions: kDivisions,
                focusNode: FocusNode(),
                onChanged: emitted.add,
              ),
            ),
          ),
        ),
      ),
    );

    final box = tester.getRect(find.byType(CustomSlider));
    final trackWidth = box.width - kPadX * 2;
    // 点在轨道 70% 处
    final tapX = box.left + kPadX + trackWidth * 0.7;
    await tester.tapAt(Offset(tapX, box.center.dy));
    await tester.pump();

    expect(emitted, isNotEmpty, reason: '点击轨道必须回调 onChanged');
    final expected = (0.7 * kDivisions).round() + kMin;
    expect(emitted.last, closeTo(expected, 0.001));
  });

  testWidgets('横向拖动 → 连续回调（桌面端主要交互方式）', (tester) async {
    final emitted = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: CustomSlider(
                min: kMin,
                max: kMax,
                value: 1,
                divisions: kDivisions,
                focusNode: FocusNode(),
                onChanged: emitted.add,
              ),
            ),
          ),
        ),
      ),
    );

    final box = tester.getRect(find.byType(CustomSlider));
    final trackWidth = box.width - kPadX * 2;
    final startX = box.left + kPadX + trackWidth * 0.1;
    final endX = box.left + kPadX + trackWidth * 0.8;

    final gesture = await tester.startGesture(
      Offset(startX, box.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 20));
    // 分多步向右拖，模拟真实拖动
    for (var i = 1; i <= 4; i++) {
      await gesture.moveTo(
        Offset(startX + (endX - startX) * i / 4, box.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pump();

    expect(emitted.length, greaterThan(1), reason: '拖动必须连续回调');
    expect(
      emitted.last,
      greaterThan(emitted.first),
      reason: '向右拖 → 页码递增',
    );
    expect(emitted.last, closeTo((0.8 * kDivisions).round() + kMin, 0.001));
  });

  testWidgets('拖动时圆点跟手（不依赖父组件重建）', (tester) async {
    // 父组件的 value 故意不随拖动更新：只有滑块自己维护本地值，
    // 圆点才会跟手；靠父组件回传值的实现圆点会原地不动。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: CustomSlider(
                min: kMin,
                max: kMax,
                value: 1,
                divisions: kDivisions,
                focusNode: FocusNode(),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final box = tester.getRect(find.byType(CustomSlider));
    final trackWidth = box.width - kPadX * 2;
    final before = tester.getCenter(thumbFinder).dx;

    final gesture = await tester.startGesture(
      Offset(box.left + kPadX + trackWidth * 0.1, box.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(
      Offset(box.left + kPadX + trackWidth * 0.8, box.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 20));
    final after = tester.getCenter(thumbFinder).dx;
    expect(
      after - before,
      greaterThan(trackWidth * 0.5),
      reason: '圆点应跟随指针移动',
    );

    await gesture.up();
    await tester.pump();
  });
}
