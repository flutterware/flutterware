import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/plugins.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/design/design.dart';
import '../ui/picker.dart';
import '../ui/theme.dart';
import 'film_encode.dart';

/// Renders one scenario as a video: what to render it at, how far along it is,
/// and where it landed.
///
/// The render arrives as a callback rather than a core, so the whole dialog —
/// every state of it — can be looked at in the catalog against a fake that
/// counts frames on a timer. `showScenarioVideoDialog` in the panel hands over
/// `ScenariosCore.renderVideo`; nothing here knows that exists.
typedef ScenarioVideoRender = Future<Artifact> Function(
  Map<String, Object?> arguments, {
  void Function(ScenarioFilmProgress progress)? onProgress,
});

/// The options a film is rendered with, as this dialog offers them.
///
/// Deliberately not every knob the action has. The device, the language and
/// the brightness are the page's own axes and are shown a foot above this
/// dialog; the pacing beats are for tuning the *look* of films in general
/// rather than for one export. What is left is what somebody exporting a clip
/// actually chooses: how big, how smooth, how heavy — and, where the scenario
/// forks, which way.
Future<void> showScenarioVideoDialog(
  BuildContext context, {
  required ScenarioVideoRender render,
  required String scenario,
  required String file,
  required String package,
  required String pluginId,
  required bool nameThePackage,
  String? device,
}) => showDialog<void>(
  context: context,
  // A render outlives a careless click outside the dialog, and this is the
  // only place its progress exists.
  barrierDismissible: false,
  builder: (context) => _VideoDialog(
    render: render,
    scenario: scenario,
    file: file,
    package: package,
    pluginId: pluginId,
    nameThePackage: nameThePackage,
    device: device,
  ),
);

/// The same render, spelled for a terminal.
///
/// A function rather than a method so a test can check the flags against the
/// ones the action declares: this string is an instruction to a user, and a
/// flag renamed on the action and not here is a command that fails when they
/// run it.
String scenarioVideoCommand({
  required String pluginId,
  required String package,
  required String file,
  required String scenario,
  required bool nameThePackage,
  ScenarioVideoOptions options = const ScenarioVideoOptions(),
  String? device,
}) => [
  'dart run flutterware run ${pluginId.split('.').last} video',
  if (nameThePackage) '--package=${_arg(package)}',
  '--file=${_arg(file)}',
  '--scenario=${_arg(scenario)}',
  for (var branch in options.branches) '--branch=${_arg(branch)}',
  if (device != null) '--device=$device',
  if (options.scale != 3) '--scale=${_number(options.scale)}',
  if (options.fps != 30) '--fps=${options.fps}',
  if (options.crf != 18) '--crf=${options.crf}',
  if (options.reel) '--reel=true',
  if (options.output.isNotEmpty) '--output=${_arg(options.output)}',
].join(' ');

String _arg(String value) => value.contains(RegExp(r'\s')) ? "'$value'" : value;

String _number(double value) =>
    value == value.roundToDouble() ? '${value.round()}' : '$value';

class _VideoDialog extends StatefulWidget {
  const _VideoDialog({
    required this.render,
    required this.scenario,
    required this.file,
    required this.package,
    required this.pluginId,
    required this.nameThePackage,
    this.device,
  });

  final ScenarioVideoRender render;
  final String scenario;
  final String file;
  final String package;
  final String pluginId;
  final bool nameThePackage;
  final String? device;

  @override
  State<_VideoDialog> createState() => _VideoDialogState();
}

class _VideoDialogState extends State<_VideoDialog> {
  var _options = const ScenarioVideoOptions();
  final _branches = TextEditingController();
  final _output = TextEditingController();

  var _running = false;
  ScenarioFilmProgress? _progress;
  Artifact? _rendered;
  String? _error;

