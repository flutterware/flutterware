import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'shell.dart';

/// Animated and stateful, so the texture visibly proves the guest is live —
/// and so switching away and back shows the entry remounting with fresh state.
@Preview(name: 'Counter', wrapper: wrapInApp)
Widget counter() => const _Counter();

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  int _taps = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 24,
          children: [
            RotationTransition(
              turns: _controller,
              child: const FlutterLogo(size: 96),
            ),
            Text('Taps: $_taps', style: const TextStyle(fontSize: 28)),
            FilledButton(
              onPressed: () => setState(() => _taps++),
              child: const Text('Tap me'),
            ),
          ],
        ),
      ),
    );
  }
}

void main() => runApp(wrapInApp(counter()));
