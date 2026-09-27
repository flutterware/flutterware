import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../session/job.dart' show ActionRefusal;
import '../ui/action_button.dart';
import '../ui/filter_bar.dart' show FwPill;
import '../ui/loading_state.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'web_snapshot.dart';
import 'world_canvas.dart' show ColumnBack, clockOf, messageIcon;
import 'world_trace.dart';

/// One mail as its recipient would see it, two ways: a **picture** WebKit
/// drew of it ([WebSnapshots]) — what the column opens on, which zooms, keeps
/// and reads like any widget — and the **page** itself, live in a web view.
///
/// Either way a link goes where a phone would send it: an app's link into
/// the person's app, a web link to a browser — here, the page view. The
/// links it carries are listed beneath, each with a way into the app too,
/// for a web link the app claims.
class MailView extends StatefulWidget {
  const MailView({
    super.key,
    required this.message,
    required this.snapshots,
    required this.back,
    required this.onBack,
    required this.onChoose,
    this.onDeliver,
  });

  final OutboxMessage message;
  final WebSnapshots snapshots;

  /// Where [onBack] goes.
  final String back;
  final VoidCallback onBack;

  /// Opens the step that sent it.
  final void Function(String step) onChoose;

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
      widget.snapshots.of(widget.message.html ?? _asHtml(widget.message));

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

  /// A link, followed as a phone would: the web in a browser, anything else
  /// in the app that claims it.
  Future<void> _follow(String link) async {
    if (_isWeb(link)) {
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
    if (deliver == null) {
      setState(() => _said = "$person's app is not running.");
      return;
    }
    try {
      await deliver(link);
      if (mounted) setState(() => _said = "Opened in $person's app: $link");
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
          if (_isWeb(request.url) || request.url.startsWith('about:')) {
            return NavigationDecision.navigate;
          }
          unawaited(_deliver(request.url));
          return NavigationDecision.prevent;
        },
      ),
    )
    ..loadHtmlString(widget.message.html ?? _asHtml(widget.message));

  @override
  Widget build(BuildContext context) {
    var message = widget.message;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColumnBack(widget.back, onBack: widget.onBack),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.lg,
            0,
            FwSpacing.lg,
            FwSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    messageIcon(message.kind),
                    size: FwIconSize.md,
                    color: context.colors.ink2,
                  ),
                  const SizedBox(width: FwSpacing.sm),
                  Expanded(
                    child: SelectableText(
                      message.text,
                      style: context.type.heading,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Text(
                    [
                      'to ${message.person ?? message.to}',
                      clockOf(message.at),
                    ].join(' · '),
                    style: context.type.bodyMuted,
                  ),
                  if (message.step case var step?) ...[
                    Text(' · ', style: context.type.bodyMuted),
                    Tappable(
                      onTap: () => widget.onChoose(step),
                      feedback: TapFeedback.link,
                      child: Text(
                        step,
                        style: context.type.body.copyWith(
                          color: context.colors.accent,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  FwPill(
                    label: 'Picture',
                    selected: !_live,
                    onTap: () => setState(() => _live = false),
                  ),
                  const SizedBox(width: FwSpacing.xs),
                  FwPill(
                    label: 'Page',
                    selected: _live,
                    onTap: () => setState(() => _live = true),
                  ),
                ],
              ),
            ],
          ),
        ),
        Container(height: 1, color: context.colors.line),
        Expanded(
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
        if (_said case var said?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.lg,
              FwSpacing.sm,
              FwSpacing.lg,
              0,
            ),
            child: Text(said, style: context.type.bodyMuted),
          ),
        _Links(
          message: message,
          picture: _picture,
          onDeliver: widget.onDeliver == null ? null : _deliver,
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

/// Every link the mail carries, each with a way into the recipient's app —
/// the answer for a web link the app claims, which a click would open in
/// the page instead.
class _Links extends StatelessWidget {
  const _Links({
    required this.message,
    required this.picture,
    required this.onDeliver,
  });

  final OutboxMessage message;
  final Future<WebSnapshot> picture;
  final Future<void> Function(String link)? onDeliver;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: picture,
    builder: (context, drawn) {
      // The words on each link, once the picture says them.
      var words = {
        for (var link in drawn.data?.links ?? const <WebLink>[])
          link.href: link.text,
      };
      var links = message.links;
      if (links.isEmpty) return const SizedBox.shrink();
      var whose = message.person == null ? 'their' : "${message.person}'s";
      return Container(
        constraints: const BoxConstraints(maxHeight: 180),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.colors.line)),
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.lg,
            vertical: FwSpacing.sm,
          ),
          children: [
            Text('Links', style: context.type.sectionLabel),
            for (var link in links)
              Padding(
                padding: const EdgeInsets.only(top: FwSpacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (words[link] ?? words['$link/'] case var text?
                              when text.isNotEmpty)
                            Text(text, style: context.type.body),
                          Text(
                            link,
                            style: context.type.caption,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: FwSpacing.sm),
                    FwActionButton(
                      label: 'Open in $whose app',
                      onPressed: switch (onDeliver) {
                        var deliver? => () => deliver(link),
                        null => null,
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

bool _isWeb(String link) =>
    link.startsWith('https://') || link.startsWith('http://');

/// A mail with no HTML, as the plain text a mail client would show.
String _asHtml(OutboxMessage message) {
  String escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '<!doctype html><html><body style="margin:24px;'
      'font:15px -apple-system,Helvetica,sans-serif;white-space:pre-wrap">'
      '<h2>${escape(message.text)}</h2>${escape(message.body ?? '')}'
      '</body></html>';
}
