import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../session/job.dart' show ActionRefusal;
import '../ui/chip.dart';
import '../ui/loading_state.dart';
import '../ui/segmented.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'open_world.dart' show WorldDelivery;
import 'web_snapshot.dart';
import 'world_focus.dart' show ColumnBack;
import 'world_messages.dart';
import 'world_trace.dart';

/// One mail as its recipient would see it, read in their panel: a
/// **picture** WebKit drew of it ([WebSnapshots]), which zooms, keeps and
/// reads like any widget, with every link clickable where it is drawn.
///
/// A link goes where a phone would send it: into the recipient's app when
/// the app opens it — a scheme of its own, a web host it claims — and to a
/// browser otherwise, here the **page**, live in a web view. Under the mail,
/// what was opened in the app from it, and when.
class MailView extends StatefulWidget {
  const MailView({
    super.key,
    required this.message,
    required this.snapshots,
    required this.cause,
    required this.deliveries,
    required this.claims,
    required this.onBack,
    this.onDeliver,
  });

  final OutboxMessage message;
  final WebSnapshots snapshots;

  /// What caused it, in the trace's words.
  final String? cause;

  /// What was delivered from it so far, oldest first.
  final List<WorldDelivery> deliveries;

  /// Whether the recipient's app opens a link.
  final bool Function(String link) claims;

  /// Back to the messages.
  final VoidCallback onBack;

  /// Opens one of its links in the recipient's app; null while their app is
  /// not running.
  final Future<void> Function(String link)? onDeliver;

  @override
  State<MailView> createState() => _MailViewState();
}

class _MailViewState extends State<MailView> {
  late Future<WebSnapshot> _picture = _draw();
  WebViewController? _page;
  var _live = false;
  String? _said;

  Future<WebSnapshot> _draw() =>
      widget.snapshots.of(widget.message.html ?? mailHtml(widget.message));

  @override
  void didUpdateWidget(MailView old) {
    super.didUpdateWidget(old);
    if (old.message.id != widget.message.id) {
      _picture = _draw();
      _page = null;
      _live = false;
      _said = null;
    }
  }

  /// A link, followed as a phone would: into the app that opens it, else to
  /// a browser.
  Future<void> _follow(String link) async {
    if (_isWeb(link) && !widget.claims(link)) {
      setState(() => _live = true);
      var page = _pageController();
      await page.setJavaScriptMode(JavaScriptMode.unrestricted);
      await page.loadRequest(Uri.parse(link));
      return;
    }
    await _deliver(link);
  }

  Future<void> _deliver(String link) async {
    var deliver = widget.onDeliver;
    var person = widget.message.person ?? 'their';
    setState(() => _said = null);
    if (deliver == null) {
      setState(() => _said = "$person's app is not running.");
      return;
    }
    try {
      await deliver(link);
    } on ActionRefusal catch (refusal) {
      if (mounted) setState(() => _said = refusal.message);
    }
  }

  WebViewController _pageController() => _page ??= WebViewController()
    // The mail's own scripts stay off, as in a mail client; a web page
    // followed from it turns them on.
    ..setJavaScriptMode(JavaScriptMode.disabled)
    ..setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          if (request.url.startsWith('about:') ||
              _isWeb(request.url) && !widget.claims(request.url)) {
            return NavigationDecision.navigate;
          }
          unawaited(_deliver(request.url));
          return NavigationDecision.prevent;
        },
      ),
    )
    ..loadHtmlString(widget.message.html ?? mailHtml(widget.message));

  @override
  Widget build(BuildContext context) {
    var message = widget.message;
    var colors = context.colors;
    var sender = message.sender ?? message.id.split('/').first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColumnBack('Messages', onBack: widget.onBack),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.xl,
            FwSpacing.xs,
            FwSpacing.xl,
            FwSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(message.text, style: context.type.heading),
              const SizedBox(height: FwSpacing.xxs),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        'From $sender to ${message.to}',
                        clockOf(message.at),
                      ].join(' · '),
                      style: context.type.bodyMuted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Only once a link took the reader to a page: the way
                  // back to the mail.
                  if (_page != null)
                    FwSegmented<bool>(
                      segments: const [
                        FwSegment(false, 'Mail'),
                        FwSegment(true, 'Page'),
                      ],
                      selected: _live,
                      onChanged: (live) => setState(() => _live = live),
                    ),
                ],
              ),
              if (widget.cause case var cause?) ...[
                const SizedBox(height: FwSpacing.sm),
                FwChip(
                  cause,
                  icon: Icons.subdirectory_arrow_right,
                  mono: true,
                  tooltip: 'What caused it: ${message.step}',
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.xl,
              0,
              FwSpacing.xl,
              FwSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(context.radii.radius),
                      border: Border.all(color: colors.line),
                    ),
                    child: _live
                        ? (Platform.isMacOS
                              ? WebViewWidget(controller: _pageController())
                              : Center(
                                  child: Text(
                                    'The live page needs macOS.',
                                    style: context.type.bodyMuted,
                                  ),
                                ))
                        : _Picture(future: _picture, onLink: _follow),
                  ),
                ),
                if (widget.deliveries.isNotEmpty)
                  DeliveredLines(deliveries: widget.deliveries),
                if (_said case var said?)
                  Padding(
                    padding: const EdgeInsets.only(top: FwSpacing.sm),
                    child: Text(said, style: context.type.bodyMuted),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The picture, as wide as the column allows up to its own size, with each
/// link clickable where it is drawn.
class _Picture extends StatelessWidget {
  const _Picture({required this.future, required this.onLink});

  final Future<WebSnapshot> future;
  final Future<void> Function(String link) onLink;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: future,
    builder: (context, drawn) {
      if (drawn.error case var error?) {
        return Padding(
          padding: const EdgeInsets.all(FwSpacing.lg),
          child: Text(
            'Could not draw it: $error',
            style: context.type.bodyMuted,
          ),
        );
      }
      var page = drawn.data;
      if (page == null) {
        return const LoadingState(
          title: 'Drawing the mail',
          message: 'WebKit renders it once; half a second.',
        );
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          var scale = (constraints.maxWidth / page.width).clamp(0.0, 1.0);
          return SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: page.width * scale,
                height: page.height * scale,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.file(
                        File(page.picture),
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                    for (var link in page.links)
                      Positioned(
                        left: link.left * scale,
                        top: link.top * scale,
                        width: link.width * scale,
                        height: link.height * scale,
                        child: Tappable(
                          onTap: () => onLink(link.href),
                          feedback: TapFeedback.link,
                          child: const SizedBox.expand(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

bool _isWeb(String link) =>
    link.startsWith('https://') || link.startsWith('http://');

/// A mail with no HTML, as the plain text a mail client would show.
String mailHtml(OutboxMessage message) {
  String escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '<!doctype html><html><body style="margin:24px;'
      'font:15px -apple-system,Helvetica,sans-serif;white-space:pre-wrap">'
      '<h2>${escape(message.text)}</h2>${escape(message.body ?? '')}'
      '</body></html>';
}
