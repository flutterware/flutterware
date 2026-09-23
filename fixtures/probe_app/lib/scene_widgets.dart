/// The widgets the scene group in `demo/scenes.dart` places, and the values
/// it exports — this package's own, small enough to read in one go.
///
/// A scene is rendered by the app whose widgets it uses, and this fixture is
/// that app for the scene tooling: what matters is that these are ordinary
/// widgets with ordinary arguments, not what they draw.
library;

import 'package:material_ui/material_ui.dart';

const brandColor = Color(0xFF6F4E37);

const subtitleStyle = TextStyle(
  fontSize: 18,
  fontStyle: FontStyle.italic,
  color: Color(0xFFD8C9BD),
);

/// A round badge with a glyph in it, sized by a number the timeline can key.
class Badge extends StatelessWidget {
  const Badge({super.key, this.glyph = '★', this.size = 56});

  final String glyph;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFB08968), Color(0xFF6F4E37)],
      ),
    ),
    child: Text(glyph, style: TextStyle(fontSize: size * 0.45)),
  );
}

class Spinner extends StatelessWidget {
  const Spinner({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: const CircularProgressIndicator(strokeWidth: 3),
  );
}

/// A call to action, so a scene can place a real button rather than a
/// rectangle that looks like one.
class CtaButton extends StatelessWidget {
  const CtaButton({super.key, this.label = 'Order now', this.style});

  final String label;

  /// The look, when a scene hands one over — a [ButtonStyle] declared once
  /// as a token. Null is the theme's button.
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) =>
      FilledButton(onPressed: () {}, style: style, child: Text(label));
}
