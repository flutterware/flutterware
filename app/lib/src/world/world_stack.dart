import 'package:flutterware/plugins.dart' show ScriptSource, ValueSource;
// ignore: implementation_imports
import 'package:flutterware/src/world/world.dart' show WorldService;
import 'package:path/path.dart' as p;

import '../plugins/native/dev_stack_core.dart';
import '../plugins/native/dev_stack_results.dart';
import '../run/define_scripts.dart';
import '../session/job.dart' show ActionRefusal;
import 'mail_catcher.dart';
import 'open_world.dart' show WorldRefusal;
import 'world_files.dart';

/// Why [file] cannot open in a project that declares no dev stack.
String noDevStackFor(WorldFile file) =>
    '${file.name} needs ${file.needs.join(', ')}, but this project declares '
    'no dev stack. Declare them with DevStack in tool/flutterware.dart, or '
    'take `needs:` off the world.';

/// The dev stack, as a world asks it for the services it needs.
///
/// The session hands the worlds plugin one when the project declares a dev
/// stack, because the plugins cannot see each other.
abstract interface class WorldStack {
  /// What the dev stack calls [id], or [id] when it declares no such service.
  String nameOf(String id);

  /// Brings up [ids] and what they need, in order, saying in [say] what it
  /// starts and how each one ended, and in the dev stack's history that it
  /// was [world] that needed them. Answers every service it went through,
  /// all of them up.
  ///
  /// Throws a [WorldRefusal] when one did not come up, saying which and why,
  /// or when an id names no service.
  Future<List<WorldService>> bringUp(
    List<String> ids, {
    required void Function(String line) say,
    required String world,
  });

  /// The mail catchers [services] run, each with where it answers. One whose
  /// port cannot be worked out is left out, and [say] says why.
  Future<List<WorldMailCatcher>> mailCatchers(
    List<WorldService> services, {
    required void Function(String line) say,
  });
}

/// [WorldStack] over the session's [DevStackCore].
class DevStackForWorlds implements WorldStack {
  DevStackForWorlds(this.stack);

  final DevStackCore stack;

  @override
  String nameOf(String id) =>
      [
        for (var service in stack.services)
          if (service.id == id) service.label,
      ].firstOrNull ??
      id;

  @override
  Future<List<WorldService>> bringUp(
    List<String> ids, {
    required void Function(String line) say,
    required String world,
  }) async {
    StackEnsureResult result;
    try {
      result = await stack.ensure(
        ids: ids,
        onStarting: (name) => say('Starting $name'),
        onEnsured: (service) => _sayEnded(service, say),
        purpose: 'to open $world',
      );
    } on ActionRefusal catch (refusal) {
      throw WorldRefusal(
        '${refusal.message} The world names what it needs in `needs:` on its '
        'WorldScript in tool/flutterware.dart.',
      );
    }
    var down = result.services
        .where((service) => !service.outcome.isUp)
        .firstOrNull;
    if (down != null) {
      // The first one down is the cause: what comes after it was skipped
      // because of it.
      throw WorldRefusal(
        '${down.name} did not come up, so the world did not start: '
        '${down.failure ?? 'it is not up.'}'
        '${down.output.trim().isEmpty ? '' : ' The Dev stack panel has its log.'}',
      );
    }
    return [
      for (var service in result.services)
        WorldService(
          service.id,
          name: service.name,
          port: service.port,
          url: switch (service.url) {
            var url? => Uri.parse(url),
            null => null,
          },
        ),
    ];
  }

  @override
  Future<List<WorldMailCatcher>> mailCatchers(
    List<WorldService> services, {
    required void Function(String line) say,
  }) async {
    var catchers = <WorldMailCatcher>[];
    for (var service in services) {
      var core = stack.services.where((s) => s.id == service.id).firstOrNull;
      var mail = core?.declaration.mail;
      if (core == null || mail == null) continue;
      var port = mail.http;
      if (mail.httpFrom case var source?) {
        String? problem;
        (port, problem) = await _portFrom(core, source);
        if (problem != null) {
          say(
            "${core.label}'s mail catcher has no port: $problem A mail it "
            'catches reaches nobody in this world.',
          );
          continue;
        }
      }
      catchers.add(
        WorldMailCatcher(
          name: mail.name,
          kind: mail.kind,
          api: Uri.parse('http://localhost:$port/'),
          senders: mail.senders,
        ),
      );
    }
    return catchers;
  }

  /// The port [source] prints, run for [service]'s checkout, or why not.
  static Future<(int?, String?)> _portFrom(
    StackServiceCore service,
    ValueSource source,
  ) async {
    if (source is! ScriptSource) {
      return (null, 'only ValueSource.script can give its port.');
    }
    var outcome = await runDefineScript(
      source,
      dartExecutable: p.join(
        service.host.workspace.flutterSdk.root,
        'bin',
        'dart',
      ),
      worktreePath: service.host.worktree.path,
    );
    if (outcome.problem case var problem?) return (null, '$problem.');
    var printed = outcome.value?.trim();
    if (int.tryParse(printed ?? '') case var port? when port > 0) {
      return (port, null);
    }
    return (
      null,
      printed == null
          ? '${source.path} printed ${outcome.options.length} values.'
          : '${source.path} printed "$printed", which is not a port number.',
    );
  }

  static void _sayEnded(
    EnsuredService service,
    void Function(String line) say,
  ) {
    var at =
        service.url ?? (service.port == null ? null : 'port ${service.port}');
    switch (service.outcome) {
      case EnsureOutcome.alreadyUp:
        say('${service.name} is up${at == null ? '' : ' at $at'}');
      case EnsureOutcome.started:
        say('${service.name} started${at == null ? '' : ' at $at'}');
      case EnsureOutcome.failed || EnsureOutcome.skipped:
        say('${service.name}: ${service.failure ?? 'not up.'}');
        // What it printed is usually the reason; the end of it is enough to
        // read here.
        var lines = service.output.trimRight().split('\n');
        for (var line in lines.skip(
          lines.length > 20 ? lines.length - 20 : 0,
        )) {
          if (line.trim().isNotEmpty) say('  $line');
        }
    }
  }
}
