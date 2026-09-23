import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../utils/value_stream.dart';

class AutoScroller<T> extends StatefulWidget {
  final ValueStream<T> stream;
  final Widget Function(BuildContext, ScrollController, T) builder;

  const AutoScroller({super.key, required this.stream, required this.builder});

  @override
  State<AutoScroller<T>> createState() => _AutoScrollerState<T>();
}

class _AutoScrollerState<T> extends State<AutoScroller<T>> {
  late ScrollController _scrollController;
  late StreamSubscription _scrollSubscription;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();

    _scrollSubscription = widget.stream.stream.listen((_) {
      Timer(Duration(milliseconds: 100), () {
        if (mounted && _scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: Duration(milliseconds: 100),
            curve: Curves.easeInOut,
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _scrollSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueStreamBuilder<T>(
      stream: widget.stream,
      builder: (context, snapshot) {
        return widget.builder(context, _scrollController, snapshot);
      },
    );
  }
}