  @override
  void initState() {
    super.initState();
    _branches.addListener(_changed);
    _output.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _branches
      ..removeListener(_changed)
      ..dispose();
    _output
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  ScenarioVideoOptions get _current => _options.copyWith(
    // One per line, never split on commas: a branch is a label an author wrote
    // in a sentence, and `pay by card, then refund` is a plausible one.
    branches: [
      for (var line in _branches.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ],
    output: _output.text.trim(),
  );

  Future<void> _render() async {
    var options = _current;
    setState(() {
      _running = true;
      _rendered = null;
      _error = null;
      _progress = null;
    });
    try {
      var artifact = await widget.render(
        {
          'package': widget.package,
          'file': widget.file,
          'scenario': widget.scenario,
          if (options.branches.isNotEmpty) 'branch': options.branches,
          if (widget.device != null) 'device': widget.device,
          'scale': '${options.scale}',
          'fps': '${options.fps}',
          'crf': '${options.crf}',
          if (options.reel) 'reel': 'true',
          if (options.output.isNotEmpty) 'output': options.output,
        },
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (mounted) setState(() => _rendered = artifact);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => ScenarioVideoDialogView(
    scenario: widget.scenario,
    device: widget.device,
    options: _current,
    branches: _branches,
    output: _output,
    onOptions: (options) => setState(() => _options = options),
    command: scenarioVideoCommand(
      pluginId: widget.pluginId,
      package: widget.package,
      file: widget.file,
      scenario: widget.scenario,
      nameThePackage: widget.nameThePackage,
      device: widget.device,
      options: _current,
    ),
    running: _running,
    progress: _progress,
    rendered: _rendered,
    error: _error,
    onRender: _render,
    onClose: () => Navigator.of(context).pop(),
    onOpen: (artifact) async {
      if (artifact.path case var path?) await launchUrl(Uri.file(path));
    },
  );
}

/// What a film is rendered with, as this dialog offers it.
class ScenarioVideoOptions {
  const ScenarioVideoOptions({
    this.scale = 3,
    this.fps = 30,
    this.crf = 18,
    this.reel = false,
    this.branches = const [],
    this.output = '',
  });

  /// Output pixels per logical pixel.
  final double scale;

  final int fps;

  /// What `libx264` aims at, lower being better and bigger.
  final int crf;

  /// Whether the film is cut as a reel — the scenario's own edit, or the
  /// stock one — rather than shown as it ran under a cursor.
  final bool reel;

  /// Which branch to take at each `split`, outermost first.
  final List<String> branches;

  /// Where the file goes, or empty for the action's own default.
  final String output;

  ScenarioVideoOptions copyWith({
    double? scale,
    int? fps,
    int? crf,
    bool? reel,
    List<String>? branches,
    String? output,
  }) => ScenarioVideoOptions(
    scale: scale ?? this.scale,
    fps: fps ?? this.fps,
    crf: crf ?? this.crf,
    reel: reel ?? this.reel,
    branches: branches ?? this.branches,
    output: output ?? this.output,
  );
}

/// The dialog itself, with nothing behind it.
///
/// Everything it knows arrives as a value and everything it does leaves as a
/// callback, which is what lets the catalog show every state it has — a render
/// that has not started, one that is preparing, one counting frames, one
/// finished, and one refused — without a harness, a scenario or an `ffmpeg`.
class ScenarioVideoDialogView extends StatelessWidget {
  const ScenarioVideoDialogView({
    super.key,
    required this.scenario,
    required this.options,
    required this.branches,
    required this.output,
    required this.onOptions,
    required this.command,
    required this.onRender,
    required this.onClose,
    required this.onOpen,
    this.device,
    this.running = false,
    this.progress,
    this.rendered,
    this.error,
  });

  final String scenario;

  /// The device the page is framed on, for the pixel size under each scale.
  final String? device;

  final ScenarioVideoOptions options;

  /// Held by the caller, because a controller allocated in a build is a field
  /// that resets on every keystroke.
  final TextEditingController branches;
  final TextEditingController output;

  final ValueChanged<ScenarioVideoOptions> onOptions;

  /// The same render, spelled for a terminal.
  final String command;

  final bool running;
  final ScenarioFilmProgress? progress;
  final Artifact? rendered;
  final String? error;

  final VoidCallback onRender;
  final VoidCallback onClose;
  final Future<void> Function(Artifact artifact) onOpen;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return AlertDialog(
      title: const Text('Render a video'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The options scroll; what the render is *doing* does not. On a
            // short window the form is taller than the dialog, and a progress
            // bar below the fold is a progress bar nobody sees.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Option(
                      'Size',
                      child: FwPicker<double>(
                        selected: options.scale,
                        onChanged: running
                            ? (_) {}
                            : (value) =>
                                  onOptions(options.copyWith(scale: value)),
                        choices: [
                          for (var scale in const [1.0, 2.0, 3.0])
                            FwChoice(
                              value: scale,
                              label: '${scale.round()}×',
                              detail: _sizeAt(scale),
                            ),
                        ],
                      ),
                    ),
                    const Gap(FwSpacing.lg),
                    _Option(
                      'Frame rate',
                      child: FwPicker<int>(
                        selected: options.fps,
                        onChanged: running
                            ? (_) {}
                            : (value) =>
                                  onOptions(options.copyWith(fps: value)),
                        choices: const [
                          FwChoice(value: 30, label: '30 fps'),
                          FwChoice(value: 60, label: '60 fps'),
                        ],
                      ),
                    ),
                    const Gap(FwSpacing.lg),
                    _Option(
                      'Cut',
                      child: FwPicker<bool>(
                        selected: options.reel,
                        onChanged: running
                            ? (_) {}
                            : (value) =>
                                  onOptions(options.copyWith(reel: value)),
                        choices: const [
                          FwChoice(
                            value: false,
                            label: 'Plain film',
                            detail: 'the app under a cursor, as it ran',
                          ),
                          FwChoice(
                            value: true,
                            label: 'Reel',
                            detail: 'push-ins, captions, a closing card',
                          ),
                        ],
                      ),
                    ),
                    const Gap(FwSpacing.lg),
                    _Option(
                      'Quality',
                      child: FwPicker<int>(
                        selected: options.crf,
                        onChanged: running
                            ? (_) {}
                            : (value) =>
                                  onOptions(options.copyWith(crf: value)),
                        choices: const [
                          FwChoice(
                            value: 16,
                            label: 'Highest',
                            detail: 'crf 16',
                          ),
                          FwChoice(value: 18, label: 'High', detail: 'crf 18'),
                          FwChoice(value: 23, label: 'Lower', detail: 'crf 23'),
                        ],
                      ),
                    ),
                    const Gap(FwSpacing.lg),
                    _Option(
                      'Branches',
                      child: TextField(
                        controller: branches,
                        enabled: !running,
                        minLines: 1,
                        maxLines: 3,
                        style: context.type.mono,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'One per split, outermost first',
                        ),
                      ),
                    ),
                    const Gap(FwSpacing.lg),
                    _Option(
                      'Write to',
                      child: TextField(
                        controller: output,
                        enabled: !running,
                        style: context.type.mono,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'build/flutterware/video/<scenario>.mp4',
                        ),
                      ),
                    ),
                    const Gap(FwSpacing.lg),
                    _CommandLine(command: command),
                  ],
                ),
              ),
            ),
            if (running || progress != null) ...[
              const Gap(FwSpacing.xl),
              _Progress(progress: progress, running: running),
            ],
            if (error case var said?) ...[
              const Gap(FwSpacing.lg),
              _Note(text: said, color: colors.red),
            ],
            if (rendered case var artifact?) ...[
              const Gap(FwSpacing.lg),
              _Note(text: _describe(artifact), color: colors.grn),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: running ? null : onClose,
          child: Text(rendered == null ? 'Cancel' : 'Close'),
        ),
        if (rendered != null)
          TextButton(
            onPressed: running ? null : onRender,
            child: const Text('Render again'),
          ),
        FilledButton(
          onPressed: running
              ? null
              : rendered == null
              ? onRender
              : () => unawaited(onOpen(rendered!)),
          child: Text(
            running
                ? 'Rendering…'
                : rendered == null
                ? 'Render'
                : 'Open',
          ),
        ),
      ],
    );
  }

  /// The pixels a scale comes out at, when the page knows which device this
  /// scenario is framed on. A film's size is the one option nobody can guess.
  String? _sizeAt(double scale) {
    var found = device == null ? null : deviceById(device!);
    if (found == null) return null;
    return '${(found.width * scale).round()} × '
        '${(found.height * scale).round()}';
  }

  String _describe(Artifact artifact) {
    var meta = artifact.meta;
    var frames = meta['frames'];
    var fps = meta['fps'];
    var seconds = frames is int && fps is int && fps > 0 ? frames / fps : null;
    return [
      artifact.path ?? '',
      if (seconds != null) '${seconds.toStringAsFixed(1)}s',
      if (meta['bytes'] case int bytes)
        '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
    ].join('  ·  ');
  }
}

