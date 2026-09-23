import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutterware/src/render/capture.dart';
import 'package:flutterware/src/render/model.dart';

/// The capture census: run the recorder over a battery of everyday Material
/// surfaces and count what falls outside the vector lanes — unhandled canvas
/// ops, shaders the render-tree join cannot resolve, paragraphs whose text
/// cannot be recovered. This inventories the fidelity backlog against real
/// UI instead of a hand-built fixture.
void main() {
  testWidgets('census: everyday Material surfaces through the capture', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var screens = <String, Widget>{
      'buttons': Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(onPressed: () {}, child: const Text('Elevated')),
          FilledButton(onPressed: () {}, child: const Text('Filled')),
          OutlinedButton(onPressed: () {}, child: const Text('Outlined')),
          TextButton(onPressed: () {}, child: const Text('Text')),
          IconButton(onPressed: () {}, icon: const Icon(Icons.settings)),
        ],
      ),
      'text field': Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
                helperText: 'Focused, with cursor',
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: 'Prefilled value',
              decoration: const InputDecoration(labelText: 'Email'),
            ),
          ],
        ),
      ),
      'dialog': AlertDialog(
        title: const Text('Discard draft?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () {}, child: const Text('Cancel')),
          FilledButton(onPressed: () {}, child: const Text('Discard')),
        ],
      ),
      'selection controls': Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Switch(value: true, onChanged: (_) {}),
          Checkbox(value: true, onChanged: (_) {}),
          RadioGroup<int>(
            groupValue: 1,
            onChanged: (_) {},
            child: const Radio<int>(value: 1),
          ),
          Slider(value: 0.6, onChanged: (_) {}),
          const LinearProgressIndicator(value: 0.4),
          const SizedBox(height: 8),
          const CircularProgressIndicator(value: 0.7),
        ],
      ),
      'cards and lists': ListView(
        children: [
          Card(
            elevation: 3,
            child: ListTile(
              leading: const CircleAvatar(child: Text('A')),
              title: const Text('Card with elevation'),
              subtitle: const Text('and a ListTile inside'),
              trailing: const Icon(Icons.chevron_right),
            ),
          ),
          const Divider(),
          const ListTile(title: Text('Plain tile')),
          Wrap(
            spacing: 8,
            children: const [
              Chip(label: Text('chip')),
              Chip(avatar: Icon(Icons.check, size: 16), label: Text('done')),
            ],
          ),
        ],
      ),
      'navigation': Column(
        children: [
          AppBar(
            title: const Text('Title'),
            actions: [
              IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
            ],
          ),
          const Spacer(),
          NavigationBar(
            selectedIndex: 0,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
            ],
          ),
        ],
      ),
      'backdrop blur': Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.orange, Colors.purple]),
            ),
          ),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  color: Colors.white24,
                  child: const Text('frosted glass'),
                ),
              ),
            ),
          ),
        ],
      ),
      'shader mask': Center(
        child: ShaderMask(
          shaderCallback: (bounds) =>
              const LinearGradient(colors: [Colors.red, Colors.blue])
                  .createShader(bounds),
          child: const Text(
            'MASKED',
            style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold),
          ),
        ),
      ),
      'color filtered': Center(
        child: ColorFiltered(
          colorFilter: const ColorFilter.mode(Colors.red, BlendMode.srcIn),
          child: Container(width: 120, height: 60, color: Colors.white),
        ),
      ),
      'data table': DataTable(
        columns: const [
          DataColumn(label: Text('Name')),
          DataColumn(label: Text('Qty'), numeric: true),
        ],
        rows: const [
          DataRow(cells: [DataCell(Text('Apples')), DataCell(Text('12'))]),
          DataRow(cells: [DataCell(Text('Pears')), DataCell(Text('7'))]),
        ],
      ),
      'tab bar': DefaultTabController(
        length: 3,
        child: Column(
          children: const [
            TabBar(
              tabs: [
                Tab(text: 'One'),
                Tab(text: 'Two'),
                Tab(text: 'Three'),
              ],
              labelColor: Colors.black,
            ),
            Expanded(child: Center(child: Text('tab body'))),
          ],
        ),
      ),
    };

    var totalUnhandled = <String, int>{};
    var unknownTotal = 0;
    var effectsByScreen = <String, int>{};
    var report = StringBuffer();
    for (var entry in screens.entries) {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('census'),
              child: entry.value,
            ),
          ),
        ),
      );
      // A few real frames: focus, cursors and indicators reach a drawable
      // state; nothing here waits for animations to end (cursors never do).
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 80));

      var boundary = tester.renderObject(find.byKey(const ValueKey('census')));
      var recording = captureVector(boundary);

      var unresolvedShaders = 0;
      for (var op in recording.ops) {
        var paint = switch (op) {
          VgDrawRect(:var paint) => paint,
          VgDrawRRect(:var paint) => paint,
          VgDrawDRRect(:var paint) => paint,
          VgDrawCircle(:var paint) => paint,
          VgDrawOval(:var paint) => paint,
          VgDrawLine(:var paint) => paint,
          VgDrawPath(:var paint) => paint,
          _ => null,
        };
        if (paint != null && paint.hadUnresolvedShader) unresolvedShaders++;
      }
      var unknownParagraphs = recording.ops
          .whereType<VgDrawUnknownParagraph>()
          .length;
      unknownTotal += unknownParagraphs;
      var effects = recording.ops.whereType<VgBeginEffect>().length;
      effectsByScreen[entry.key] = effects;
      if (effects > 0) {
        // A layer effect must reach the warnings channel — the census's
        // reason to exist is that these used to vanish silently.
        var warnings = recording.collectWarnings(CaptureOptions());
        expect(
          warnings.where(
            (w) =>
                w.kind == RenderWarningKind.effectRasterized ||
                w.kind == RenderWarningKind.effectDropped,
          ),
          isNotEmpty,
        );
      }
      var textRuns = recording.ops.whereType<VgDrawText>().fold(
        0,
        (sum, op) => sum + op.runs.length,
      );
      for (var name in recording.unhandled) {
        totalUnhandled[name] = (totalUnhandled[name] ?? 0) + 1;
      }
      report.writeln(
        '${entry.key.padRight(20)} ops=${recording.ops.length.toString().padLeft(3)} '
        'textRuns=${textRuns.toString().padLeft(2)} '
        'unknownParagraphs=$unknownParagraphs '
        'effects=$effects '
        'unresolvedShaders=$unresolvedShaders '
        'unhandled=${recording.unhandled.isEmpty ? '-' : recording.unhandled.join(',')}',
      );
    }
    print(report);
    expect(
      totalUnhandled,
      isEmpty,
      reason: 'every canvas op on these screens must be captured',
    );
    expect(
      unknownTotal,
      0,
      reason:
          'all text on these screens joins back to the render tree '
          '(RenderParagraph and RenderEditable)',
    );
    for (var screen in ['backdrop blur', 'shader mask', 'color filtered']) {
      expect(
        effectsByScreen[screen],
        greaterThan(0),
        reason:
            '$screen must surface its layer effect instead of dropping it '
            'silently',
      );
    }
  });
}
