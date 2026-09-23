import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:vm_service/vm_service.dart';

import '../ui/filter_bar.dart';
import '../ui/http_row.dart';
import '../ui/json_view.dart';
import '../ui/split_pane.dart';
import '../ui/tappable.dart';
import 'connection.dart';
import 'handle.dart';
import 'network_tracker.dart';
import '../ui/design/design.dart';
import '../ui/loading_state.dart';
import '../ui/error_state.dart';
import '../ui/empty_state.dart';

final _logger = Logger('run_network');

/// The run's HTTP traffic — a native tab, present for every debug run.
///
/// The data is the VM's own http profile, the source behind DevTools' Network
/// page, so this works against any app the cockpit can reach: no devbar, no
/// opt-in, no wrapper client. What the app *chose* to say lives in the App
/// tab; this is what flutterware can see.
///
/// The look follows the server panel's Requests tab deliberately — the two
/// are the same thing seen from opposite ends of the wire, and a person moves
/// between them on one bug.
class NetworkTab extends StatefulWidget {
  const NetworkTab({super.key, required this.handle, this.connect});

  final RunHandle handle;

  /// How to reach the app. Injected for tests that drive a fake VM.
  final Future<RunConnection> Function(String wsUri)? connect;

  @override
  State<NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends State<NetworkTab> {
  RunConnection? _connection;
  RunNetworkTracker? _tracker;
  StreamSubscription<void>? _changes;
  String? _error;
  var _loading = true;
  String? _selectedId;

  /// The list's filter, held here rather than in the list — selecting a
  /// request swaps the child of the branch below from a bare [_RequestList] to
  /// a [FwSplitPane] wrapping one, a different runtime type in the same slot,
  /// so anything held inside the list is discarded on every selection. The
  /// server panel's Requests tab keeps its filter the same way.
  var _failedOnly = false;
  final _needle = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_attach());
  }

  @override
  void dispose() {
    _needle.dispose();
    unawaited(_changes?.cancel());
    _tracker?.dispose();
    unawaited(_connection?.close());
    super.dispose();
  }

  Future<void> _attach() async {
    var wsUri = widget.handle.vmService;
    if (wsUri == null) {
      setState(() {
        _loading = false;
        _error = 'This run has no VM service to attach to.';
      });
      return;
    }
    try {
      var connection = await (widget.connect ?? RunConnection.connect)(wsUri);
      if (!mounted) {
        unawaited(connection.close());
        return;
      }
      _connection = connection;
      var tracker = RunNetworkTracker(connection);
      _tracker = tracker;
      _changes = tracker.changes.listen((_) {
        if (mounted) setState(() {});
      });
      await tracker.poll();
      tracker.start();
      if (mounted) setState(() => _loading = false);
    } on Object catch (e) {
      _logger.fine('could not attach to ${widget.handle.key}: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not reach this app.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    var tracker = _tracker;
    if (_loading) return const LoadingState(title: 'Reading the network log…');
    if (_error != null || tracker == null) {
      return ErrorState(title: 'Could not reach this app', message: _error);
    }
    if (tracker.broken) {
      return const ErrorState(title: 'This app stopped answering');
    }
    var requests = tracker.requests
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    var newestFirst = requests.reversed.toList();
    var selected = requests.where((r) => r.id == _selectedId).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: requests.isEmpty
              ? const EmptyState(
                  icon: Icons.swap_vert,
                  title: 'No requests yet',
                  message: 'Anything the app fetches lands here.',
                )
              : selected == null
              ? _requestList(newestFirst, null, oneLine: true)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    var detail = _RequestDetail(
                      // A new state per request *and* per completion: the
                      // same id goes from in-flight to answered, and the
                      // detail refetches when it does.
                      key: ValueKey(
                        '${selected.id}:${selected.response?.statusCode}',
                      ),
                      tracker: tracker,
                      request: selected,
                      onClose: () => _select(null),
                    );
                    // Below this there is no room for two columns beside the
                    // 380px list — the detail takes the pane and close is the
                    // way back.
                    if (constraints.maxWidth < 640) return detail;
                    return FwSplitPane(
                      list: _requestList(newestFirst, selected.id),
                      detail: detail,
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(
            children: [
              Text(
                '${requests.length} '
                'request${requests.length == 1 ? '' : 's'}',
                style: context.type.caption,
              ),
              const Spacer(),
              TextButton(
                onPressed: requests.isEmpty
                    ? null
                    : () {
                        _select(null);
                        unawaited(tracker.clear());
                      },
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _select(String? id) => setState(() => _selectedId = id);

  /// One [_RequestList], wherever the branch above puts it, reading the filter
  /// this `State` owns.
  Widget _requestList(
    List<HttpProfileRequestRef> requests,
    String? selectedId, {
    bool oneLine = false,
  }) => _RequestList(
    requests: requests,
    selectedId: selectedId,
    onSelect: _select,
    oneLine: oneLine,
    failedOnly: _failedOnly,
    onFailedOnly: (it) => setState(() => _failedOnly = it),
    needle: _needle,
    onNeedle: () => setState(() {}),
  );
}

/// The request list. **Stateless on purpose** — see [_NetworkTabState] for
/// where the filter lives and why it cannot live here.
class _RequestList extends StatelessWidget {
  const _RequestList({
    required this.requests,
    required this.selectedId,
    required this.onSelect,
    required this.failedOnly,
    required this.onFailedOnly,
    required this.needle,
    required this.onNeedle,
    this.oneLine = false,
  });

  /// Newest first.
  final List<HttpProfileRequestRef> requests;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  final bool failedOnly;
  final ValueChanged<bool> onFailedOnly;

  /// The URL box's text, owned above so it survives a selection.
  final TextEditingController needle;

  /// Called when [needle] changes, so the owner can rebuild.
  final VoidCallback onNeedle;

  /// True in the full-width form, where the row can be one line.
  final bool oneLine;

  @override
  Widget build(BuildContext context) {
    var query = needle.text.trim().toLowerCase();
    var shown = [
      for (var request in requests)
        if ((!failedOnly || _isFailure(request)) &&
            (query.isEmpty ||
                '${request.method} ${request.uri}'.toLowerCase().contains(
                  query,
                )))
          request,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwFilterBar(
          pills: [
            ('All', !failedOnly, () => onFailedOnly(false)),
            ('Errors', failedOnly, () => onFailedOnly(true)),
          ],
          hint: 'Filter URLs…',
          searchController: needle,
          onSearch: (_) => onNeedle(),
          count: '${shown.length} of ${requests.length}',
        ),
        Expanded(
          child: shown.isEmpty
              ? const EmptyState(
                  icon: Icons.swap_vert,
                  title: 'Nothing matches this filter',
                )
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, index) => _RequestRow(
                    request: shown[index],
                    selected: shown[index].id == selectedId,
                    oneLine: oneLine,
                    onSelect: onSelect,
                  ),
                ),
        ),
      ],
    );
  }
}

/// A request worth filtering to: a 4xx, a 5xx, or one that never answered.
bool _isFailure(HttpProfileRequestRef request) {
  var status = networkStatusOf(request);
  return status is String || (status is int && status >= 400);
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    required this.request,
    required this.selected,
    required this.onSelect,
    this.oneLine = false,
  });

  final HttpProfileRequestRef request;
  final bool selected;
  final ValueChanged<String?> onSelect;

  /// One line at full width, two in the split's column — the server panel's
  /// row, for the reason its own comment gives: narrowing used to drop the
  /// timestamp, which is the column a request is correlated by.
  final bool oneLine;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mono = context.type.mono;
    var status = networkStatusOf(request);
    var time = Text(
      oneLine ? _timestamp(request.startTime) : _clock(request.startTime),
      style: mono.copyWith(color: colors.mut2),
    );
    var path = Text(
      _pathOf(request.uri),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: mono,
    );
    var duration = Text(
      _ms(networkDurationOf(request)),
      style: mono.copyWith(color: colors.mut2),
    );
    return Tappable(
      onTap: () => onSelect(request.id),
      child: Container(
        color: selected ? colors.accentSoft : null,
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.sm,
        ),
        child: oneLine
            ? Row(
                children: [
                  time,
                  const Gap(FwSpacing.lg),
                  HttpMethodToken(request.method),
                  const Gap(FwSpacing.md),
                  Expanded(child: path),
                  const Gap(FwSpacing.md),
                  HttpStatusCode(status),
                  const Gap(FwSpacing.md),
                  duration,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      HttpMethodToken(request.method),
                      const Gap(FwSpacing.md),
                      Expanded(child: path),
                      const Gap(FwSpacing.md),
                      duration,
                    ],
                  ),
                  const Gap(2),
                  Row(
                    children: [
                      time,
                      const Gap(FwSpacing.md),
                      HttpStatusCode(status),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// The selected request, in tabs: the request and response messages, and the
/// profiler's own timing events.
class _RequestDetail extends StatefulWidget {
  const _RequestDetail({
    super.key,
    required this.tracker,
    required this.request,
    required this.onClose,
  });

  final RunNetworkTracker tracker;
  final HttpProfileRequestRef request;
  final VoidCallback onClose;

  @override
  State<_RequestDetail> createState() => _RequestDetailState();
}

class _RequestDetailState extends State<_RequestDetail> {
  static const _tabs = ['request', 'response', 'timing'];
  var _tab = 'response';

  late final Future<HttpProfileRequest?> _detail = widget.tracker.detailsFor(
    widget.request.id,
  );

  @override
  Widget build(BuildContext context) {
    var request = widget.request;
    var status = networkStatusOf(request);
    var error = networkErrorOf(request);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${request.method} ${_pathOf(request.uri)}'
                  '${status == null ? '' : ' → $status'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.mono.copyWith(fontSize: 14),
                ),
              ),
              Text(
                _ms(networkDurationOf(request)),
                style: context.type.mono.copyWith(fontSize: 14),
              ),
              const SizedBox(width: 8),
              _CopyAsCurlButton(detail: _detail),
              IconButton(
                icon: const Icon(Icons.close, size: FwIconSize.lg),
                tooltip: 'Back to the request list',
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              error,
              style: context.type.body.copyWith(color: context.colors.red),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Wrap(
            spacing: 4,
            children: [
              for (var name in _tabs)
                TextButton(
                  style: name == _tab
                      ? TextButton.styleFrom(
                          backgroundColor: context.colors.accentSoft,
                        )
                      : null,
                  onPressed: () => setState(() => _tab = name),
                  child: Text(name),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder(
            future: _detail,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const LoadingState(title: 'Reading the request…');
              }
              var detail = snapshot.data;
              if (detail == null) {
                return const EmptyState(
                  icon: Icons.history_toggle_off,
                  title: 'No longer available',
                  message: 'The app restarted, and this request went with it.',
                );
              }
              return switch (_tab) {
                'request' => _HttpMessageTab(detail: detail, response: false),
                'timing' => _TimingTab(detail: detail),
                _ => _HttpMessageTab(detail: detail, response: true),
              };
            },
          ),
        ),
      ],
    );
  }
}

/// One side of the HTTP exchange: headers and body, from the profile's lazy
/// detail. The body arrives as bytes — decoded here, folded when it is JSON.
class _HttpMessageTab extends StatelessWidget {
  const _HttpMessageTab({required this.detail, required this.response});

  final HttpProfileRequest detail;

  /// False for the request side, true for the response side.
  final bool response;

  @override
  Widget build(BuildContext context) {
    var mono = context.type.mono;
    var headers = _headersOf(detail, response: response);
    var body = response ? detail.responseBody : detail.requestBody;
    if (headers == null && (body == null || body.isEmpty)) {
      return Center(
        child: Text(
          response && detail.response == null
              ? 'No response yet.'
              : 'Not captured.',
          style: context.type.bodyMuted,
        ),
      );
    }
    String? bodyText;
    var binary = false;
    if (body != null && body.isNotEmpty) {
      try {
        bodyText = utf8.decode(body);
      } on FormatException {
        binary = true;
      }
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Headers', style: context.type.sectionLabel),
        const SizedBox(height: 4),
        for (var entry in (headers ?? const {}).entries)
          for (var value
              in entry.value is List ? entry.value! as List : [entry.value])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: SelectableText('${entry.key}: $value', style: mono),
            ),
        const SizedBox(height: 16),
        Text('Body', style: context.type.sectionLabel),
        const SizedBox(height: 4),
        if (bodyText == null)
          Text(
            binary ? '${body!.length} bytes of binary data.' : 'Empty.',
            style: context.type.caption,
          )
        // A JSON body folds; anything else stays plain text. Sniffing the
        // first character beats trusting content-type, which lies.
        else if (bodyText.trimLeft().startsWith(RegExp(r'[\[{]')))
          JsonView.source(bodyText, maxHeight: 520)
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.colors.panel2,
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
            child: SelectableText(bodyText, style: mono),
          ),
      ],
    );
  }
}

