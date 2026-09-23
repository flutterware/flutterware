import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/render_client.dart';

import '../../session/job.dart';
import '../../ui/action_button.dart';
import '../../ui/design/design.dart';
import '../../ui/empty_state.dart';
import '../../ui/panel_header.dart';
import '../../ui/picker.dart';
import '../native_plugin.dart';
import 'no_packages.dart';
import 'renders_core.dart';

export 'renders_core.dart' show RendersCore, rendersPluginId;

/// The GUI half of the render plugin: pick a point, give it args and a size,
/// look at it, export it. Everything it decides lives in [RendersCore]; the
/// preview is the camera lane (PNG from the same guest a server would run),
/// and the exports are the deliverables.
class RendersPlugin extends NativePlugin<RendersCore> {
  RendersPlugin(super.core);

  @override
  String? get busyWith => core.busyPhase;

  @override
  Widget buildPanel(BuildContext context) => _RendersPanel(this);
}

class _RendersPanel extends StatefulWidget {
  const _RendersPanel(this.plugin);

  final RendersPlugin plugin;

  @override
  State<_RendersPanel> createState() => _RendersPanelState();
}

class _RendersPanelState extends State<_RendersPanel> {
  RendersCore get _core => widget.plugin.core;

  StreamSubscription<int>? _changes;
  String? _point;
  final _args = TextEditingController(text: '{}');
  final _width = TextEditingController(text: '400');
  final _height = TextEditingController(text: '300');
  var _text = TextPolicy.embedFont;
  var _unsupported = UnsupportedPolicy.rasterize;

