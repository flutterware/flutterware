import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware_app/src/utils/enum_lookup.dart';
import 'package:flutterware_app/src/utils/parameter_knobs.dart';
import 'package:path/path.dart' as p;

/// The one translation a catalog demo and a run entry point share.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fw-knobs-'));
  tearDown(() => root.deleteSync(recursive: true));

  /// Writes [source] as `main.dart` and reads the knobs off its first function.
  List<ParameterKnob> knobsOf(
    String source, {
    Map<String, String> alongside = const {},
    void Function(String, String)? onSkipped,
  }) {
    for (var file in {...alongside, 'main.dart': source}.entries) {
      File(p.join(root.path, file.key))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(file.value);
    }
    var path = p.join(root.path, 'main.dart');
    var unit = parseString(content: source, throwIfDiagnostics: false).unit;
    var function = unit.declarations.whereType<FunctionDeclaration>().first;
    return knobsFromParameters(
      function.functionExpression.parameters,
      file: path,
      lookup: EnumLookup(),
      onSkipped: onSkipped,
    );
  }

  /// The same, off the first constructor rather than the first function —
  /// which is where `super.key` can appear at all.
  List<ParameterKnob> constructorKnobsOf(
    String source, {
    void Function(String, String)? onSkipped,
  }) {
    var path = p.join(root.path, 'main.dart');
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(source);
    var unit = parseString(content: source, throwIfDiagnostics: false).unit;
    var constructor = unit.declarations
        .whereType<ClassDeclaration>()
        .expand((c) => c.body.members)
        .whereType<ConstructorDeclaration>()
        .first;
    return knobsFromParameters(
      constructor.parameters,
      file: path,
      lookup: EnumLookup(),
      onSkipped: onSkipped,
    );
  }

  test('draws each built-in type as its own control', () {
    var knobs = knobsOf('''
Widget demo({
  String label = 'Hello',
  bool dense = false,
  int count = 2,
  double ratio = 1.5,
  num any = 3,
}) => Placeholder();
''');

    expect(
      {for (var knob in knobs) knob.name: knob.knob.kind},
      {
        'label': KnobKind.string,
        'dense': KnobKind.boolean,
        'count': KnobKind.integer,
        'ratio': KnobKind.number,
        'any': KnobKind.number,
      },
    );
    expect(
      {for (var knob in knobs) knob.name: knob.knob.defaultValue},
      {'label': 'Hello', 'dense': false, 'count': 2, 'ratio': 1.5, 'any': 3},
    );
    // Nothing has moved it yet, so the value *is* the default.
    expect(knobs.first.knob.value, 'Hello');
  });

  test('an enum becomes a picker of its constants', () {
    var knobs = knobsOf('''
enum Backend { dev, staging, prod }
Widget demo({Backend backend = Backend.staging}) => Placeholder();
''');

    expect(knobs.single.knob.kind, KnobKind.picker);
    expect(knobs.single.knob.options, ['dev', 'staging', 'prod']);
    // Stored as the constant's name — the prefix is exactly what a picker does
    // not want.
    expect(knobs.single.knob.defaultValue, 'staging');
  });

  test('a picker carries the type as written, for the generator alone', () {
    // The wrapper writes `m.Backend.staging`, and it only compiles spelled the
    // way the entry point spells it. Nothing else ever sees this.
    var knobs = knobsOf(
      '''
import 'models.dart' as m;
Widget demo({m.Backend backend = m.Backend.dev}) => Placeholder();
''',
      alongside: {'models.dart': 'enum Backend { dev, prod }'},
    );

    expect(knobs.single.enumType, 'm.Backend');
    expect(knobs.single.knob.options, ['dev', 'prod']);
  });

  test('a built-in knob carries no type — there is nothing to generate', () {
    expect(
      knobsOf("Widget demo({String label = 'x'}) => Placeholder();")
          .single
          .enumType,
      isNull,
    );
  });

  test('a prefixed enum through a barrel still picks', () {
    var knobs = knobsOf(
      '''
import 'models.dart' as m;
Widget demo({m.Backend backend = m.Backend.prod}) => Placeholder();
''',
      alongside: {
        'src/backend.dart': 'enum Backend { dev, prod }',
        'models.dart': "export 'src/backend.dart';",
      },
    );

    expect(knobs.single.knob.options, ['dev', 'prod']);
    expect(knobs.single.knob.defaultValue, 'prod');
  });

  test('a type nothing can draw is skipped, with a reason', () {
    var skipped = <String, String>{};
    var knobs = knobsOf(
      'Widget demo({Color tint = Colors.red}) => Placeholder();',
      onSkipped: (name, reason) => skipped[name] = reason,
    );

    // KnobKind's own rule: left out rather than guessed at, and said out loud
    // rather than left out quietly.
    expect(knobs, isEmpty);
    expect(skipped, contains('tint'));
    // Both halves: a parse cannot tell a `Color` from an enum it failed to
    // find, and only one of the two answers is useful to whoever reads it.
    expect(skipped['tint'], contains('is `Color`'));
    expect(
      skipped['tint'],
      contains('String, bool, int, double, num or an enum'),
    );
    expect(skipped['tint'], contains('If it is an enum'));
  });

  test('a type that cannot be an enum is not reported as a missing one', () {
    // Measured 2026-08-13 (E3): every non-enum type was told "no enum Duration
    // in main.dart — declare it there", advice about a file that was never
    // going to exist.
    var skipped = <String, String>{};
    knobsOf(
      'Widget demo({List<String> tags = const [], dynamic any}) '
      '=> Placeholder();',
      onSkipped: (name, reason) => skipped[name] = reason,
    );

    expect(skipped['tags'], contains('is `List<String>`'));
    expect(skipped['tags'], isNot(contains('If it is an enum')));
    expect(skipped['any'], contains('is `dynamic`'));
    expect(skipped['any'], isNot(contains('If it is an enum')));
  });

  test('nullable is not a kind of its own', () {
    // Measured with the rest: `String?` is still a text field that starts
    // empty, and `Backend?` is still a picker.
    var knobs = knobsOf('''
enum Backend { dev, prod }
Widget demo({String? host, Backend? backend}) => Placeholder();
''');

    expect(knobs.map((k) => k.knob.kind), [KnobKind.string, KnobKind.picker]);
    expect(knobs.last.knob.options, ['dev', 'prod']);
  });

  test('a required parameter is not a knob', () {
    var knobs = knobsOf(
      'Widget demo(String positional, {String label = "x"}) => Placeholder();',
    );

    expect(knobs.map((k) => k.name), ['label']);
  });

  test('an optional parameter with no default is a knob with no value', () {
    var knobs = knobsOf('Widget demo({String? label}) => Placeholder();');

    expect(knobs.single.knob.kind, KnobKind.string);
    expect(knobs.single.knob.defaultValue, isNull);
  });

  test('a default this cannot carry reads as no default, not as source', () {
    // `const Duration(seconds: 5)` is a fine default and a poor value to put in
    // a text field. Better empty than showing somebody their own source.
    var knobs = knobsOf(
      'Widget demo({String label = someConstant}) => Placeholder();',
    );

    expect(knobs.single.knob.kind, KnobKind.string);
    expect(knobs.single.knob.defaultValue, isNull);
  });

  test('a positional optional parameter is a knob too', () {
    var knobs = knobsOf('Widget demo([int count = 3]) => Placeholder();');

    expect(knobs.single.name, 'count');
    expect(knobs.single.knob.defaultValue, 3);
  });

  test('no parameters at all is no knobs, not a failure', () {
    expect(knobsOf('Widget demo() => Placeholder();'), isEmpty);
  });

  /// `key` is on every demo widget written as a class, which is the form the
  /// README recommends for moving an existing catalog. Reported, it was one
  /// warning per entry — a real one has nowhere to be seen in that.
  group('`key` is not a knob, and does not say so', () {
    test('a `super.key` is skipped in silence', () {
      var skipped = <String, String>{};
      var knobs = constructorKnobsOf(
        'class Demo extends StatelessWidget {\n'
        "  const Demo({super.key, String label = 'x'});\n"
        '}',
        onSkipped: (name, reason) => skipped[name] = reason,
      );

      expect(knobs.map((k) => k.name), ['label']);
      expect(skipped, isEmpty);
    });

    test('an explicit `Key? key` too', () {
      // The other spelling, and it took a different branch to the same useless
      // line: `super.key` writes no type, `Key?` writes one no control fits.
      var skipped = <String, String>{};
      var knobs = constructorKnobsOf(
        'class Demo extends StatelessWidget {\n'
        '  const Demo({Key? key});\n'
        '}',
        onSkipped: (name, reason) => skipped[name] = reason,
      );

      expect(knobs, isEmpty);
      expect(skipped, isEmpty);
    });

    test("a `key` of somebody else's type is still reported", () {
      // The rule is the name *and* the type, because only the pair is Flutter's
      // own. A parameter called `key` that is something else is an undrawable
      // knob like any other, and staying quiet about it is what this whole
      // group is complaining about.
      var skipped = <String, String>{};
      var knobs = knobsOf(
        'Widget demo({Color key = Colors.red}) => Placeholder();',
        onSkipped: (name, reason) => skipped[name] = reason,
      );

      expect(knobs, isEmpty);
      expect(skipped['key'], contains('is `Color`'));
    });
  });

  /// A default that is a reference, which is the ordinary shape. Reported
  /// by a consumer: the values knobs replace are usually already
  /// `String.fromEnvironment` constants, because that is what a `--dart-define`
  /// build reads — so the default is a `const` reference rather than a literal,
  /// and the form showed a blank for a parameter that plainly had one.
  ///
  /// The spelling is carried, never evaluated. Following it would mean
  /// answering an open question (`a + b`, a const constructor, a getter) in
  /// something that is not a compiler, and resolution — which answers all of
  /// it — costs 5.5s on an entry point that imports Flutter, on a scan that
  /// runs on every knob change.
  group('a default it cannot evaluate', () {
    test('carries how it is written, and no value', () {
      var knobs = knobsOf(
        'void main({String serverHost = ServerUrls.localHost, '
        'int serverPort = ServerUrls.localPort}) {}',
      );

      expect(knobs.map((k) => k.name), ['serverHost', 'serverPort']);
      expect(knobs[0].defaultSource, 'ServerUrls.localHost');
      expect(knobs[1].defaultSource, 'ServerUrls.localPort');
      expect(knobs.map((k) => k.knob.defaultValue), [
        null,
        null,
      ], reason: 'the value field stays honest about not knowing');
      expect(knobs.map((k) => k.knob.kind), [
        KnobKind.string,
        KnobKind.integer,
      ], reason: 'the type is still read off the signature');
    });

    /// The pair is what carries the meaning, so they may never both be set:
    /// a value means there is nothing to spell out, and source text where a
    /// value belongs is the thing this is careful not to do.
    test('a literal default carries a value and no source', () {
      var knobs = knobsOf(
        "void main({String host = 'localhost', int port = 8080, "
        'bool verbose = false, double scale = 1.5}) {}',
      );

      expect(knobs.map((k) => k.knob.defaultValue), [
        'localhost',
        8080,
        false,
        1.5,
      ]);
      expect(knobs.map((k) => k.defaultSource), everyElement(isNull));
    });

    test('no default at all carries neither', () {
      var knobs = knobsOf('void main({String? host, int? port}) {}');

      expect(knobs.map((k) => k.knob.defaultValue), everyElement(isNull));
      expect(knobs.map((k) => k.defaultSource), everyElement(isNull));
    });

    /// An expression is as unevaluatable as a reference, and just as
    /// recognisable to whoever wrote it.
    test('an expression is carried the same way', () {
      var knobs = knobsOf('void main({int seconds = 60 * 5}) {}');

      expect(knobs.single.defaultSource, '60 * 5');
      expect(knobs.single.knob.defaultValue, isNull);
    });

    /// A picker reads its default off the end of whatever was written, so a
    /// constant holding an enum value already answers — and must not also be
    /// reported as unevaluated.
    test('a picker that resolved its constant carries no source', () {
      var knobs = knobsOf(
        '''
import 'backend.dart';
void main({Backend backend = Backend.staging}) {}
''',
        alongside: {'backend.dart': 'enum Backend { dev, staging, prod }'},
      );

      expect(knobs.single.knob.defaultValue, 'staging');
      expect(knobs.single.defaultSource, isNull);
    });
  });
}
