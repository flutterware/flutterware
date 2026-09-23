// A textured, rigged model from outside: the Khronos "Fox" sample (see
// assets/models/NOTICE.md), through the version-zero 3D view and the walk.
//
// What it asks that the generated rigs could not: a texture decoded on the
// way in, a skin, and a clip somebody else authored — scrubbed by the
// playhead through `ModelView`'s ordinary arguments, the way a scene's
// motion drives them.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_probes/model_view.dart';
// ignore: implementation_imports
import 'package:flutterware/src/previews/playhead.dart';

import 'shell.dart';

@Preview(name: 'Fox probe', wrapper: wrapInApp)
Widget foxProbe() => const FoxProbe();

const foxProbeDuration = Duration(seconds: 2);

class FoxProbe extends StatefulWidget {
  const FoxProbe({super.key});

  @override
  State<FoxProbe> createState() => _FoxProbeState();
}

class _FoxProbeState extends State<FoxProbe> {
  var _t = Duration.zero;
  late final String _playheadId;

  @override
  void initState() {
    super.initState();
    _playheadId = PlayheadRegistry.instance.attach(_FoxPlayhead(this));
  }

  @override
  void dispose() {
    PlayheadRegistry.instance.detach(_playheadId);
    super.dispose();
  }

  void _seek(Duration position) => setState(() => _t = position);

  @override
  Widget build(BuildContext context) {
    var p = _t.inMicroseconds / foxProbeDuration.inMicroseconds;
    return ColoredBox(
      color: const Color(0xFF1C1F26),
      child: ModelView(
        asset: 'assets/models/fox.glb',
        yaw: -70 + 140 * p,
        pitch: 14,
        distance: 260,
        fov: 40,
        clip: 'Run',
        clipTime: _t.inMicroseconds / 1e6,
      ),
    );
  }
}

class _FoxPlayhead implements Playhead {
  _FoxPlayhead(this._state);

  final _FoxProbeState _state;

  @override
  Duration get duration => foxProbeDuration;

  @override
  void seek(Duration position) => _state._seek(position);
}
