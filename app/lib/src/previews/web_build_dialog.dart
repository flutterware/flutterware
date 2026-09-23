import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../plugins/native/previews_core.dart';
import '../plugins/native/previews_results.dart';
import '../ui/design/design.dart';
import '../ui/theme.dart';
import '../utils/base_href.dart';
import 'web_build.dart';

/// Configures a web build, runs it, and shows what the tool says while it does.
///
/// It calls [PreviewsCore.buildWeb] directly rather than going through
/// `Session.invoke`. The behaviour is still the core's — `fw` reaches the same
/// method by its own route, and the `build-web` action is that route. What the
/// action cannot carry is the thing this exists for: a build takes tens of
/// seconds, and `Job` has no log or progress event to put those lines in (see
/// `session/job.dart`, which says so and declines to guess a shape for them).
/// A dialog that showed a spinner for half a minute and then a path would be a
/// worse answer than the CLI already gives.
Future<void> showWebBuildDialog(
  BuildContext context, {
  required PreviewsCore core,
  required String package,
  required ServeBuild serve,
}) => showDialog<void>(
  context: context,
  // A build outlives a careless click outside the dialog, and the log is the
  // only place its output exists.
  barrierDismissible: false,
  builder: (context) =>
      _WebBuildDialog(core: core, package: package, serve: serve),
);

/// The same build, spelled for a terminal.
///
/// Shown in the dialog for discovery: the button and `fw` reach one method on
/// the core, and nothing on screen says so. Somebody who wants this in a
/// script, or in CI, should not have to learn from the docs that it is
/// possible.
///
/// Only what is not already the default is included — a command line carrying
/// flags that change nothing teaches the flags rather than the command.
///
/// A function rather than a method so a test can check the flags against the
/// ones the action declares. This string is an instruction to a user: a flag
/// renamed on the action and not here is a command that fails when they run it.
String webBuildCommand({
  required String pluginId,
  required String package,
  required bool nameThePackage,
  String output = '',
  String baseHref = '',
}) => [
  'dart run flutterware run ${pluginId.split('.').last} $webBuildActionId',
  if (nameThePackage) '--package=${_shellArg(package)}',
  if (output.isNotEmpty && output != WebCatalogBuilder.defaultOutput)
    '--output=${_shellArg(output)}',
  if (baseHref.isNotEmpty) '--base-href=${_shellArg(baseHref)}',
].join(' ');

/// Quoted when a shell would otherwise split it.
String _shellArg(String value) =>
    value.contains(RegExp(r'\s')) ? "'$value'" : value;

/// Puts a built directory on a local port and answers with its URL.
///
/// A callback rather than something this file does, because the server has to
/// outlive the dialog: you close this the moment the tab is open. The plugin
/// owns them and ends them with the worktree.
typedef ServeBuild = Future<Uri> Function(String output, {String basePath});

class _WebBuildDialog extends StatefulWidget {
  const _WebBuildDialog({
    required this.core,
    required this.package,
    required this.serve,
  });

  final PreviewsCore core;
  final String package;
  final ServeBuild serve;

  @override
  State<_WebBuildDialog> createState() => _WebBuildDialogState();
}

class _WebBuildDialogState extends State<_WebBuildDialog> {
  final _output = TextEditingController(text: WebCatalogBuilder.defaultOutput);
  final _baseHref = TextEditingController();

  final _log = <String>[];
  final _logScroll = ScrollController();

  var _running = false;
  CatalogWebBuildResult? _built;
  String? _error;

  /// Where the last build is being served, once something has asked. Kept so
  /// the URL stays on screen and a second look does not need a second click.
  Uri? _served;

  /// The base href the finished build was compiled with — not what the field
  /// says now, which the user may have edited since.
  String? _builtBaseHref;

  @override
  void initState() {
    super.initState();
    // The echoed command below is built from these, so it has to be rebuilt as
    // they are typed — a command line that lags the form it claims to mirror
    // is worse than none.
    _output.addListener(_onFieldChanged);
    _baseHref.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _output
      ..removeListener(_onFieldChanged)
      ..dispose();
    _baseHref
      ..removeListener(_onFieldChanged)
      ..dispose();
    _logScroll.dispose();
    super.dispose();
  }

  String get _command => webBuildCommand(
    pluginId: widget.core.id,
    package: widget.package,
    // With several packages declared the action refuses without it, so there
    // it is part of the command rather than a decoration on it.
    nameThePackage: widget.core.packages.length > 1,
    output: _output.text.trim(),
    baseHref: _baseHref.text.trim(),
  );

