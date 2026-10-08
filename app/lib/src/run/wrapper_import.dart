import 'package:path/path.dart' as p;

/// Where the generated guest wrapper sits, relative to the package root.
///
/// Inside the package so its imports resolve, outside `lib/` so no analyzer or
/// tool of the project's ever meets it. Named here because two files have to
/// agree about it: the generator writing the wrapper and the scan rewriting the
/// entry point's own imports into it.
const wrapperDirectory = '.dart_tool/flutterware/run';

/// How the wrapper must spell an import of [target] — package-relative,
/// `/`-separated — or null when there is no spelling it can honestly write.
///
/// A `lib/` file is named by its `package:` URI, and only that. The wrapper
/// could reach it by path just as well, and must not: the app's own code names
/// it `package:$package/...`, and a library reached under two URIs is two
/// libraries, so a type crossing between them stops being the same type. Null
/// when [package] is unknown, because then there is no `package:` spelling to
/// write and the path is not allowed to stand in for it.
///
/// Anything else inside the package is named by a path, and only that. A
/// file outside `lib/` has no `package:` URI at all, so nothing else can name
/// it either and the double-identity hazard cannot arise. This is what lets an
/// entry point live in `demo/` — the constraint was always about `lib/` being
/// the half of a package that has two spellings, never about the wrapper
/// needing a `package:` URI specifically.
///
/// Anything outside the package is dropped. A path would spell it, but a
/// file in a sibling package is reached by `package:` URI from everywhere else
/// in the checkout, which is the hazard above with the packages swapped. An
/// absolute path is outside by the same test, which is why there is no separate
/// check for one.
///
/// On web the path is dropped too, and that is the compiler's rule rather
/// than ours — see [webWrapperImportRefusal].
String? wrapperImportOf(String target, {String? package, bool web = false}) {
  if (!p.posix.isWithin('.', target)) return null;
  if (p.posix.isWithin('lib', target)) {
    if (package == null) return null;
    return 'package:$package/${p.posix.relative(target, from: 'lib')}';
  }
  if (web) return null;
  return p.posix.relative(target, from: wrapperDirectory);
}

/// Why a web launch cannot use the path spelling, in the words the launcher
/// logs — null when [target] is fine on web.
///
/// A relative import out of the wrapper is a file-system fact that web does
/// not share. Compiling for the browser, flutter_tools finds no `package:`
/// URI for a target outside `lib/`, so it adds *the target's own directory* as
/// a virtual file-system root and names the target `org-dartlang-app:///` plus
/// its basename (`resident_web_runner.dart`, 3.47). The wrapper is the target
/// there, so the wrapper's directory becomes the root of the world and the
/// `../../../` that reaches the entry point on a disk climbs out of it — the
/// compile fails on generated source, reporting a file not found and an
/// undefined `main`.
///
/// Nothing the wrapper can be *written* as fixes this; only where it is written
/// would, and every directory the import could reach down from — the entry
/// point's own, the package root — is one the project commits. Rather than put
/// a generated file there, a web launch of such an entry point goes
/// uninstrumented, and the launcher logs why. `lib/` is unaffected: a `package:` URI means no
/// root is added and nothing has to climb.
String? webWrapperImportRefusal(String target) {
  if (!p.posix.isWithin('.', target)) return null;
  if (p.posix.isWithin('lib', target)) return null;
  return '$target is outside lib/. A web build compiles from the generated '
      "wrapper's directory, so the wrapper cannot import the entry point. "
      'Move it under lib/ to get knobs, inspect and drive on web; other '
      'platforms work with it where it is.';
}
