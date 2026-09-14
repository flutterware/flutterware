import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/comparison/ui/previews_tab.dart';
import 'package:flutterware_app/src/comparison/ui/scenarios_tab.dart';
import 'package:flutterware_app/src/comparison/web_viewer.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The exported page filters its list the way the panel does: a channel chip
/// is a control there too, not a label.
void main() {
  const card = 'demo/card.dart#card';
  const list = 'demo/list.dart#list';
  const pay = 'test/pay_test.dart#Pay';
  const refund = 'test/refund_test.dart#Refund';

  const pixels = {
    'pixels': {'width': 4, 'height': 4, 'changed': 0.5},
  };
  const texts = {
    'texts': {
      'added': ['Pay'],
      'removed': ['Buy'],
    },
  };

  var index = jsonEncode({
    'base': 'abc123',
    'against': 'origin/master',
    'previews': {
      'items': [
        {'id': card, 'state': 'changed', 'channels': pixels},
        {'id': list, 'state': 'changed', 'channels': texts},
      ],
    },
    'scenarios': {
      'items': [
        {
          'id': pay,
          'state': 'changed',
          'steps': [
            {'id': 'Cart', 'state': 'changed', 'channels': pixels},
          ],
        },
        {
          'id': refund,
          'state': 'changed',
          'steps': [
            {'id': 'Refund', 'state': 'changed', 'channels': texts},
          ],
        },
      ],
    },
  });

  Future<void> open(WidgetTester tester, String tab) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: ComparisonWebViewer(
          base: Uri.parse('http://host/page#$tab'),
          raw: index,
          history: _History(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Text chip(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label));

  testWidgets('a channel chip hides the rows only it spoke for', (
    tester,
  ) async {
    await open(tester, 'previews');
    expect(find.byKey(previewRowKey(list)), findsOneWidget);

    await tester.tap(find.text('texts · 1 entry'));
    await tester.pumpAndSettle();

    expect(find.byKey(previewRowKey(list)), findsNothing);
    expect(find.byKey(previewRowKey(card)), findsOneWidget);
    // And the chip says so: struck through, keeping the count it hides.
    expect(
      chip(tester, 'texts · 1 entry').style?.decoration,
      TextDecoration.lineThrough,
    );

    await tester.tap(find.text('texts · 1 entry'));
    await tester.pumpAndSettle();

    expect(find.byKey(previewRowKey(list)), findsOneWidget);
    expect(chip(tester, 'texts · 1 entry').style?.decoration, isNull);
  });

  testWidgets('a flow goes when every step that changed is hidden', (
    tester,
  ) async {
    await open(tester, 'scenarios');
    expect(find.byKey(scenarioRowKey(refund)), findsOneWidget);

    await tester.tap(find.text('texts · 1 step'));
    await tester.pumpAndSettle();

    expect(find.byKey(scenarioRowKey(refund)), findsNothing);
    expect(find.byKey(scenarioRowKey(pay)), findsOneWidget);
  });
}

class _History implements ViewerHistory {
  @override
  void replace(String fragment) {}

  @override
  void push(String fragment, {required String from}) {}

  @override
  String? get pushedFrom => null;

  @override
  void back() {}

  @override
  Stream<String> get changes => const Stream.empty();
}
