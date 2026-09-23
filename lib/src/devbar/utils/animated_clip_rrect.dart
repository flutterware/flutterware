import 'package:material_ui/material_ui.dart';

class AnimatedClipRRect extends ImplicitlyAnimatedWidget {
  AnimatedClipRRect({
    super.key,
    required this.borderRadius,
    required this.child,
    super.curve,
    required super.duration,
    super.onEnd,
  });

  final BorderRadius borderRadius;

  /// The widget below this widget in the tree.
  ///
  /// {@macro flutter.widgets.child}
  final Widget child;

  @override
  AnimatedWidgetBaseState<AnimatedClipRRect> createState() =>
      _AnimatedClipRRectState();
}

class _AnimatedClipRRectState
    extends AnimatedWidgetBaseState<AnimatedClipRRect> {
  BorderRadiusTween? _borderRadius;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _borderRadius =
        visitor(
              _borderRadius,
              widget.borderRadius,
              (dynamic value) =>
                  BorderRadiusTween(begin: value as BorderRadius),
            )!
            as BorderRadiusTween;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: _borderRadius!.evaluate(animation)!,
      child: widget.child,
    );
  }
}
