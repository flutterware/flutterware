import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/comparison/ui/findings_tab.dart';
import 'package:flutterware_app/src/comparison/ui/merged_tree.dart';
import 'package:flutterware_app/src/comparison/ui/not_in_comparison.dart';
import 'package:flutterware_app/src/comparison/ui/previews_tab.dart';
import 'package:flutterware_app/src/comparison/ui/step_page.dart';
import 'package:flutterware_app/src/comparison/web_viewer.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// What the exported comparison does to the browser's history as a reader
/// moves through it, and what it draws for a link naming something it does
/// not have.
void main() {
  const flow = 'test/pay_test.dart#Pay';

  var index = jsonEncode({
    'base': 'abc123',
    'against': 'origin/master',
    'previews': {
      'items': [
        {'id': 'demo/card.dart#card', 'state': 'changed'},
        {'id': 'demo/list.dart#list', 'state': 'changed'},
      ],
    },
    'scenarios': {
      'items': [
        {
          'id': flow,
          'state': 'changed',
          'steps': [
            {'id': 'Cart', 'state': 'changed'},
            {'id': 'Pay', 'state': 'same'},
          ],
        },
      ],
    },
  });

  var previewsOnly = jsonEncode({
    'base': 'abc123',
    'against': 'origin/master',
    'previews': {
      'items': [
        {'id': 'demo/card.dart#card', 'state': 'changed'},
      ],
    },
  });

  late _History history;

  Future<void> open(
    WidgetTester tester, {
    String fragment = '',
    String? raw,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    history = _History();
    addTearDown(history.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: ComparisonWebViewer(
          base: Uri.parse('http://host/page#$fragment'),
          raw: raw ?? index,
          history: history,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('back retraces the way in', () {
    testWidgets('a page opened on nothing names the tab it chose', (
      tester,
    ) async {
      await open(tester);

      expect(history.log, ['replace findings']);
    });

    testWidgets('a link is left naming what it named', (tester) async {
      await open(tester, fragment: 'previews/demo/card.dart#card');

      expect(history.log, isEmpty);
    });

    testWidgets('another row in the same list replaces', (tester) async {
      await open(tester, fragment: 'previews/demo/card.dart#card');

      await tester.tap(find.byKey(previewRowKey('demo/list.dart#list')));
      await tester.pumpAndSettle();

      expect(history.log, ['replace previews/demo/list.dart#list']);
    });

    testWidgets('another tab is an entry', (tester) async {
      await open(tester, fragment: 'previews/demo/card.dart#card');

      await tester.tap(find.text('scenarios'));
      await tester.pumpAndSettle();

      expect(history.log, ['push scenarios from previews/demo/card.dart#card']);
    });

    testWidgets('a finding opened from the list is an entry', (tester) async {
      await open(tester, fragment: 'findings');

      await tester.tap(find.byKey(findingRowKey('demo/card.dart#card')));
      await tester.pumpAndSettle();

      expect(history.log, ['push previews/demo/card.dart#card from findings']);
    });

    testWidgets('a step is pushed over its flow, and its arrow goes back', (
      tester,
    ) async {
      await open(tester, fragment: 'scenarios/$flow');

      await tester.tap(find.byKey(stepNodeKey('Cart')));
      await tester.pumpAndSettle();
      expect(find.byKey(stepPageKey), findsOneWidget);
      expect(history.log, ['push scenarios/$flow/Cart from scenarios/$flow']);

      await tester.tap(find.byKey(stepBackKey));
      await tester.pumpAndSettle();

      // The browser's own back, so the flow is in the history once.
      expect(history.log.last, 'back');
      expect(find.byKey(stepPageKey), findsNothing);
    });

    testWidgets('a step a link arrived on has nothing to go back through', (
      tester,
    ) async {
      await open(tester, fragment: 'scenarios/$flow/Cart');
      expect(find.byKey(stepPageKey), findsOneWidget);

      await tester.tap(find.byKey(stepBackKey));
      await tester.pumpAndSettle();

      expect(history.log, ['replace scenarios/$flow']);
    });

    testWidgets('the browser moving the page draws where it went', (
      tester,
    ) async {
      await open(tester, fragment: 'previews/demo/card.dart#card');

      history.arrive('scenarios/$flow/Cart');
      await tester.pumpAndSettle();
      expect(find.byKey(stepPageKey), findsOneWidget);
      expect(history.log, isEmpty);

      // Not an address on this page: the bar goes back to where the page is.
      history.arrive('files');
      await tester.pumpAndSettle();
      expect(history.log, ['replace scenarios/$flow/Cart']);
    });
  });

  group('a link to something this comparison does not have', () {
    testWidgets('a preview says so, beside the list', (tester) async {
      await open(tester, fragment: 'previews/demo/gone.dart#gone');

      expect(find.byKey(notInComparisonKey), findsOneWidget);
      expect(find.textContaining('demo/gone.dart#gone'), findsOneWidget);
      expect(find.byKey(previewRowKey('demo/card.dart#card')), findsOneWidget);
      expect(history.log, isEmpty);
    });

    testWidgets('a flow says so, beside the list', (tester) async {
      await open(tester, fragment: 'scenarios/test/gone_test.dart#Gone');

      expect(find.byKey(notInComparisonKey), findsOneWidget);
      expect(find.byKey(mergedTreeKey), findsNothing);
    });

    testWidgets('a step says so, with the flow one tap away', (tester) async {
      await open(tester, fragment: 'scenarios/$flow/Refund');

      expect(find.byKey(notInComparisonKey), findsOneWidget);
      await tester.tap(find.text('Back to the flow'));
      await tester.pumpAndSettle();

      expect(find.byKey(mergedTreeKey), findsOneWidget);
      expect(history.log, ['replace scenarios/$flow']);
    });

    testWidgets('a tab says so', (tester) async {
      await open(tester, fragment: 'scenarios/$flow', raw: previewsOnly);

      expect(find.byKey(notInComparisonKey), findsOneWidget);
    });
  });
}

class _History implements ViewerHistory {
  final log = <String>[];
  final _changes = StreamController<String>();
  final _pushedFrom = <String?>[null];

  void arrive(String fragment) => _changes.add(fragment);

  void dispose() => unawaited(_changes.close());

  @override
  void replace(String fragment) => log.add('replace $fragment');

  @override
  void push(String fragment, {required String from}) {
    log.add('push $fragment from $from');
    _pushedFrom.add(from);
  }

  @override
  String? get pushedFrom => _pushedFrom.last;

  /// What a browser does: the entry goes, and the page hears the one before.
  @override
  void back() {
    log.add('back');
    _pushedFrom.removeLast();
    _changes.add(_previous);
  }

  String get _previous {
    var pushes = log.where((line) => line.startsWith('push ')).toList();
    return pushes.last.split(' from ').last;
  }

  @override
  Stream<String> get changes => _changes.stream;
}
