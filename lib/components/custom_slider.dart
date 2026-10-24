import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';

/// patched slider.dart with RtL support
class _SliderDefaultsM3 extends SliderThemeData {
  _SliderDefaultsM3(this.context)
      : super(trackHeight: 4.0);

  final BuildContext context;
  late final ColorScheme _colors = Theme.of(context).colorScheme;

  @override
  Color? get activeTrackColor => _colors.primary;

  @override
  Color? get inactiveTrackColor => _colors.surfaceContainerHighest;

  @override
  Color? get secondaryActiveTrackColor => _colors.primary.toOpacity(0.54);

  @override
  Color? get disabledActiveTrackColor => _colors.onSurface.toOpacity(0.38);

  @override
  Color? get disabledInactiveTrackColor => _colors.onSurface.toOpacity(0.12);

  @override
  Color? get disabledSecondaryActiveTrackColor => _colors.onSurface.toOpacity(0.12);

  @override
  Color? get activeTickMarkColor => _colors.onPrimary.toOpacity(0.38);

  @override
  Color? get inactiveTickMarkColor => _colors.onSurfaceVariant.toOpacity(0.38);

  @override
  Color? get disabledActiveTickMarkColor => _colors.onSurface.toOpacity(0.38);

  @override
  Color? get disabledInactiveTickMarkColor => _colors.onSurface.toOpacity(0.38);

  @override
  Color? get thumbColor => _colors.primary;

  @override
  Color? get disabledThumbColor => Color.alphaBlend(_colors.onSurface.toOpacity(0.38), _colors.surface);

  @override
  Color? get overlayColor => WidgetStateColor.resolveWith((Set<WidgetState> states) {
    if (states.contains(WidgetState.dragged)) {
      return _colors.primary.toOpacity(0.1);
    }
    if (states.contains(WidgetState.hovered)) {
      return _colors.primary.toOpacity(0.08);
    }
    if (states.contains(WidgetState.focused)) {
      return _colors.primary.toOpacity(0.1);
    }

    return Colors.transparent;
  });

  @override
  TextStyle? get valueIndicatorTextStyle => Theme.of(context).textTheme.labelMedium!.copyWith(
    color: _colors.onPrimary,
  );

  @override
  SliderComponentShape? get valueIndicatorShape => const DropSliderValueIndicatorShape();
}

class CustomSlider extends StatefulWidget {
  const CustomSlider({required this.min, required this.max, required this.value, required this.divisions, required this.onChanged, required this.focusNode, this.reversed = false, super.key});

  final double min;

  final double max;

  final double value;

  final int divisions;

  final void Function(double) onChanged;

  final FocusNode? focusNode;

  final bool reversed;

  @override
  State<CustomSlider> createState() => _CustomSliderState();
}

class _CustomSliderState extends State<CustomSlider> {
  late double value;

  /// 用户是否正在交互（按下 / 拖动中）。
  ///
  /// 交互期间以本地值为准：父组件回传的值可能还没更新（阅读器走的是
  /// 「乐观更新 + 动画落点校正」链路），直接覆盖会让滑块圆点往回跳。
  bool _interacting = false;

  @override
  void initState() {
    super.initState();
    value = widget.value;
  }

  @override
  void didUpdateWidget(CustomSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_interacting && widget.value != oldWidget.value) {
      setState(() {
        value = widget.value;
      });
    }
  }

  /// 把指针横坐标换算成滑块值并回调（点击 / 拖动共用同一条换算路径）。
  ///
  /// 换算规则与 [CustomSlider.divisions] 对齐：轨道等分成 divisions 段，
  /// 每段对应 (max - min) / divisions 的值；指针移出轨道按边界夹取。
  void _emitFromDx(double dx, double trackWidth) {
    if (widget.reversed) {
      dx = trackWidth - dx;
    }
    if (dx < 0) dx = 0;
    if (dx > trackWidth) dx = trackWidth;
    final gap = trackWidth / widget.divisions;
    final gapValue = (widget.max - widget.min) / widget.divisions;
    var v = (dx / gap).round() * gapValue + widget.min;
    if (v < widget.min) v = widget.min;
    if (v > widget.max) v = widget.max;
    // 本地立即更新：圆点跟手，不等父组件重建
    if (v != value) {
      setState(() {
        value = v;
      });
    }
    widget.onChanged.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = _SliderDefaultsM3(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      child: widget.max - widget.min > 0 ? LayoutBuilder(
        builder: (context, constraints) => MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: (details) {
              _interacting = true;
              _emitFromDx(details.localPosition.dx, constraints.maxWidth);
            },
            onTapUp: (_) {
              _interacting = false;
            },
            onTapCancel: () {
              _interacting = false;
            },
            // pan 而不是 verticalDrag：桌面端是横向拖动滑块，
            // 原来只有 onVerticalDragUpdate → 横向拖动完全没反应。
            onPanStart: (details) {
              _interacting = true;
              _emitFromDx(details.localPosition.dx, constraints.maxWidth);
            },
            onPanUpdate: (details) {
              _emitFromDx(details.localPosition.dx, constraints.maxWidth);
            },
            onPanEnd: (_) {
              _interacting = false;
            },
            onPanCancel: () {
              _interacting = false;
            },
            child: SizedBox(
              height: 24,
              child: Center(
                child: SizedBox(
                  height: 24,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: Center(
                          child: Container(
                            width: double.infinity,
                            height: 6,
                            decoration: BoxDecoration(
                                color: theme.inactiveTrackColor,
                                borderRadius: const BorderRadius.all(Radius.circular(10))
                            ),
                          ),
                        ),
                      ),
                      if(constraints.maxWidth / widget.divisions > 10)
                        Positioned.fill(
                          child: Row(
                            children: (){
                              var res = <Widget>[];
                              for(int i = 0; i<widget.divisions-1; i++){
                                res.add(const Spacer());
                                res.add(Container(
                                  width: 4,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: colorScheme.surface.withRed(10),
                                    shape: BoxShape.circle,
                                  ),
                                ));
                              }
                              res.add(const Spacer());
                              return res;
                            }.call(),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          bottom: 0,
                          left: widget.reversed ? null : 0,
                          right: widget.reversed ? 0 : null,
                          child: Center(
                            child: Container(
                              width: constraints.maxWidth * ((value - widget.min) / (widget.max - widget.min)),
                              height: 8,
                              decoration: BoxDecoration(
                                  color: theme.activeTrackColor,
                                  borderRadius: const BorderRadius.all(Radius.circular(10))
                              ),
                            ),
                          )
                        ),
                      Positioned(
                        top: 0,
                        bottom: 0,
                        left: widget.reversed ? null : constraints.maxWidth * ((value - widget.min) / (widget.max - widget.min))-11,
                        right: !widget.reversed ? null : constraints.maxWidth * ((value - widget.min) / (widget.max - widget.min))-11,
                        child: Center(
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: theme.activeTrackColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      )
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ) : null,
    );
  }
}