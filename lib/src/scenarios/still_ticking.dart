/// What keeps a screen asking for frames once a settle has given up on it.
///
/// A step that never settles runs its whole budget on every replay, and the
/// count of such steps says only that something is moving. Which thing is the
/// question a reader then answers by hand — measured on a real suite, a list
/// whose "in progress" row drew an indeterminate spinner made its scenario
/// ten times slower, and nothing in the report pointed at the row.
///
/// The framework already knows. In debug, every frame callback keeps the stack
/// that registered it, and a ticker that re-registers every frame keeps the
/// stack of its first `start` — so a still-ticking spinner still carries
/// `_CircularProgressIndicatorState._updateControllerAnimatingStatus`, and a
/// looping controller of the app's carries the app's own line.
/// [SchedulerBinding.debugAssertNoTransientCallbacks] is the one public door
/// to those stacks. A frame the framework owns says nothing about *where*, so
/// the element that owns it is found by its state's type, and named by the
/// first widget above it that the app's own code created — read through the
/// inspector, the one reader of `--track-widget-creation`'s locations.
///
/// Debug-only, like everything it reads. Without asserts it finds nothing, and
/// says so by returning nothing.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../design_libraries.dart';

/// What each frame callback still registered was started by, one line each,
/// the same line once however many callbacks share it.
///
/// `CircularProgressIndicator (lib/src/orders/status_cell.dart:42)` for a
/// framework widget the app built, `_PulseState.initState
/// (package:app/src/pulse.dart:18)` for animation the app started itself, and
/// the framework frame as it is when neither can be found.
List<String> whatKeepsTicking() {
  var described = <String>{};
  for (var stack in _transientCallbackStacks()) {
    var frame = _startingFrame(stack);
    if (frame == null) continue;
    var owned = _framework.any(frame.location.startsWith)
        ? _ownersOf(frame.owner)
        : const <String>[];
    described.addAll(owned.isEmpty ? [frame.label] : owned);
  }
  return described.toList();
}

List<StackTrace> _transientCallbackStacks() {
  if (SchedulerBinding.instance.transientCallbackCount == 0) return const [];
  FlutterErrorDetails? reported;
  var onError = FlutterError.onError;
  FlutterError.onError = (details) => reported = details;
  try {
    SchedulerBinding.instance.debugAssertNoTransientCallbacks('');
  } finally {
    FlutterError.onError = onError;
  }
  return [
    for (var node in reported?.informationCollector?.call() ?? const [])
      if (node case DiagnosticsStackTrace(value: StackTrace stack)) stack,
  ];
}

/// The first frame below the ticker machinery: who called `repeat`, `forward`
/// or `scheduleFrameCallback`.
({String owner, String member, String location, String label})? _startingFrame(
  StackTrace stack,
) {
  for (var line in '$stack'.split('\n')) {
    var match = _frame.firstMatch(line);
    if (match == null) continue;
    var member = match.group(1)!;
    var location = match.group(2)!;
    if (_machinery.any(location.startsWith)) continue;
    var at = _column.firstMatch(location)?.group(1) ?? location;
    return (
      owner: member.split('.').first,
      member: member,
      location: location,
      label: '$member ($at)',
    );
  }
  return null;
}

/// The widgets whose state is [stateType], still allowed to tick, each named
/// by where the app created it — or by its own type alone when no widget
/// above it has a location outside the framework.
List<String> _ownersOf(String stateType) {
  var owners = <String>[];
  void visit(Element element) {
    if (element is StatefulElement &&
        _typeName(element.state.runtimeType) == stateType &&
        TickerMode.valuesOf(element).enabled) {
      var location = _appCreation(element);
      var name = _typeName(element.widget.runtimeType);
      owners.add(location == null ? name : '$name ($location)');
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return owners;
}

/// `lib/src/orders/status_cell.dart:42`: where the app's own code created
/// [element]'s widget, or the nearest widget above it the app created.
String? _appCreation(Element element) {
  String? found;
  bool look(Element element) {
    var json = element.widget.toDiagnosticsNode().toJsonMap(
      InspectorSerializationDelegate(service: WidgetInspectorService.instance),
    );
    if (json['creationLocation'] case {'file': String file, 'line': int line}
        when !_sdk.hasMatch(file) && !designLibraryFile.hasMatch(file)) {
      found = '${_readable(file)}:$line';
      return false;
    }
    return true;
  }

  if (look(element)) element.visitAncestorElements(look);
  return found;
}

/// A `file://` URI as the part a reader recognises: from its package's `lib`
/// or `test` on.
String _readable(String file) {
  var segments = Uri.tryParse(file)?.pathSegments ?? const <String>[];
  var root = [
    segments.lastIndexOf('lib'),
    segments.lastIndexOf('test'),
  ].reduce((a, b) => a > b ? a : b);
  return root < 0 ? file : segments.sublist(root).join('/');
}

String _typeName(Type type) {
  var name = '$type';
  var generic = name.indexOf('<');
  return generic < 0 ? name : name.substring(0, generic);
}

final _frame = RegExp(r'^#\d+\s+(.+?) \((.+)\)$');

/// `…/file.dart:20:7` → `…/file.dart:20`.
final _column = RegExp(r'^(.*?:\d+)(?::\d+)?$');

/// A creation location inside the Flutter SDK's own packages.
final _sdk = RegExp(r'/packages/flutter(_test)?/lib/');

/// The libraries whose frames are the framework's.
const _framework = ['package:flutter/', ...designLibraryPackages];

const _machinery = [
  'dart:',
  'package:flutter/src/scheduler/',
  'package:flutter/src/animation/',
  'package:flutter/src/widgets/ticker_provider.dart',
];
