import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

// The leaf, not the `source_code.dart` barrel, for the reason the generators
// give: this is on the compiler daemon's import closure.
import '../utils/source_code/escape_dart_string.dart';

/// The function a package's declared setup file has to define.
const previewSetupFunction = 'previewSetup';

/// The file `PreviewsPackage.setup` names, checked before anything imports it.
///
/// Every program a preview renders in — the guest, the `flutter_tester`
/// harness, the web page — imports the file and calls [previewSetupFunction]
/// before the first entry builds. A declaration those programs could not
/// honour is refused here, in words, rather than left to the compiler: a
/// missing import or a missing function fails the compile inside generated
/// code, which blames no entry and reads as flutterware's bug.
///
/// Pure Dart, like the generators that call it: the compiler daemon imports
/// this and must never reach Flutter.
class PreviewSetup {
  const PreviewSetup(this.path);

  /// Package-relative and `/`-separated, as `PreviewsPackage.setup` wrote it.
  final String path;

  /// Why [path] under [packageRoot] cannot be the setup, or null when it can.
  String? problemIn(String packageRoot) {
    var file = File(p.join(packageRoot, path));
    if (p.isAbsolute(path) || !p.isWithin(packageRoot, file.path)) {
      return 'The preview setup `$path` is not inside the package. '
          '`PreviewsPackage.setup` takes a path relative to the package, '
          "such as 'lib/preview_setup.dart'.";
    }
    if (!file.existsSync()) {
      return 'The preview setup `$path` does not exist. Write it, with a '
          'top-level `Future<void> $previewSetupFunction()`, or remove '
          '`setup:` from the package in `tool/flutterware.dart`.';
    }
    var unit = parseString(
      content: file.readAsStringSync(),
      throwIfDiagnostics: false,
    ).unit;
    var declared = [
      for (var declaration in unit.declarations)
        if (declaration is FunctionDeclaration &&
            declaration.name.lexeme == previewSetupFunction)
          declaration,
    ];
    if (declared.isEmpty) {
      return 'The preview setup `$path` declares no top-level '
          '`$previewSetupFunction()`, which is what every preview program '
          'calls before the first entry builds.';
    }
    bool callable(FunctionDeclaration function) =>
        !function.isGetter &&
        !function.isSetter &&
        !(function.functionExpression.parameters?.parameters.any(
              (parameter) => parameter.isRequired,
            ) ??
            false);
    if (!declared.any(callable)) {
      return '`$previewSetupFunction` in `$path` has to be a function called '
          'with no arguments: `Future<void> $previewSetupFunction()`.';
    }
    return null;
  }

  /// [problemIn] as a refusal, for the generators: each writes a program that
  /// imports the file, and none of them may write one that cannot compile.
  void check(String packageRoot) {
    if (problemIn(packageRoot) case var problem?) {
      throw PreviewSetupProblem(problem);
    }
  }

  /// The statements a generated `main` runs the setup with, the file imported
  /// as `fw_setup` — shared by the guest's entrypoint and the web page, which
  /// have to agree about what a setup that throws looks like.
  ///
  /// Reported, and **shown in place of the previews**, never skipped: every
  /// entry would otherwise render without what the setup installs, and
  /// plausibly — a fallback font looks like a font.
  String get statements {
    var running = escapeDartString(
      'running $previewSetupFunction() from $path',
    );
    var threw = escapeDartString(
      '$previewSetupFunction() in $path threw, so no preview is rendered '
      'without it:\n',
    );
    return '''
  // The package's declared setup — `PreviewsPackage.setup` — once, before
  // anything is built.
  try {
    await fw_setup.$previewSetupFunction();
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'preview setup',
        context: ErrorDescription($running),
      ),
    );
    runApp(ErrorWidget.withDetails(message: $threw '\$error'));
    return;
  }
''';
  }
}

/// A declared setup that cannot be run, said in words — the whole of what
/// reaches the caller, so it prints as its message and nothing else.
class PreviewSetupProblem implements Exception {
  const PreviewSetupProblem(this.message);

  final String message;

  @override
  String toString() => message;
}
