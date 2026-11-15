import 'dart:io';

/// Whether this was compiled for a browser.
///
/// `dart:io` compiles there and throws when it is used, so the paths a
/// scenario replay takes in a web page ask this before they touch it.
const isWeb = bool.fromEnvironment('dart.library.js_interop');

/// The process environment, or nothing in a browser, which has none.
Map<String, String> get processEnvironment =>
    isWeb ? const {} : Platform.environment;

/// Writes one line of diagnostics: to stderr, or to the console in a browser.
void writeDiagnostic(String line) {
  if (isWeb) {
    print(line);
  } else {
    stderr.writeln(line);
  }
}
