import 'dart:async';

import 'package:flutter/widgets.dart';

import 'value_stream.dart';

/// [ValueListenableBuilder]'s counterpart for a [ValueStream].
///
/// The one place the pure-Dart notification primitive meets Flutter. It exists
/// because `ListenableBuilder` cannot accept a [ValueStream] — and because the
/// widget's subscription *is* the demand signal: mounting starts the work,
/// unmounting releases it, so the work is lazy with no extra machinery.
///
/// Unlike `StreamBuilder` there is no initial frame without data: a
/// [ValueStream] always has a current value, so [builder] gets a real one on
/// the very first build.
class ValueStreamBuilder<T> extends StatefulWidget {
  const ValueStreamBuilder({
    super.key,
    required this.stream,
    required this.builder,
    this.child,
  });

  final ValueStream<T> stream;

  /// Same shape as [ValueListenableBuilder]'s, so call sites port across
  /// unchanged.
  final Widget Function(BuildContext context, T value, Widget? child) builder;

  /// Passed back to [builder] untouched — the subtree that does not depend on
  /// the value and should not be rebuilt with it.
  final Widget? child;

  @override
  State<ValueStreamBuilder<T>> createState() => _ValueStreamBuilderState<T>();
}

class _ValueStreamBuilderState<T> extends State<ValueStreamBuilder<T>> {
  late T _value;
  StreamSubscription<T>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(ValueStreamBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stream != widget.stream) {
      _unsubscribe();
      _subscribe();
    }
  }

  void _subscribe() {
    // Seeded before listening so the first build has the value even though the
    // stream delivers its replay asynchronously.
    _value = widget.stream.value;
    _subscription = widget.stream.listen((value) {
      if (!mounted) return;
      setState(() => _value = value);
    });
  }

  void _unsubscribe() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _value, widget.child);
}
