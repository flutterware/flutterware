/// Spike: the DevTools network data source, from the run's own VM service.
///
/// Measures the loop a cockpit Network tab would run: enable
/// `ext.dart.io.httpEnableTimelineLogging`, poll `getHttpProfile` with
/// `updatedSince`, fetch one request's full detail (headers, body bytes,
/// timeline events) by id. Run one subcommand per process against the newest
/// run handle this worktree launched, or pass an explicit `ws://` URI.
///
///     fvm dart run tool/http_profile_spike.dart status
///     fvm dart run tool/http_profile_spike.dart enable
///     fvm dart run tool/http_profile_spike.dart list [sinceMicros]
///     fvm dart run tool/http_profile_spike.dart detail <requestId>
///     fvm dart run tool/http_profile_spike.dart socket
///     fvm dart run tool/http_profile_spike.dart clear
///
/// This file is a measuring instrument; nothing ships from it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print(
      'usage: http_profile_spike.dart '
      '<status|enable|disable|list|detail|socket|clear> [args] '
      '[--ws=ws://...]',
    );
    exit(64);
  }
  var command = args.first;
  var wsArg = args
      .where((a) => a.startsWith('--ws='))
      .map((a) => a.substring('--ws='.length))
      .firstOrNull;
  var rest = args.skip(1).where((a) => !a.startsWith('--ws=')).toList();

  var wsUri = wsArg ?? _discoverWsUri();
  print('# connecting to $wsUri');
  var watch = Stopwatch()..start();
  var service = await vmServiceConnectUri(wsUri);
  var vm = await service.getVM();
  var isolateId = vm.isolates!.first.id!;
  print('# connected in ${watch.elapsedMilliseconds}ms, isolate $isolateId');

  watch.reset();
  try {
    switch (command) {
      case 'status':
        var available = await service.isHttpProfilingAvailable(isolateId);
        var state = await service.httpEnableTimelineLogging(isolateId);
        var version = await service.getDartIOVersion(isolateId);
        print(
          'dart:io extension version: '
          '${version.major}.${version.minor}',
        );
        print('http profiling available: $available');
        print('timeline logging enabled: ${state.enabled}');
      case 'enable':
      case 'disable':
        var state = await service.httpEnableTimelineLogging(
          isolateId,
          command == 'enable',
        );
        print(
          'timeline logging enabled: ${state.enabled} '
          '(${watch.elapsedMilliseconds}ms)',
        );
      case 'list':
        var since = rest.isEmpty
            ? null
            : DateTime.fromMicrosecondsSinceEpoch(int.parse(rest.first));
        // Raw call first, to measure what the wire actually carries.
        var raw = await service.callServiceExtension(
          'ext.dart.io.getHttpProfile',
          isolateId: isolateId,
          args: {
            if (since != null) 'updatedSince': since.microsecondsSinceEpoch,
          },
        );
        var rawBytes = utf8.encode(jsonEncode(raw.json)).length;
        var profile = await service.getHttpProfile(
          isolateId,
          updatedSince: since,
        );
        var requests = profile.requests;
        print(
          'list: ${requests.length} requests, raw $rawBytes bytes, '
          '${watch.elapsedMilliseconds}ms, '
          'timestamp ${profile.timestamp.microsecondsSinceEpoch}',
        );
        for (var r in requests) {
          var end = r.endTime;
          var ms = end == null
              ? '…'
              : ((end.difference(r.startTime).inMicroseconds) / 1000)
                    .toStringAsFixed(1);
          print(
            '  [${r.id}] ${r.method} ${r.uri} '
            '-> ${r.response?.statusCode ?? '…'} ${ms}ms '
            'start=${r.startTime.microsecondsSinceEpoch}',
          );
        }
      case 'detail':
        var raw = await service.callServiceExtension(
          'ext.dart.io.getHttpProfileRequest',
          isolateId: isolateId,
          args: {'id': rest.first},
        );
        var rawBytes = utf8.encode(jsonEncode(raw.json)).length;
        var r = await service.getHttpProfileRequest(isolateId, rest.first);
        print('detail: raw $rawBytes bytes, ${watch.elapsedMilliseconds}ms');
        print('  ${r.method} ${r.uri} -> ${r.response?.statusCode}');
        print('  request headers: ${jsonEncode(r.request?.headers)}');
        print('  response headers: ${jsonEncode(r.response?.headers)}');
        var requestBody = r.requestBody;
        var responseBody = r.responseBody;
        print(
          '  request body (${requestBody?.length ?? 0}b): '
          '${_preview(requestBody)}',
        );
        print(
          '  response body (${responseBody?.length ?? 0}b): '
          '${_preview(responseBody)}',
        );
        print('  request events:');
        for (var e in r.events) {
          print('    ${e.timestamp.microsecondsSinceEpoch} ${e.event}');
        }
      case 'socket':
        var profile = await service.getSocketProfile(isolateId);
        print(
          'socket: ${profile.sockets.length} sockets, '
          '${watch.elapsedMilliseconds}ms',
        );
        for (var s in profile.sockets.take(20)) {
          print(
            '  [${s.id}] ${s.socketType} ${s.address}:${s.port} '
            'r=${s.readBytes} w=${s.writeBytes}',
          );
        }
      case 'watch':
        // The loop a cockpit tracker would run: updatedSince cursor, 500ms.
        var seconds = rest.isEmpty ? 15 : int.parse(rest.first);
        DateTime? since;
        var deadline = DateTime.now().add(Duration(seconds: seconds));
        while (DateTime.now().isBefore(deadline)) {
          var profile = await service.getHttpProfile(
            isolateId,
            updatedSince: since,
          );
          since = profile.timestamp;
          for (var r in profile.requests) {
            var status = r.response?.statusCode;
            print(
              '${DateTime.now().toIso8601String()} '
              '[${r.id}] ${r.method} ${r.uri.path} '
              '-> ${status ?? 'IN FLIGHT'}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      case 'clear':
        await service.clearHttpProfile(isolateId);
        print('cleared (${watch.elapsedMilliseconds}ms)');
      default:
        print('unknown command: $command');
        exit(64);
    }
  } finally {
    await service.dispose();
  }
}

String _preview(List<int>? body) {
  if (body == null || body.isEmpty) return '<empty>';
  var text = utf8.decode(body.take(200).toList(), allowMalformed: true);
  return text.replaceAll('\n', r'\n');
}

/// Newest handle launched from this worktree that has a VM service URI.
String _discoverWsUri() {
  var home = Platform.environment['HOME']!;
  var runDir = Directory('$home/.flutterware/run');
  var worktree = Directory.current.parent.path; // script runs from app/
  var candidates = <(DateTime, String)>[];
  for (var entry in runDir.listSync()) {
    if (entry is! File) continue;
    var name = entry.uri.pathSegments.last;
    if (!name.startsWith('app-') || !name.endsWith('.json')) continue;
    try {
      var json = jsonDecode(entry.readAsStringSync()) as Map<String, Object?>;
      if (json['worktree'] != worktree) continue;
      var ws = json['vmService'] as String?;
      if (ws == null) continue;
      candidates.add((DateTime.parse(json['startedAt']! as String), ws));
    } on Object {
      continue;
    }
  }
  if (candidates.isEmpty) {
    print(
      'no run handle with a vmService URI for $worktree — '
      'launch first, or pass --ws=',
    );
    exit(1);
  }
  candidates.sort((a, b) => b.$1.compareTo(a.$1));
  return candidates.first.$2;
}
