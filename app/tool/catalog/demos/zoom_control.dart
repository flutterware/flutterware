import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/previews/zoom_control.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The preview panel's own magnification capsule, in every state it takes.
///
/// What this is for. The control is a number and a cross in a 24pt capsule,
/// and everything worth deciding about it is a glyph or a pixel: whether the
/// dim state reads as *at rest* rather than as broken, whether the cross reads
/// as a way out at 11pt, whether the readout stops shoving the capsule about as
/// the number climbs from 1.4× to three digits. None of that survives a widget
/// test, which has no icon font, and none of it can be judged from the running
/// studio, where the capsule is 50px in the corner of a bar and every state
/// past the first needs a gesture to reach.
///
/// It is possible at all because the control takes values and callbacks rather
/// than a `CatalogSession` — see [ZoomControl].

@Preview(name: 'Zoom capsule', group: 'Previews panel', wrapper: wrapInAppTheme)
Widget zoomCapsule() => const _Sheet();

@Preview(
  name: 'Zoom capsule · dark',
  group: 'Previews panel',
  wrapper: wrapInDarkTheme,
)
Widget zoomCapsuleDark() => const _Sheet();

class _Sheet extends StatelessWidget {
  const _Sheet();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colors.panel,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: const [
              _Row(caption: 'at rest — dim, and does nothing', scale: 1),
              _Row(caption: 'just past rest — one decimal', scale: 1.4),
              _Row(caption: 'a control, filled', scale: 3.6),
              // The widths that decide whether the bar reflows under the
              // pointer as the number climbs.
              _Row(caption: 'two digits', scale: 17),
              _Row(
                caption: 'past the pixel budget — still zooms, softly',
                scale: 120,
              ),
              // Life-size but not centred — the state that used to leave this
              // dim with a stage nobody could put back.
              _Row(caption: 'life-size, still panned', scale: 1, atRest: false),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.caption, required this.scale, this.atRest});

  final String caption;
  final double scale;

  /// Defaults to whatever the scale implies, which is right for every row but
  /// the one that exists to show the two coming apart.
  final bool? atRest;

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 16,
      children: [
        ZoomControl(scale: scale, atRest: atRest ?? scale <= 1, onReset: () {}),
        Text(caption, style: context.type.caption),
      ],
    );
  }
}
