import 'dart:io';

import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:flutterware_app/src/world/app_guest.dart';
import 'package:flutterware_app/src/world/guest_process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('guest_process_'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A host that connects to the control socket, as the real one does, then
  /// runs [body]. It writes its pid first, and `exec` keeps that pid.
  String host(String body) {
    var file = File(p.join(dir.path, 'host.sh'))
      ..writeAsStringSync('''
#!/bin/sh
echo \$\$ > "${p.join(dir.path, 'pid')}"
nc -U "\$3" < /dev/null > /dev/null &
$body
''');
    Process.runSync('chmod', ['+x', file.path]);
    return file.path;
  }

  Future<GuestProcess> start(String hostPath) => GuestProcess.start(
    person: 'ana',
    hostPath: hostPath,
    assetsDir: dir.path,
    icuData: dir.path,
    workingDirectory: dir.path,
    environment: const {},
  );

  int hostPid() => int.parse(File(p.join(dir.path, 'pid')).readAsStringSync());

  test('an app whose main failed before runApp fails at once, and is '
      'stopped', () async {
    var started = DateTime.now();
    await expectLater(
      start(
        host('''
echo "$guestStoppedMarker FailedToLoadClassException: Failed to load Objective-C class: some_plugin.SomeApiSetup"
exec sleep 600
'''),
      ),
      throwsA(
        isA<GuestStartFailure>().having(
          (e) => e.message,
          'message',
          allOf(
            startsWith(
              'The app stopped before it drew anything: '
              'FailedToLoadClassException: Failed to load Objective-C class',
            ),
            contains('Fake the plugin in the entry point, behind a knob.'),
          ),
        ),
      ),
    );
    expect(DateTime.now().difference(started), lessThan(_minute ~/ 4));
    // Left running, it would keep whoever opened the world alive after the
    // world had closed.
    expect(isProcessAlive(hostPid()), isFalse);
  });

  test('an app that exits before it draws says so', () async {
    await expectLater(
      start(host('exit 3')),
      throwsA(
        isA<GuestStartFailure>().having(
          (e) => e.message,
          'message',
          'The app exited with code 3 before it drew anything.',
        ),
      ),
    );
  });
}

const _minute = Duration(minutes: 1);
