import 'package:flutter/widget_previews.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show FieldKind;
import 'package:flutterware/world.dart';
import 'package:flutterware_app/src/ui/stage.dart' show stageGroundColor;
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/world/autofill_bar.dart';
import 'package:flutterware_app/src/world/world_autofill.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

/// What a focused field in a person's app is offered: under a device on the
/// stage, a pill of whose each address is; in the person's panel, the
/// addresses themselves.

@Preview(name: 'Autofill bar', group: 'Worlds', wrapper: wrapInAppTheme)
Widget autofillBar() => const _Bars();

@Preview(name: 'Autofill bar · dark', group: 'Worlds', wrapper: wrapInDarkTheme)
Widget autofillBarDark() => const _Bars();

const _people = [
  Person('Manager', email: 'manager@example.com', password: 'ward-7'),
  Person('Nurse', email: 'nurse@example.com', password: 'night-shift'),
  Person('Porter', email: 'porter@example.com', phone: '+447700900003'),
];

List<WorldOffer> _offers(FieldKind kind, {List<FieldKind> group = const []}) =>
    offersFor('Manager', WorldField(kind, group: group), _people);

class _Bars extends StatelessWidget {
  const _Bars();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    Color colorOf(String? person) =>
        colors.person(_people.indexWhere((p) => p.name == person).clamp(0, 9));
    Widget under(String label, Widget bar) => Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.lg),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(label, style: context.type.bodyMuted),
          ),
          bar,
        ],
      ),
    );
    var code = [
      WorldOffer(
        kind: FieldKind.code,
        label: 'the code from the SMS',
        value: '482193',
        message: 'lab/12',
      ),
    ];
    return SizedBox(
      width: 760,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColoredBox(
            color: stageGroundColor(colors),
            child: Padding(
              padding: const EdgeInsets.all(FwSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var (label, kind, offers, refused) in [
                    (
                      'Address',
                      FieldKind.email,
                      _offers(FieldKind.email),
                      null,
                    ),
                    (
                      'Sign-in form',
                      FieldKind.password,
                      _offers(FieldKind.password, group: [FieldKind.email]),
                      null,
                    ),
                    ('Code', FieldKind.code, code, null),
                    (
                      'Refused',
                      FieldKind.email,
                      _offers(FieldKind.email),
                      "No field has focus in Manager's app. Tap one first, "
                          'then try again.',
                    ),
                  ])
                    under(
                      label,
                      AutofillOffers(
                        kind: kind,
                        offers: offers,
                        colorOf: colorOf,
                        refused: refused,
                        onPick: (_) {},
                      ),
                    ),
                ],
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(top: FwSpacing.xl),
            padding: const EdgeInsets.only(top: FwSpacing.md),
            decoration: BoxDecoration(
              color: colors.bg,
              border: Border.all(color: colors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AutofillOffers(
                  kind: FieldKind.email,
                  offers: _offers(FieldKind.email),
                  colorOf: colorOf,
                  detailed: true,
                  onPick: (_) {},
                ),
                AutofillOffers(
                  kind: FieldKind.email,
                  offers: _offers(FieldKind.email, group: [FieldKind.password]),
                  colorOf: colorOf,
                  detailed: true,
                  onPick: (_) {},
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