  ui.Image? _preview;
  int _previewBytes = 0;
  var _isDocument = false;
  List<RenderWarning> _warnings = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _changes = _core.changes.stream.listen((_) {
      if (mounted) setState(() {});
    });
    // Every open rescans: it reads one small file, and a registrar written
    // since the last look must not leave the panel saying "no registrar".
    _core.scan();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _args.dispose();
    _width.dispose();
    _height.dispose();
    _preview?.dispose();
    super.dispose();
  }

  String? get _package => _core.packages.firstOrNull;

  RenderOptions get _options =>
      RenderOptions(text: _text, unsupported: _unsupported);

  RenderSize? get _size {
    var width = double.tryParse(_width.text);
    var height = double.tryParse(_height.text);
    if (width == null || height == null) return null;
    return RenderSize(width, height);
  }

  Future<void> _render() async {
    var package = _package!;
    var point = _point!;
    var lane = _core.laneFor(package);
    var pool = await lane.ensureStarted();
    var info = pool.points.where((info) => info.name == point).firstOrNull;
    if (info == null) return;
    var isDocument = info.kind == RenderPointKind.document;
    try {
      setState(() => _error = null);
      var args = parseRenderArgs(_args.text);
      var result = await _core.renderPoint(
        package: package,
        point: point,
        format: isDocument ? 'pdf' : 'png',
        args: args,
        size: isDocument ? null : _requireSize(),
        options: _options,
        pixelRatio: 2,
      );
      ui.Image? image;
      if (!isDocument) {
        image = await decodeImageFromList(result.bytes);
      }
      if (!mounted) {
        image?.dispose();
        return;
      }
      setState(() {
        _preview?.dispose();
        _preview = image;
        _previewBytes = result.bytes.length;
        _isDocument = isDocument;
        _warnings = result.warnings;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
      rethrow;
    }
  }

  RenderSize _requireSize() {
    var size = _size;
    if (size == null) {
      throw ActionRefusal('size takes numbers, as 400 x 300');
    }
    return size;
  }

  Future<void> _export(String format) async {
    var package = _package!;
    var point = _point!;
    var pool = await _core.laneFor(package).ensureStarted();
    var info = pool.points.where((info) => info.name == point).firstOrNull;
    if (info == null) return;
    var isDocument = info.kind == RenderPointKind.document;
    var effective = isDocument ? 'pdf' : format;
    var result = await _core.renderPoint(
      package: package,
      point: point,
      format: effective,
      args: parseRenderArgs(_args.text),
      size: isDocument ? null : _requireSize(),
      options: _options,
    );
    var location = await getSaveLocation(
      suggestedName: '${point.split('/').last}.$effective',
      acceptedTypeGroups: [
        XTypeGroup(label: effective.toUpperCase(), extensions: [effective]),
      ],
    );
    // Backing out of the picker is backing out of the export.
    if (location == null) return;
    if (effective == 'svg') {
      // utf8, never codeUnits: UTF-16 units truncated to bytes corrupt any
      // non-ASCII text in the document.
      await XFile.fromData(
        utf8.encode(result.text),
        mimeType: 'image/svg+xml',
      ).saveTo(location.path);
    } else {
      await XFile.fromData(result.bytes).saveTo(location.path);
    }
    if (mounted) setState(() => _warnings = result.warnings);
  }

  @override
  Widget build(BuildContext context) {
    var package = _package;
    if (package == null) {
      return const NoPackagesConfigured(icon: Icons.picture_as_pdf_outlined);
    }
    var registrar = _core.registrarFor(package);
    var target = _core.targetFor(package);
    var lane = _core.laneFor(package);
    var points = lane.pool?.points ?? const <RenderPointInfo>[];
    if (_point == null || points.every((info) => info.name != _point)) {
      _point = points.firstOrNull?.name;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwPanelHeader(
          'Render',
          subtitle: [target, ?registrar],
          selectableSubtitle: true,
          trailing: FwActionButton(
            label: lane.pool == null ? 'Start' : 'Rebuild & restart',
            tooltip:
                'Compile the registrar and run it on flutter_tester — the '
                'same guest a server gets from `fw render bundle`',
            primary: lane.pool == null,
            onPressed: registrar == null
                ? null
                : () async {
                    await (lane.pool == null
                        ? lane.ensureStarted()
                        : lane.restart());
                  },
          ),
        ),
        Expanded(
          child: _core.scanned && registrar == null
              ? EmptyState(
                  icon: Icons.picture_as_pdf_outlined,
                  title: 'No registrar',
                  message:
                      '$target declares no @RenderRegistry() function.\n'
                      'Bind your render points there:\n\n'
                      '@RenderRegistry()\n'
                      'void registerRenders(RenderHost host) { … }',
                  selectableMessage: true,
                  action: FwActionButton(
                    label: 'Rescan',
                    onPressed: () async => _core.scan(),
                  ),
                )
              : lane.pool == null
              ? EmptyState(
                  icon: Icons.picture_as_pdf_outlined,
                  title: lane.phase ?? 'The render guest is not running',
                  message:
                      lane.error ??
                      (lane.phase == null
                          ? 'Points are announced by the running registrar. '
                                'Start compiles it once; renders after that '
                                'are instant.'
                          : null),
                  selectableMessage: lane.error != null,
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 230, child: _pointList(points)),
                    const VerticalDivider(width: 1),
                    Expanded(child: _workbench()),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _pointList(List<RenderPointInfo> points) {
    var colors = context.colors;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
      children: [
        for (var info in points)
          InkWell(
            onTap: () => setState(() {
              _point = info.name;
              _preview?.dispose();
              _preview = null;
              _warnings = const [];
              _error = null;
            }),
            child: Container(
              color: info.name == _point ? colors.accentSoft : null,
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.lg,
                vertical: FwSpacing.md,
              ),
              child: Row(
                children: [
                  Icon(
                    info.kind == RenderPointKind.document
                        ? Icons.description_outlined
                        : Icons.widgets_outlined,
                    size: 16,
                    color: colors.mut,
                  ),
                  const Gap(FwSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.name,
                          style: context.type.body,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          info.kind.name,
                          style: context.type.caption.copyWith(
                            color: colors.mut,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _workbench() {
    var point = _point;
    if (point == null) {
      return const EmptyState(
        icon: Icons.widgets_outlined,
        title: 'No render points',
        message: 'The registrar bound nothing.',
      );
    }
    var isDocument =
        _core
            .laneFor(_package!)
            .pool
            ?.points
            .where((info) => info.name == point)
            .firstOrNull
            ?.kind ==
        RenderPointKind.document;
    var colors = context.colors;
    return ListView(
      padding: const EdgeInsets.all(FwSpacing.lg),
      children: [
        _field(
          'Args',
          TextField(
            controller: _args,
            maxLines: 3,
            minLines: 1,
            style: context.type.mono,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '{"title": "…"}',
            ),
          ),
        ),
        if (!isDocument) ...[
          const Gap(FwSpacing.md),
          _field(
            'Size',
            Row(
              children: [
                SizedBox(width: 90, child: _numberField(_width)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
                  child: Text('×', style: context.type.caption),
                ),
                SizedBox(width: 90, child: _numberField(_height)),
              ],
            ),
          ),
        ],
        const Gap(FwSpacing.md),
        _field(
          'Text',
          _dropdown<TextPolicy>(
            value: _text,
            values: TextPolicy.values,
            onChanged: (value) => setState(() => _text = value),
          ),
        ),
        const Gap(FwSpacing.md),
        _field(
          'Unsupported',
          _dropdown<UnsupportedPolicy>(
            value: _unsupported,
            values: UnsupportedPolicy.values,
            onChanged: (value) => setState(() => _unsupported = value),
          ),
        ),
        const Gap(FwSpacing.lg),
        Row(
          children: [
            FwActionButton(label: 'Render', primary: true, onPressed: _render),
            const Gap(FwSpacing.md),
            if (!isDocument) ...[
              FwActionButton(
                label: 'Save SVG…',
                onPressed: () => _export('svg'),
              ),
              const Gap(FwSpacing.sm),
              FwActionButton(
                label: 'Save PNG…',
                onPressed: () => _export('png'),
              ),
              const Gap(FwSpacing.sm),
            ],
            FwActionButton(label: 'Save PDF…', onPressed: () => _export('pdf')),
          ],
        ),
        const Gap(FwSpacing.lg),
        if (_error != null)
          Text(_error!, style: context.type.caption.copyWith(color: colors.red))
        else if (_preview != null)
          Align(
            alignment: Alignment.topLeft,
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: colors.line)),
              child: RawImage(image: _preview, scale: 2, fit: BoxFit.scaleDown),
            ),
          )
        else if (_isDocument && _previewBytes > 0)
          Text(
            'PDF rendered: ${(_previewBytes / 1024).toStringAsFixed(1)} KB — '
            'Save PDF… to look at it.',
            style: context.type.caption,
          ),
        if (_warnings.isNotEmpty) ...[
          const Gap(FwSpacing.md),
          for (var warning in _warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: FwSpacing.xs),
              child: Text(
                '⚠ $warning',
                style: context.type.caption.copyWith(color: colors.amber),
              ),
            ),
        ],
      ],
    );
  }

  Widget _field(String label, Widget control) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(label, style: context.type.caption),
          ),
        ),
        Expanded(child: control),
      ],
    );
  }

  Widget _numberField(TextEditingController controller) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    style: context.type.body,
    decoration: const InputDecoration(isDense: true),
  );

  Widget _dropdown<T extends Enum>({
    required T value,
    required List<T> values,
    required void Function(T value) onChanged,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: FwPicker<T>(
          choices: [
            for (var option in values)
              FwChoice(value: option, label: option.name),
          ],
          selected: value,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
