import 'dart:async';

import 'package:material_ui/material_ui.dart';

class ValueStream<T> {
  final _controller = StreamController<T>.broadcast();
  T _lastValue;

  ValueStream(this._lastValue);

  T get value => _lastValue;
  set value(T newValue) {
    add(newValue);
  }

  void add(T value) {
    _lastValue = value;
    _controller.add(value);
  }

  Stream<T> get stream => _controller.stream;

  bool get hasListener => _controller.hasListener;

  void Function()? get onListen => _controller.onListen;
  set onListen(void Function()? onListen) {
    _controller.onListen = onListen;
  }

  void Function()? get onCancel => _controller.onCancel;
  set onCancel(void Function()? onCancel) {
    _controller.onCancel = onCancel;
  }

  void dispose() {
    _controller.close();
  }
}

class ValueStreamBuilder<T> extends StatelessWidget {
  final ValueStream<T> stream;
  final Widget Function(BuildContext, T) builder;

  const ValueStreamBuilder({
    super.key,
    required this.stream,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<T>(
      stream: stream.stream,
      initialData: stream.value,
      builder: (context, snapshot) => builder(context, snapshot.data as T),
    );
  }
}