  Future<void> _build() async {
    setState(() {
      _running = true;
      _built = null;
      _error = null;
      _served = null;
      _log.clear();
    });
    var baseHref = _baseHref.text.trim();
    try {
      var result = await widget.core.buildWeb(
        package: widget.package,
        output: _output.text.trim().isEmpty ? null : _output.text.trim(),
        baseHref: baseHref.isEmpty ? defaultBaseHref : baseHref,
        onOutput: _append,
      );
      if (mounted) {
        setState(() {
          _built = result;
          _builtBaseHref = absoluteMount(baseHref);
        });
      }
    } catch (e) {
      // Shown rather than thrown: the failure a user hits most is "web is not
      // enabled for this package", whose message carries the command that fixes
      // it, and that belongs on screen next to the button they just pressed.
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _open() async {
    var built = _built;
    if (built == null) return;
    try {
      // Mounted where the build was told it would be. A page built with
      // `--base-href=/catalog/` carries that in its `<base>`, so served at the
      // root it loads and then asks for every asset one directory up. The
      // relative default carries no mount, so it is served at the root.
      var url = await widget.serve(
        built.output,
        basePath: _builtBaseHref ?? '/',
      );
      if (mounted) setState(() => _served = url);
      await launchUrl(url);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _log.add(line);
      // The tool is verbose on a cold build and nothing above the last screen
      // is ever read; keeping it all would grow the dialog's memory for the
      // life of the session.
      if (_log.length > 400) _log.removeRange(0, _log.length - 400);
    });
    // After the frame that added the line, so the extent it scrolls to is the
    // one that includes it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return AlertDialog(
      title: Text(
        widget.package == '.'
            ? 'Build a web page'
            : 'Build a web page — ${widget.package}',
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Compiles every demo into a page you can browse — the widgets '
              'themselves, with their knobs, not pictures of them.',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
            const Gap(FwSpacing.xl),
            _Field(
              label: 'Write to',
              controller: _output,
              enabled: !_running,
              hint: WebCatalogBuilder.defaultOutput,
            ),
            const Gap(FwSpacing.lg),
            _Field(
              label: 'Base href',
              controller: _baseHref,
              enabled: !_running,
              hint: '$defaultBaseHref — serves from anywhere it is hosted',
            ),
            const Gap(FwSpacing.lg),
            _CommandLine(command: _command),
            if (_log.isNotEmpty) ...[
              const Gap(FwSpacing.xl),
              _Log(lines: _log, controller: _logScroll),
            ],
            if (_error case var error?) ...[
              const Gap(FwSpacing.lg),
              _Message(text: error, color: colors.red),
            ],
            if (_built case var built?) ...[
              const Gap(FwSpacing.lg),
              _Message(
                text:
                    '${built.entries} '
                    '${built.entries == 1 ? 'entry' : 'entries'} → '
                    '${built.output}  '
                    '(${(built.durationMs / 1000).toStringAsFixed(1)}s)',
                color: colors.grn,
              ),
              if (_served case var url?) ...[
                const Gap(FwSpacing.xs),
                // Left on screen after the tab opens: the server outlives this
                // dialog, and without the URL written down the only way back to
                // a page you closed is to build it again.
                _Message(
                  text: 'Serving at $url — until this worktree is closed.',
                  color: colors.mut,
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: Text(_built == null ? 'Cancel' : 'Close'),
        ),
        TextButton(
          onPressed: _running || _built == null ? null : _build,
          child: const Text('Build again'),
        ),
        // The primary action once there is something to look at: building a
        // page you then have to go and find is most of the work and none of
        // the point.
        FilledButton(
          onPressed: _running
              ? null
              : _built == null
              ? _build
              : () => unawaited(_open()),
          child: Text(
            _running
                ? 'Building…'
                : _built == null
                ? 'Build'
                : _served == null
                ? 'Open in browser'
                : 'Open again',
          ),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.enabled,
    required this.hint,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final String hint;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      SizedBox(width: 90, child: Text(label, style: context.type.bodySmall)),
      Expanded(
        child: TextField(
          controller: controller,
          enabled: enabled,
          style: context.type.bodySmall.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(isDense: true, hintText: hint),
        ),
      ),
    ],
  );
}

/// The same build as a command, with a way to take it.
///
/// Deliberately not a disabled-looking hint: it is the real invocation, so that
/// reading it once is enough to know this is scriptable.
class _CommandLine extends StatefulWidget {
  const _CommandLine({required this.command});

  final String command;

  @override
  State<_CommandLine> createState() => _CommandLineState();
}

class _CommandLineState extends State<_CommandLine> {
  Timer? _copied;

  @override
  void dispose() {
    _copied?.cancel();
    super.dispose();
  }

  void _copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.command)));
    _copied?.cancel();
    setState(() {});
    _copied = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var justCopied = _copied?.isActive ?? false;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.md,
        FwSpacing.sm,
        FwSpacing.xs,
        FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              widget.command,
              style: context.type.micro.copyWith(
                fontFamily: 'monospace',
                color: colors.mut,
              ),
            ),
          ),
          const Gap(FwSpacing.sm),
          IconButton(
            icon: Icon(
              justCopied ? Icons.check : Icons.content_copy,
              size: FwIconSize.sm,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 22, height: 22),
            tooltip: 'Copy the command',
            onPressed: _copy,
          ),
        ],
      ),
    );
  }
}

/// The tool's own output, as it arrives.
class _Log extends StatelessWidget {
  const _Log({required this.lines, required this.controller});

  final List<String> lines;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      height: 180,
      width: double.infinity,
      padding: const EdgeInsets.all(FwSpacing.md),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line),
      ),
      child: SingleChildScrollView(
        controller: controller,
        child: SelectableText(
          lines.join('\n'),
          style: context.type.micro.copyWith(fontFamily: 'monospace'),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.color});

  final String text;
  final Color color;

  /// Selectable, because both messages are things you paste somewhere: the
  /// failure carries the `flutter create` that fixes it, and the success
  /// carries a path.
  @override
  Widget build(BuildContext context) => SelectableText(
    text,
    style: context.type.bodySmall.copyWith(color: color),
  );
}
