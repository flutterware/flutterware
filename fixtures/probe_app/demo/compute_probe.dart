// Does an isolate answer a second test body in one warm harness process?
//
// The 3D model probe's runtime import unpacks its primitives through
// `compute`, and the import landed in the first body of a harness and never in
// a later one. `compute` was suspected and is not the cause: it answers every
// body. The stall was a memoized flutter_scene future — see
// `lib/root_zone_scene.dart`. This keeps the question on its own: a `compute`
// in `initState`, tracked, and a green box once it answers.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/real_work.dart';

import 'shell.dart';

@Preview(name: 'Compute probe', wrapper: wrapInApp)
Widget computeProbe() => const ComputeProbe();

class ComputeProbe extends StatefulWidget {
  const ComputeProbe({super.key});

  @override
  State<ComputeProbe> createState() => _ComputeProbeState();
}

class _ComputeProbeState extends State<ComputeProbe> {
  int? _answer;

  @override
  void initState() {
    super.initState();
    RealWork.run(() => compute(_square, 12)).then((answer) {
      debugPrint('compute probe: $answer');
      if (mounted) setState(() => _answer = answer);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _answer == null ? Colors.white : const Color(0xFF00C853),
      child: Center(child: Text('${_answer ?? ''}')),
    );
  }
}

int _square(int n) => n * n;
