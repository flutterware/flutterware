import 'package:material_ui/material_ui.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// Wraps a demo in **the app's own theme**, so what a preview shows is what the
/// Studio shows.
///
/// Deliberately not `shell.dart`'s `wrapInApp`: that one stands in for a
/// *project's* catalog shell — it exists to exercise the axes mechanism and
/// paints a generic `colorSchemeSeed` theme with a `SHELL dev roomy` probe in
/// the corner. A component read through it renders against `defaultTokens` by
/// fallback rather than against the real `appTheme`, which is the one thing a
/// component preview is for.
///
/// Was a private helper in the command palette's demo, which is where the
/// reasoning was worked out; it is here because six more demos need it.
Widget wrapInAppTheme(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: appTheme,
  // `Material`, not a bare `ColoredBox`: text outside a Material ancestor draws
  // with Flutter's yellow debug underline, which turns every label in a demo
  // into a false defect.
  home: Material(color: appTheme.colorScheme.surface, child: child),
);

/// The same, in the dark build. Paired with [wrapInAppTheme] so a component can
/// be reviewed in both without a system setting or a running app — the whole
/// dark theme is wired and, before these, nothing looked at it.
Widget wrapInDarkTheme(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: appDarkTheme,
  home: Material(color: appDarkTheme.colorScheme.surface, child: child),
);

/// The narrowest content pane the Studio ever lays out: `shellPaneMinimumSize`
/// itself, which is what every window minimum is built up from. **The pane, not
/// the content** — a demo adds its own `panelGutter` inside this, exactly as a
/// panel does, which is what leaves the 800px the dependencies table's seven
/// columns need.
///
/// A component that survives this survives the app, because below the minimum
/// the whole window scales rather than getting narrower — so this is not "a
/// small size", it is *the* small size, and there is exactly one.
const narrowPaneWidth = 848.0;

/// Lays [child] out at [narrowPaneWidth] against a marked edge, so a preview of
/// the tight case reads as deliberate rather than as a window someone resized.
class NarrowPane extends StatelessWidget {
  const NarrowPane({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Container(
      width: narrowPaneWidth,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: context.colors.line)),
      ),
      child: child,
    ),
  );
}