/// The profiler's own event list — connection, request sent, first byte,
/// download — with the gap to the previous event, which is where the time
/// went.
class _TimingTab extends StatelessWidget {
  const _TimingTab({required this.detail});

  final HttpProfileRequest detail;

  @override
  Widget build(BuildContext context) {
    var events = detail.events;
    if (events.isEmpty) {
      return const EmptyState(icon: Icons.timeline, title: 'No timing events');
    }
    var previous = detail.startTime;
    var rows = <(String, Duration)>[];
    for (var event in events) {
      rows.add((event.event, event.timestamp.difference(previous)));
      previous = event.timestamp;
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (var (label, gap) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(child: Text(label, style: context.type.mono)),
                Text(
                  '+${_ms(gap.inMicroseconds / 1000)}',
                  style: context.type.mono.copyWith(color: context.colors.mut2),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One click from "I see the request" to "I can reproduce it in a terminal".
/// Unlike the server panel's version this needs no published base URL — the
/// profile records the absolute URI the client actually called.
class _CopyAsCurlButton extends StatelessWidget {
  const _CopyAsCurlButton({required this.detail});

  final Future<HttpProfileRequest?> detail;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.terminal, size: FwIconSize.lg),
      tooltip: 'Copy as curl',
      onPressed: () async {
        var resolved = await detail;
        if (resolved == null) return;
        await Clipboard.setData(ClipboardData(text: curlForRequest(resolved)));
      },
    );
  }
}

/// The request replayed from a shell — same shape as the server panel's
/// `curlCommand`, built from the profile's detail instead of a feed event.
String curlForRequest(HttpProfileRequest detail) {
  var methodFlag = detail.method == 'GET' ? '' : ' -X ${detail.method}';
  var lines = ['curl$methodFlag ${_shellQuote(detail.uri.toString())}'];
  var headers = _headersOf(detail, response: false);
  if (headers != null) {
    for (var entry in headers.entries) {
      var name = entry.key.toLowerCase();
      if (name == 'host' || name == 'content-length') continue;
      var values = entry.value is List ? entry.value! as List : [entry.value];
      for (var value in values) {
        lines.add('-H ${_shellQuote('${entry.key}: $value')}');
      }
    }
  }
  var body = detail.requestBody;
  if (body != null && body.isNotEmpty) {
    try {
      lines.add('--data-raw ${_shellQuote(utf8.decode(body))}');
    } on FormatException {
      // A binary body has no faithful shell form; the command without it
      // still names the call.
    }
  }
  return lines.join(' \\\n  ');
}

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Headers for one side, null when that side errored or was never recorded —
/// the typed model throws on access after an error.
Map<String, Object?>? _headersOf(
  HttpProfileRequest detail, {
  required bool response,
}) {
  var raw = response
      ? detail.response?.headers
      : (detail.request?.hasError ?? true)
      ? null
      : detail.request?.headers;
  return raw?.cast<String, Object?>();
}

String _pathOf(Uri uri) {
  var path = uri.path.isEmpty ? '/' : uri.path;
  return uri.hasQuery ? '$path?${uri.query}' : path;
}

String _ms(Object? value) =>
    value is num ? '${value.toStringAsFixed(1)}ms' : '';

/// `hh:mm:ss`, for a row with no width for the milliseconds.
String _clock(DateTime time) =>
    '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

String _timestamp(DateTime time) =>
    '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}'
    '.${time.millisecond.toString().padLeft(3, '0')}';

String _two(int n) => n.toString().padLeft(2, '0');
