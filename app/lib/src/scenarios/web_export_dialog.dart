import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../plugins/native/scenarios_core.dart';
import '../plugins/native/scenarios_results.dart';
import '../previews/web_build_dialog.dart' show ServeBuild;
import '../ui/design/design.dart';
import '../ui/theme.dart';
import '../utils/base_href.dart';
import 'web_export.dart';

/// Configures an export, runs it, and shows what it says while it does.
///
/// Calls [ScenariosCore.exportWeb] directly rather than going through
/// `Session.invoke`, for the reason the catalog's build dialog gives: the
/// behaviour is the core's either way, but an export runs the whole suite and
/// may compile the viewer, and `Job` has no log or progress event to put those
/// lines in.
///
/// The one thing this must not hide is that the export **re-runs the
/// scenarios**. It is on the tin, above the fields.
Future<void> showScenarioWebExportDialog(
  BuildContext context, {
  required ScenariosCore core,
  required String package,
  required ServeBuild serve,
}) => showDialog<void>(
  context: context,
  // An export outlives a careless click outside the dialog, and the log is the
  // only place its output exists.
  barrierDismissible: false,
  builder: (context) =>
      _WebExportDialog(core: core, package: package, serve: serve),
);

/// The same export, spelled for a terminal.
///
/// A function rather than a method so a test can check the flags against the
/// ones the action declares: this string is an instruction to a user, and a
/// flag renamed on the action and not here is a command that fails when they
/// run it.
String scenarioWebExportCommand({
  required String pluginId,
  required String package,
  required bool nameThePackage,
  String output = '',
  String baseHref = '',
  bool offline = false,
}) => [
  'dart run flutterware run ${pluginId.split('.').last} $webExportActionId',
  if (nameThePackage) '--package=${_shellArg(package)}',
  if (output.isNotEmpty && output != ScenarioWebExporter.defaultOutput)
    '--output=${_shellArg(output)}',
  if (baseHref.isNotEmpty) '--base-href=${_shellArg(baseHref)}',
  if (offline) '--offline=true',
].join(' ');

String _shellArg(String value) =>
    value.contains(RegExp(r'\s')) ? "'$value'" : value;

class _WebExportDialog extends StatefulWidget {
  const _WebExportDialog({
    required this.core,
    required this.package,
    required this.serve,
  });

  final ScenariosCore core;
  final String package;
  final ServeBuild serve;

  @override
  State<_WebExportDialog> createState() => _WebExportDialogState();
}

class _WebExportDialogState extends State<_WebExportDialog> {
  final _output = TextEditingController(
    text: ScenarioWebExporter.defaultOutput,
  );
  final _baseHref = TextEditingController();
  var _offline = false;

  final _log = <String>[];
  final _logScroll = ScrollController();

  var _running = false;
  ScenarioWebExportResult? _exported;
  String? _error;

  Uri? _served;

  /// The base href the finished page was written with — not what the field
  /// says now, which the user may have edited since.
  String? _exportedBaseHref;

  @override
  void initState() {
    super.initState();
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

  String get _command => scenarioWebExportCommand(
    pluginId: widget.core.id,
    package: widget.package,
    nameThePackage: widget.core.packages.length > 1,
    output: _output.text.trim(),
    baseHref: _baseHref.text.trim(),
    offline: _offline,
  );

  Future<void> _export() async {
    setState(() {
      _running = true;
      _exported = null;
      _error = null;
      _served = null;
      _log.clear();
    });
    var baseHref = _baseHref.text.trim();
    try {
      var result = await widget.core.exportWeb({
        'package': widget.package,
        'output': _output.text.trim().isEmpty ? null : _output.text.trim(),
        'base-href': baseHref.isEmpty ? null : baseHref,
        if (_offline) 'offline': 'true',
      }, onOutput: _append);
      if (mounted) {
        setState(() {
          _exported = result;
          _exportedBaseHref = absoluteMount(baseHref);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _open() async {
    var exported = _exported;
    if (exported == null) return;
    try {
      var url = await widget.serve(
        exported.output,
        basePath: _exportedBaseHref ?? '/',
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
      if (_log.length > 400) _log.removeRange(0, _log.length - 400);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var exported = _exported;
    return AlertDialog(
      title: Text(
        widget.package == '.'
            ? 'Export a web page'
            : 'Export a web page — ${widget.package}',
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Runs the scenarios and writes the result as a page: the same '
              'flows, step pages and inspect dock you see here, for anyone '
              'with a browser and no checkout.',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
            const Gap(FwSpacing.xl),
            _Field(
              label: 'Write to',
              controller: _output,
              enabled: !_running,
              hint: ScenarioWebExporter.defaultOutput,
            ),
            const Gap(FwSpacing.lg),
            _Field(
              label: 'Base href',
              controller: _baseHref,
              enabled: !_running,
              hint: '$defaultBaseHref — serves from anywhere it is hosted',
            ),
            const Gap(FwSpacing.sm),
            CheckboxListTile(
              value: _offline,
              onChanged: _running
                  ? null
                  : (value) => setState(() => _offline = value ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text('Self-contained', style: context.type.bodySmall),
              subtitle: Text(
                "Bundles the renderer instead of fetching it from Google's "
                'CDN. Bigger, and the only form that works offline.',
                style: context.type.micro.copyWith(color: colors.mut),
              ),
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
            if (exported != null) ...[
              const Gap(FwSpacing.lg),
              _Message(
                text:
                    '${exported.scenarios} '
                    '${exported.scenarios == 1 ? 'scenario' : 'scenarios'}, '
                    '${exported.steps} steps → ${exported.output}  '
                    '(${(exported.durationMs / 1000).toStringAsFixed(1)}s)',
                color: exported.ok ? colors.grn : colors.red,
              ),
              if (exported.failed > 0) ...[
                const Gap(FwSpacing.xs),
                // Said plainly, because the page was still written and looks
                // like every other one until you open the red flow.
                _Message(
                  text:
                      '${exported.failed} failed — their flows are on the '
                      'page, up to the frame they broke on.',
                  color: colors.red,
                ),
              ],
              if (_served case var url?) ...[
                const Gap(FwSpacing.xs),
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
          child: Text(exported == null ? 'Cancel' : 'Close'),
        ),
        TextButton(
          onPressed: _running || exported == null ? null : _export,
          child: const Text('Export again'),
        ),
        FilledButton(
          onPressed: _running
              ? null
              : exported == null
              ? _export
              : () => unawaited(_open()),
          child: Text(
            _running
                ? 'Running…'
                : exported == null
                ? 'Run and export'
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

/// The same export as a command, with a way to take it.
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

/// The run's own output, as it arrives.
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

  @override
  Widget build(BuildContext context) => SelectableText(
    text,
    style: context.type.bodySmall.copyWith(color: color),
  );
}
