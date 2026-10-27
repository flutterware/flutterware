import 'dart:io';

import 'package:flutterware_app/src/utils/terminal_environment.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The environment every process flutterware starts is given.
///
/// The shell is a fake that behaves like a user's: it prints a greeting, its
/// profile exports a variable and prepends to PATH, and then it runs what it
/// was asked to. Everything else is real — the spawn, the markers, `env -0`.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('fw_terminal_env_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String shell(String profile) {
    var file = File(p.join(dir.path, 'fake_shell'))
      ..writeAsStringSync('#!/bin/sh\n$profile\n$_runTheCommand');
    Process.runSync('chmod', ['+x', file.path]);
    return file.path;
  }

  var profile = r'''
echo "Welcome back"
export FROM_PROFILE=yes
export PATH="/profile/bin:$PATH"
''';

  Map<String, String> ours(String fakeShell, {String path = '/ours/bin'}) => {
    'SHELL': fakeShell,
    'HOME': dir.path,
    'PATH': path,
    'ONLY_OURS': 'leaked',
  };

  group('read from a shell', () {
    test('has what the profile set, and nothing that is only ours', () async {
      var read = await readTerminalEnvironment(ours(shell(profile)));

      expect(read['FROM_PROFILE'], 'yes');
      expect(read['HOME'], dir.path);
      expect(read, isNot(contains('ONLY_OURS')));
      // The profile's addition, in front of launchd's PATH. Not ours.
      expect(read['PATH'], startsWith('/profile/bin:'));
      expect(read['PATH'], contains(':/usr/bin:'));
      expect(read['PATH'], isNot(contains('/ours/bin')));
    });

    test('is the same however this process was started', () async {
      // The point of the whole thing: the build hooks' cache is keyed on
      // PATH, so a studio from the Dock and an MCP server with a version
      // manager's SDK in front must hand out the same one.
      var fake = shell(profile);
      var fromDock = await readTerminalEnvironment(
        ours(fake, path: '/usr/bin:/bin:/usr/sbin:/sbin'),
      );
      var fromAgent = await readTerminalEnvironment(
        ours(fake, path: '/sdk/bin:/profile/bin:/usr/local/bin:/usr/bin:/bin'),
      );

      expect(fromAgent['PATH'], fromDock['PATH']);
    });

    test('leaves out the variables about the shell that answered', () async {
      var read = await readTerminalEnvironment(ours(shell(profile)));

      expect(read.keys, isNot(contains('PWD')));
      expect(read.keys, isNot(contains('SHLVL')));
      expect(read.keys, isNot(contains('_')));
    });

    test('does not wait for a job the profile left running', () async {
      // A prompt's git daemon holds stdout open long after the shell exits.
      var started = DateTime.now();
      var read = await readTerminalEnvironment(
        ours(shell('sleep 30 &\n$profile')),
        timeout: const Duration(seconds: 20),
      );

      expect(read['FROM_PROFILE'], 'yes');
      expect(
        DateTime.now().difference(started),
        lessThan(Duration(seconds: 5)),
      );
    });
  });

  group('keeps our own environment', () {
    test('when the shell hangs', () async {
      var own = ours(shell('sleep 30'));
      var read = await readTerminalEnvironment(
        own,
        timeout: const Duration(seconds: 1),
      );

      expect(read, own);
    });

    test('when the shell cannot be started', () async {
      var own = ours(p.join(dir.path, 'no_such_shell'));

      expect(await readTerminalEnvironment(own), own);
    });

    test('on CI, where there is no terminal to copy', () async {
      var own = {...ours(shell(profile)), 'CI': 'true'};

      expect(await readTerminalEnvironment(own), own);
    });

    test('on Windows', () async {
      var own = ours(shell(profile));

      expect(await readTerminalEnvironment(own, windows: true), own);
    });
  });

  group('the shell output', () {
    const start = '\n__flutterware_environment__\n';
    const end = '\n__flutterware_environment_end__\n';

    test('is read between the markers, a value at a time', () {
      var read = parseTerminalEnvironment(
        'motd\n${start}PATH=/a:/b\x00MULTI=one\ntwo\x00EQ=a=b\x00$end',
      );

      expect(read, {'PATH': '/a:/b', 'MULTI': 'one\ntwo', 'EQ': 'a=b'});
    });

    test('without both markers is no answer', () {
      expect(parseTerminalEnvironment('PATH=/a\x00'), isNull);
      expect(parseTerminalEnvironment('${start}PATH=/a\x00'), isNull);
    });

    test('without a PATH is no answer', () {
      expect(parseTerminalEnvironment('${start}HOME=/h\x00$end'), isNull);
    });
  });

  group('an executable on a PATH', () {
    test('is the first one that can be run', () {
      var first = Directory(p.join(dir.path, 'first'))..createSync();
      var second = Directory(p.join(dir.path, 'second'))..createSync();
      File(p.join(first.path, 'tool')).writeAsStringSync('');
      var runnable = File(p.join(second.path, 'tool'))..writeAsStringSync('');
      Process.runSync('chmod', ['+x', runnable.path]);
      Directory(p.join(first.path, 'dir_tool')).createSync();

      var path = '${first.path}:${second.path}';
      expect(executableOnPath('tool', path), runnable.path);
      expect(executableOnPath('dir_tool', path), isNull);
      expect(executableOnPath('missing', path), isNull);
    });
  });
}

/// What a shell does with `-l -i -c <command>`, minus the profile: skip the
/// flags, run the command.
const _runTheCommand = r'''
while [ "$1" != "-c" ]; do shift; done
eval "$2"
''';