/// A label above its control, which is the shape every form in this studio
/// uses at this width.
class _Option extends StatelessWidget {
  const _Option(this.label, {required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: context.type.fieldLabel),
      const Gap(FwSpacing.xs),
      child,
    ],
  );
}

/// What a render is doing, in the one number that is honest the whole way
/// through.
///
/// A frame count rather than a percentage until there is something to be a
/// percentage *of*: the length of a film is what the scenario does, and nobody
/// — including the renderer — knows it until the last beat has been drawn.
class _Progress extends StatelessWidget {
  const _Progress({required this.progress, required this.running});

  final ScenarioFilmProgress? progress;
  final bool running;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var frames = progress?.frames ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          child: LinearProgressIndicator(
            value: running ? progress?.fraction : 1,
            minHeight: 4,
            backgroundColor: colors.mut3,
          ),
        ),
        const Gap(FwSpacing.xs),
        Text(switch ((running, frames)) {
          (false, _) => '',
          // Nothing has been drawn yet: the harness is still compiling and
          // booting, which is the longest part of a cold render.
          (true, 0) => 'Preparing…',
          (true, _) =>
            '$frames'
                '${progress?.total == null ? ' frames' : ' of ${progress!.total} frames'}'
                ' · ${_seconds(progress!.filmed)}',
        }, style: context.type.caption.copyWith(color: colors.mut)),
      ],
    );
  }

  static String _seconds(Duration filmed) =>
      '${(filmed.inMilliseconds / 1000).toStringAsFixed(1)}s';
}

/// The command that does the same thing, copyable — the sibling export dialog's
/// line, for the same reason: whatever the GUI can do, a terminal and an agent
/// can do too, and this is where that is discoverable.
class _CommandLine extends StatelessWidget {
  const _CommandLine({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.panel2,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: colors.line),
      ),
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.md,
        FwSpacing.sm,
        FwSpacing.xs,
        FwSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: context.type.mono.copyWith(color: colors.mut),
              maxLines: 3,
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            iconSize: FwIconSize.md,
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                unawaited(Clipboard.setData(ClipboardData(text: command))),
            icon: const Icon(Icons.copy_all_outlined),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      SelectableText(text, style: context.type.caption.copyWith(color: color));
}
