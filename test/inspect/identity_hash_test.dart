import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/node.dart';
import 'package:flutterware/src/utils/identity_hash.dart';

/// Nothing a node carries may be a value the VM assigned per allocation.
///
/// [InspectNode] is read in one process and compared in another, so an
/// identity hash in any field is a difference that is always there and never
/// means anything. It reached the tree by two doors — a widget's key, fused
/// into its description by the framework, and any property that renders an
/// object — and this is the sweep that says both are shut.
void main() {
  final hash = RegExp(r'#[0-9a-f]{5}(?![0-9a-f])');

  InspectTree read(WidgetTester tester) => GuestInspector(
    rootOf: () => tester.binding.rootElement,
    entryIdOf: () => null,
  ).read();

  testWidgets('no field of any node carries one', (tester) async {
    var scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              TextField(controller: TextEditingController(text: 'x')),
              AnimatedBuilder(
                animation: scroll,
                builder: (_, _) => const Text('hi'),
              ),
              Form(key: GlobalKey<FormState>(), child: const Text('f')),
              const Placeholder(key: ValueKey('tile')),
              // A key that identifies something else, which is how the hash
              // gets in behind a lower-case type name.
              Placeholder(key: GlobalObjectKey(1)),
            ],
          ),
        ),
      ),
    );

    var offenders = <String>[];
    for (var node in read(tester).nodes) {
      for (var entry in {...node.properties, ...node.textStyle}.entries) {
        if (hash.hasMatch(entry.value)) {
          offenders.add('${node.type}.${entry.key} = ${entry.value}');
        }
      }
      for (var value in [node.description, node.label, node.widgetKey]) {
        if (value != null && hash.hasMatch(value)) {
          offenders.add('${node.type} = $value');
        }
      }
    }

    expect(offenders, isEmpty);
  });

  testWidgets('the object survives, only its allocation goes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ListView(controller: ScrollController())),
    );
    var list = read(tester).nodes.firstWhere((it) => it.type == 'ListView');

    expect(list.properties['controller'], startsWith('ScrollController#('));
  });

  // The other half of the bargain: this must not edit the app's own words.
  testWidgets('a hash-shaped string in the UI is left alone', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('Order#12345')));
    var text = read(tester).nodes.firstWhere((it) => it.type == 'Text');

    expect(text.description, 'Text("Order#12345")');
    expect(text.properties['data'], '"Order#12345"');
  });

  test('a key whose value merely looks like a hash keeps it', () {
    expect(
      InspectNode.splitKey("Chip-[<'build#a1b2c'>]", 'Chip').key,
      "[<'build#a1b2c'>]",
    );
  });

  test('every shape of value-less key loses its hash', () {
    expect(
      {
        for (var pair in const [
          ('Form-[LabeledGlobalKey<FormState>#acc1d]', 'Form'),
          ('Card-[GlobalKey#04a2f]', 'Card'),
          ('Row-[#a1b2c]', 'Row'),
          ('Tile-[GlobalObjectKey Item#1234f]', 'Tile'),
          // The value's type, not the key's, so it may be lower-case or
          // carry a space inside its generics. `go_router` keys its
          // `_CustomNavigator` with the first of these.
          ('Nav-[GlobalObjectKey int#8cc0b]', 'Nav'),
          ('Nav-[GlobalObjectKey<int>#8cc0b]', 'Nav'),
          ('Cell-[ObjectKey Map<String, int>#04a2f]', 'Cell'),
        ])
          InspectNode.splitKey(pair.$1, pair.$2).key,
      },
      {
        '[LabeledGlobalKey<FormState>#]',
        '[GlobalKey#]',
        '[#]',
        '[GlobalObjectKey Item#]',
        '[GlobalObjectKey int#]',
        '[GlobalObjectKey<int>#]',
        '[ObjectKey Map<String, int>#]',
      },
    );
  });

  group('the two entries added for the events channel', () {
    // A private member's name is mangled with a token derived from its
    // library, and `Closure.toString()` prints the mangled form — so a widget
    // holding a private callback renders a number two *compilations* need not
    // agree on. Base and head are two compilations, which makes this a
    // permanent false positive rather than run-to-run noise.
    test("a private closure's mangling token goes, and nothing else does", () {
      expect(
        withoutIdentityHash(
          'Closure: (Object?, Object?) => Object? '
          "from Function '_imageBuilder@21460559':.",
        ),
        'Closure: (Object?, Object?) => Object? '
        "from Function '_imageBuilder@':.",
      );
    });

    // Measured: a closure prints no line:col to strip, and an anonymous one
    // prints no name at all — so there is nothing else in one that moves.
    test('a closure with nothing to mangle is left exactly as it is', () {
      for (var value in const [
        'Closure: (Object?) => Object?',
        "Closure: () => void from Function 'main': static.",
      ]) {
        expect(withoutIdentityHash(value), value);
      }
    });

    // `EditableTextState.autofillId` is its type and its hashCode, and it
    // reaches a comparison through `TextInput.setClient`'s arguments. On a
    // real 128-scenario suite it was 266 of the 402 run-to-run differences the
    // events channel had.
    test('an autofill id keeps its type and loses its hash', () {
      expect(withoutIdentityHash('EditableText-873965551'), 'EditableText-');
    });

    // The bar every entry here has to clear: a value that merely *looks*
    // like noise is somebody's data, and the only thing telling two of theirs
    // apart.
    test('a real value shaped like a hash is not touched', () {
      for (var value in const [
        "ValueKey('build#a1b2c')",
        "[<'order-12345'>]",
        'SKU-4491',
        'Contact-4491',
        'someone@12345',
      ]) {
        expect(withoutIdentityHash(value), value, reason: value);
      }
    });
  });
}
