import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app_events/events.dart';
import '../../../utils/value_stream.dart';
import '../../devbar.dart';
import 'ui.dart';

/// Names `DevbarHttpClient` as the reporter of an event.
///
/// A mounted devbar registers with this as its `ignoreSource`: that client
/// hands every devbar the exchange in two halves as it happens, so the
/// completed report it makes for every *other* listener would be a second row
/// for the same request. Lives here rather than beside the client so that
/// `devbar.dart` can name it without importing its own barrel back.
///
/// A project writing its own listener can ignore it the same way.
const devbarHttpClientSource = #devbarHttpClient;

/// A plugin for the Devbar which add a tab to display network requests and responses.
class LogNetworkPlugin implements DevbarPlugin {
  static const _maxRequest = 200;

  final requests = ValueStream<List<NetworkRequest>>([]);
  final DevbarState devbar;

  /// Ids for [reported] rows. Negative, so they can never be answered by a
  /// [response] meant for one of [DevbarHttpClient]'s in-flight requests.
  var _reportedId = -1;

  LogNetworkPlugin(this.devbar) {
    devbar.ui.addTab(
      Tab(text: 'Network'),
      NetworkList(this),
      hierarchy: ['Logs'],
    );
  }

  static LogNetworkPlugin Function(DevbarState) init() {
    return (devbar) => LogNetworkPlugin(devbar);
  }

  void clear() {
    requests.add([]);
  }

  void request(
    int id, {
    String? apiName,
    Object? body,
    required String method,
    required String path,
    Map<String, String?>? parameters,
  }) {
    var request = NetworkRequest(
      id,
      apiName: apiName,
      requestBody: body,
      httpMethod: method,
      path: path,
      parameters: parameters ?? {},
    );

    var requestList = requests.value..add(request);

    if (requestList.length > _maxRequest) {
      requestList.removeAt(0);
    }

    requests.add(requestList);
  }

  /// Records an exchange that was already over when it was reported.
  ///
  /// [request]/[response] track one this process is watching go out and come
  /// back, which is what [DevbarHttpClient] has in hand. An [AppEvent] a
  /// project reported from its own client has only the outcome, so it lands
  /// here in one piece and with no timing.
  void reported(AppEvent event) {
    // The inverse of what `AppEvent.request` composed — a method never holds a
    // space. A network event some other constructor made keeps its whole title
    // as the path, which is the only honest reading of it.
    var split = event.title.indexOf(' ');
    var request = NetworkRequest(
      _reportedId--,
      apiName: null,
      requestBody: event.data.isEmpty ? null : event.data,
      httpMethod: split < 0 ? '' : event.title.substring(0, split),
      path: split < 0 ? event.title : event.title.substring(split + 1),
      parameters: const {},
      timed: false,
    );
    if (event.error) {
      request.errorResponse = ErrorResponse(
        code: int.tryParse(event.detail ?? '') ?? 0,
        reason: event.detail ?? '',
        message: event.body ?? '',
      );
    } else {
      // Decoded where it parses, so the Response tab shows a tree like it does
      // for an exchange this process watched. A report carries its body as
      // text; handed to the viewer as text it comes back JSON-encoded a second
      // time, as one escaped line.
      request.response = _decodedOrRaw(event.body);
    }

    var requestList = requests.value..add(request);
    if (requestList.length > _maxRequest) {
      requestList.removeAt(0);
    }
    requests.add(requestList);
  }

  void response(int id, {body}) {
    var request = requests.value.firstWhereOrNull((n) => n.id == id);
    if (request != null) {
      request.watch?.stop();

      request.response = body;

      requests.add(requests.value);
    }
  }

  void responseError(int id, {int? code, String? reason, String? message}) {
    var request = requests.value.firstWhereOrNull((n) => n.id == id);
    if (request != null) {
      request.watch?.stop();

      request.errorResponse = ErrorResponse(
        code: code ?? 400,
        reason: reason ?? '',
        message: message ?? '',
      );

      requests.add(requests.value);
    }
  }

  @override
  void dispose() {
    requests.dispose();
  }
}

class NetworkRequest {
  final int id;
  final String? apiName;
  final String httpMethod;
  final String path;
  final Map<String, String?> parameters;
  final dynamic requestBody;

  /// Null for a [LogNetworkPlugin.reported] row: the exchange was over before
  /// this process heard about it, so there is no duration to show. The report
  /// carries none either — the scenario design ruled durations out, because
  /// `FakeAsync` makes them meaningless.
  final Stopwatch? watch;

  dynamic response;
  ErrorResponse? errorResponse;

  NetworkRequest(
    this.id, {
    required this.apiName,
    required this.requestBody,
    required this.httpMethod,
    required this.path,
    required this.parameters,
    bool timed = true,
  }) : watch = timed ? (Stopwatch()..start()) : null;
}

/// [body] as an object where it is JSON, and unchanged where it is not — a
/// stack, an HTML error page, a line of prose.
Object? _decodedOrRaw(String? body) {
  if (body == null) return null;
  try {
    return jsonDecode(body);
  } on FormatException {
    return body;
  }
}

class ErrorResponse {
  final int code;
  final String reason, message;

  ErrorResponse({
    required this.code,
    required this.reason,
    required this.message,
  });
}

/// Extension to add `context.network` shortcut.
extension LogNetworkPluginDevbarExtension on DevbarState {
  LogNetworkPlugin get network => plugin<LogNetworkPlugin>();
}
