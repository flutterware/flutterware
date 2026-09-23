import 'package:material_ui/material_ui.dart';
import 'package:flutterware/previews.dart';

/// The app chrome a demo needs to look like itself: theme, localizations,
/// directionality.
///
/// Demos are widgets, not apps — the catalog renders the widget and nothing
/// else — so anything that normally comes from `MaterialApp` has to be put back
/// by a wrapper. This is that wrapper, and it is shared rather than repeated
/// because a demo that themes itself differently from the app is not a preview
/// of the app.
///
/// Wrapping it in a [PreviewShell] is what puts the switches below in the
/// catalog's top bar, where they apply to every demo and stay put as you move
/// between them. It changes nothing anywhere else: this is still a plain
/// `Widget Function(Widget)`, and outside the catalog — in the real app, or in
/// Flutter's own previewer — each switch answers with the default written here.
Widget wrapInApp(Widget child) => PreviewShell(
  'app',
  builder: (context, axes) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: axes.flag('dark', false) ? Brightness.dark : Brightness.light,
      colorSchemeSeed: Colors.white,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    locale: axes.picker('locale', {
      'English': const Locale('en'),
      'Français': const Locale('fr'),
    }, const Locale('en')),
    localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
    supportedLocales: const [Locale('en'), Locale('fr')],
    home: child,
  ),
);
