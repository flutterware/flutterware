import 'dart:io';

import 'package:flutterware/src/working_copy.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What the working copy is a function of.
///
/// Both cases here are the same bug seen from its two ends, and the bug is not
/// hypothetical: a consumer whose project moved to a newer Flutter kept a copy
/// resolved against this repository's pinned one, and the way it surfaced was
/// a package in the middle of the graph failing to *parse* — a minute into a
/// GUI build, naming a package the project never asked for. Neither half fixes
/// it alone. Drop the lock and an existing copy still never re-resolves; stamp
/// the SDK and the fresh copy still inherits the versions in the lock.
void main() {
  late Directory temp;
  late String source;
  late String destination;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('working_copy');
    source = p.join(temp.path, 'source');
    destination = p.join(temp.path, 'destination');
    _write(p.join(source, 'pubspec.yaml'), 'name: flutterware\n');
    _write(p.join(source, 'lib', 'flutterware.dart'), '// library\n');
    _write(p.join(source, 'app', 'pubspec.yaml'), 'name: flutterware_app\n');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('the lock does not cross the boundary', () {
    test('is left behind rather than copied', () {
      _write(p.join(source, 'pubspec.lock'), 'packages:\n  jni: 1.0.0\n');

      copyPackageInto(source, destination, 'stamp');

      expect(File(p.join(destination, 'pubspec.yaml')).existsSync(), isTrue);
      expect(
        File(p.join(destination, 'lib', 'flutterware.dart')).existsSync(),
        isTrue,
      );
      expect(File(p.join(destination, 'pubspec.lock')).existsSync(), isFalse);
    });

    test('one an older flutterware left in the copy is removed', () {
      // The heal for a machine that already has a copy: not copying it is no
      // use while `pub get` can still find the one already sitting there.
      _write(p.join(destination, 'pubspec.lock'), 'packages:\n  jni: 1.0.0\n');

      copyPackageInto(source, destination, 'stamp');

      expect(File(p.join(destination, 'pubspec.lock')).existsSync(), isFalse);
    });

    test('a changed lock does not invalidate the copy', () {
      // The stamp and the copy walk one list, so a file the copy skips must not
      // be able to say the copy is stale.
      _write(p.join(source, 'pubspec.lock'), 'packages:\n  jni: 1.0.0\n');
      var before = workingCopyStamp(source, sdk: 'dart 3.13');

      _write(p.join(source, 'pubspec.lock'), 'packages:\n  jni: 1.0.3\n');

      expect(workingCopyStamp(source, sdk: 'dart 3.13'), before);
    });
  });

  group('the SDK is an input', () {
    test('the same sources under a different SDK are a different copy', () {
      expect(
        workingCopyStamp(source, sdk: 'dart 3.14'),
        isNot(workingCopyStamp(source, sdk: 'dart 3.13')),
      );
    });

    test('the same sources under the same SDK are the same copy', () {
      expect(
        workingCopyStamp(source, sdk: 'dart 3.13'),
        workingCopyStamp(source, sdk: 'dart 3.13'),
      );
    });

    test('changed sources under one SDK are a different copy', () {
      var before = workingCopyStamp(source, sdk: 'dart 3.13');

      _write(p.join(source, 'lib', 'flutterware.dart'), '// library, longer\n');

      expect(workingCopyStamp(source, sdk: 'dart 3.13'), isNot(before));
    });
  });

  group('the workspace is the one the copy carries', () {
    test('members the archive leaves out are dropped from the list', () {
      // This repository's own root pubspec, so the shape under test is the one
      // that ships.
      var real = File(p.join(Directory.current.path, 'pubspec.yaml'))
          .readAsStringSync();
      expect(real, contains('\n  - fixtures/probe_app\n'));
      _write(p.join(source, 'pubspec.yaml'), real);

      copyPackageInto(source, destination, 'stamp');

      var copied = File(p.join(destination, 'pubspec.yaml')).readAsStringSync();
      expect(copied, contains('workspace:\n  - app\n'));
      for (var absent in ['fixtures/probe_app', 'examples/brewline']) {
        expect(copied, isNot(contains('- $absent')));
      }
      // Only the list moves: what follows it is still there.
      expect(copied, contains('\nplatforms:'));
    });

    test('a pubspec with no workspace is copied as it is', () {
      copyPackageInto(source, destination, 'stamp');

      expect(
        File(p.join(destination, 'pubspec.yaml')).readAsStringSync(),
        'name: flutterware\n',
      );
    });
  });

  test('the stamp records what the copy was made from', () {
    var stamp = workingCopyStamp(source, sdk: 'dart 3.13');

    copyPackageInto(source, destination, stamp);

    expect(workingCopyStampFile(destination).readAsStringSync(), stamp);
  });

  /// What a finished copy is allowed to keep.
  ///
  /// The shape here is macOS's, because it is the one where the product is a
  /// *directory* four levels below the platform build directory and the
  /// executable is inside it — get the trim wrong on Windows and it deletes a
  /// DLL, get it wrong here and it deletes the bundle.
  group('trimming a finished copy', () {
    late String appPath;
    late Directory product;

    String at(String relative) => p.join(appPath, relative);

    setUp(() {
      appPath = p.join(destination, 'app');
      product = Directory(
        at(
          p.join(
            'build',
            'macos',
            'Build',
            'Products',
            'Release',
            'Flutterware.app',
          ),
        ),
      );
      _write(
        p.join(product.path, 'Contents', 'MacOS', 'Flutterware'),
        'mach-o',
      );
      _write(
        p.join(product.path, 'Contents', 'Frameworks', 'App.framework', 'App'),
        'framework',
      );
      // What Xcode scatters around it, at every level of the chain.
      _write(
        at(p.join('build', 'macos', 'ModuleCache.noindex', 'x.pcm')),
        'cache',
      );
      _write(
        at(p.join('build', 'macos', 'Build', 'Intermediates.noindex', 'x.o')),
        'object',
      );
      _write(
        at(
          p.join(
            'build',
            'macos',
            'Build',
            'Products',
            'Debug',
            'Flutterware.app',
            'x',
          ),
        ),
        'debug',
      );
      _write(
        at(
          p.join(
            'build',
            'macos',
            'Build',
            'Products',
            'Release',
            'FlutterMacOS.framework.dSYM',
            'x',
          ),
        ),
        'symbols',
      );
      // What must survive: everything under `build/` that is not the platform
      // directory, and the resolution.
      _write(at(p.join('build', 'cli', 'bundle', 'bin', 'fw')), 'binary');
      _write(at(p.join('build', 'gui-build.log')), 'log');
      _write(at(p.join('build', 'catalog', 'daemon', 'daemon.dill')), 'kernel');
      _write(at(p.join('.dart_tool', 'package_config.json')), '{}');
      _write(
        at(p.join('.dart_tool', 'flutter_build', 'x', 'app.dill')),
        'kernel',
      );
      _write(
        p.join(destination, '.dart_tool', 'hooks_runner', 'x', 'out'),
        'asset',
      );
    });

    test('keeps the product whole and deletes what is beside it', () {
      trimWorkingCopy(appPath, guiProduct: product);

      expect(
        File(p.join(product.path, 'Contents', 'MacOS', 'Flutterware'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(
            product.path,
            'Contents',
            'Frameworks',
            'App.framework',
            'App',
          ),
        ).existsSync(),
        isTrue,
        reason: 'a release bundle carries its own frameworks',
      );
      for (var gone in [
        at(p.join('build', 'macos', 'ModuleCache.noindex')),
        at(p.join('build', 'macos', 'Build', 'Intermediates.noindex')),
        at(p.join('build', 'macos', 'Build', 'Products', 'Debug')),
        at(
          p.join(
            'build',
            'macos',
            'Build',
            'Products',
            'Release',
            'FlutterMacOS.framework.dSYM',
          ),
        ),
      ]) {
        expect(Directory(gone).existsSync(), isFalse, reason: gone);
      }
    });

    test('never prunes build/ itself', () {
      trimWorkingCopy(appPath, guiProduct: product);

      expect(
        File(at(p.join('build', 'cli', 'bundle', 'bin', 'fw'))).existsSync(),
        isTrue,
      );
      expect(File(at(p.join('build', 'gui-build.log'))).existsSync(), isTrue);
      expect(
        File(at(p.join('build', 'catalog', 'daemon', 'daemon.dill')))
            .existsSync(),
        isTrue,
        reason: 'the warm kernel is a real cache and a separate decision',
      );
    });

    test('drops the build caches and keeps the resolution', () {
      trimWorkingCopy(appPath, guiProduct: product);

      expect(
        Directory(at(p.join('.dart_tool', 'flutter_build'))).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(destination, '.dart_tool', 'hooks_runner'))
            .existsSync(),
        isFalse,
      );
      expect(
        File(at(p.join('.dart_tool', 'package_config.json'))).existsSync(),
        isTrue,
        reason: 'losing this turns a warm run into a pub get',
      );
    });

    test('a product outside this copy deletes nothing beside it', () {
      var elsewhere = Directory(
        p.join(temp.path, 'elsewhere', 'Flutterware.app'),
      )..createSync(recursive: true);
      _write(p.join(temp.path, 'elsewhere', 'sibling'), 'not ours');

      expect(trimWorkingCopy(appPath, guiProduct: elsewhere), 0);

      expect(
        File(p.join(temp.path, 'elsewhere', 'sibling')).existsSync(),
        isTrue,
      );
      expect(
        Directory(at(p.join('build', 'macos', 'ModuleCache.noindex')))
            .existsSync(),
        isTrue,
        reason: 'the walk never reached build/, so it acted on nothing',
      );
      expect(
        Directory(at(p.join('.dart_tool', 'flutter_build'))).existsSync(),
        isTrue,
        reason: 'a walk that answered nothing must not fall through to these',
      );
    });

    test('a build that produced no product is left to be resumed', () {
      // The wreckage of a failed build, and the thing the next attempt reads.
      // Reclaiming it would turn every retry into a cold build.
      product.deleteSync(recursive: true);

      expect(trimWorkingCopy(appPath, guiProduct: product), 0);

      expect(
        Directory(
          at(p.join('build', 'macos', 'Build', 'Intermediates.noindex')),
        ).existsSync(),
        isTrue,
      );
      expect(
        Directory(at(p.join('.dart_tool', 'flutter_build'))).existsSync(),
        isTrue,
        reason: 'the caches are half of what a resumed build reads',
      );
      expect(
        Directory(p.join(destination, '.dart_tool', 'hooks_runner'))
            .existsSync(),
        isTrue,
      );
    });

    test('is safe to run twice', () {
      var first = trimWorkingCopy(appPath, guiProduct: product);
      var second = trimWorkingCopy(appPath, guiProduct: product);

      expect(first, greaterThan(0));
      expect(second, 0);
      expect(
        File(p.join(product.path, 'Contents', 'MacOS', 'Flutterware'))
            .existsSync(),
        isTrue,
      );
    });
  });
}

void _write(String path, String contents) => File(path)
  ..createSync(recursive: true)
  ..writeAsStringSync(contents);
