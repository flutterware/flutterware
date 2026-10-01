import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/previews.dart';
import 'package:flutterware/previews_guest.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/axes_controls.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knobs.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knobs_editor.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/toolbar.dart';
import 'package:flutterware_app/src/previews/knob_picker.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// A picker in both of its styles, where it is actually drawn: on the preview
/// panel's top bar as an axis, and in the Controls tab among the other knobs.
///
/// What this is for. A segmented control is taller than the 24pt fields it
/// shares a row with, and whether that reads as one bar or as two sizes of
/// control is a question only a picture answers. The last knob asks for
/// segments over seven options, and is drawn as the dropdown it falls back to.
@Preview(
  name: 'Picker styles',
  group: 'Previews panel',
  wrapper: wrapInAppTheme,
)
Widget pickerStyles() => const _Sheet();

@Preview(
  name: 'Picker styles · dark',
  group: 'Previews panel',
  wrapper: wrapInDarkTheme,
)
Widget pickerStylesDark() => const _Sheet();

/// The same declarations on an in-app catalog page, which draws them with its
/// own toolbar and knob editor rather than the studio's — light only, because
/// that page is.
///
/// The shell here is a real [PreviewShell], so the studio's own top bar shows
/// its two axes too when this entry is open.
@Preview(name: 'Picker styles · catalog page', group: 'Previews panel')
Widget pickerStylesOnAPage() => const _OnAPage();

const _themes = ['Light', 'Dark'];
const _flavors = ['Dev', 'Staging', 'Production'];
const _densities = ['Compact', 'Roomy'];
const _sizes = ['S', 'M', 'L'];
const _locales = ['en', 'fr', 'de', 'nl', 'es', 'it', 'pt'];

KnobDescriptor _picker(
  String name,
  List<String> options, {
  PickerStyle style = PickerStyle.segmented,
}) => KnobDescriptor(
  name: name,
  kind: KnobKind.picker,
  value: options.first,
  defaultValue: options.first,
  options: options,
  style: style,
);

class _Sheet extends StatefulWidget {
  const _Sheet();

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  final _values = <String, String?>{};

  Widget _labelled(
    BuildContext context,
    KnobDescriptor knob, {
    required double gap,
    bool markDefault = false,
  }) {
    var value = _values[knob.name] ?? knob.defaultValue as String?;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      children: [
        Text(
          knob.name,
          style: context.type.caption.copyWith(
            color: value == knob.defaultValue
                ? context.colors.mut
                : context.colors.ink,
          ),
        ),
        KnobPicker(
          knob: knob,
          value: value,
          onChanged: (v) => setState(() => _values[knob.name] = v),
          markDefault: markDefault,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.bg,
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: FwSpacing.xxl,
          children: [
            // The top bar: 36 tall, axes labelled beside their controls.
            Container(
              color: colors.panel,
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: FwSpacing.lg,
                children: [
                  _labelled(
                    context,
                    _picker('theme', _themes),
                    gap: FwSpacing.sm,
                    markDefault: true,
                  ),
                  _labelled(
                    context,
                    _picker('flavor', _flavors, style: PickerStyle.dropdown),
                    gap: FwSpacing.sm,
                    markDefault: true,
                  ),
                ],
              ),
            ),
            // The Controls tab: knobs wrapped in a row, beside a text field.
            Container(
              width: 720,
              color: colors.panel,
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.lg,
                vertical: FwSpacing.md,
              ),
              child: Wrap(
                spacing: FwSpacing.xxl,
                runSpacing: FwSpacing.md,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _labelled(
                    context,
                    _picker('density', _densities),
                    gap: FwSpacing.md,
                  ),
                  _labelled(
                    context,
                    _picker('size', _sizes),
                    gap: FwSpacing.md,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: FwSpacing.md,
                    children: [
                      Text(
                        'label',
                        style: context.type.caption.copyWith(color: colors.mut),
                      ),
                      KnobBox(
                        width: 140,
                        child: Text(
                          'Hello',
                          style: context.type.caption.copyWith(
                            color: colors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                  _labelled(
                    context,
                    _picker('locale', _locales),
                    gap: FwSpacing.md,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Flavor { dev, staging, prod }

class _OnAPage extends StatefulWidget {
  const _OnAPage();

  @override
  State<_OnAPage> createState() => _OnAPageState();
}

class _OnAPageState extends State<_OnAPage> {
  late final _knobs = EditableKnobs(
    onRefresh: () => setState(() {}),
    onAdded: () {},
  );

  @override
  void dispose() {
    _knobs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(useMaterial3: true),
      home: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Toolbar(children: [AxesControls()]),
            Expanded(
              child: PreviewShell(
                'picker-styles',
                builder: (context, axes) {
                  var theme = axes.picker(
                    'theme',
                    {'Light': Brightness.light, 'Dark': Brightness.dark},
                    Brightness.light,
                    style: PickerStyle.segmented,
                  );
                  var flavor = axes.picker('flavor', {
                    'Dev': _Flavor.dev,
                    'Staging': _Flavor.staging,
                    'Production': _Flavor.prod,
                  }, _Flavor.dev);
                  var size = _knobs.picker(
                    'size',
                    {'S': 12.0, 'M': 16.0, 'L': 22.0},
                    16.0,
                    style: PickerStyle.segmented,
                  );
                  _knobs.picker(
                    'locale',
                    {for (var locale in _locales) locale: locale},
                    'en',
                    style: PickerStyle.segmented,
                  );
                  var dark = theme == Brightness.dark;
                  return ColoredBox(
                    color: dark ? const Color(0xff202124) : Colors.white,
                    child: Center(
                      child: Text(
                        '${flavor.name} · ${theme.name}',
                        style: TextStyle(
                          fontSize: size,
                          color: dark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            SizedBox(height: 120, child: KnobsEditor(_knobs)),
          ],
        ),
      ),
    );
  }
}
