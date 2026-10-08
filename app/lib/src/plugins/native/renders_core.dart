import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/plugins.dart';
import 'package:flutterware/render_client.dart';
// ignore: implementation_imports
import 'package:flutterware/src/render/bundle_entrypoint.dart';
import 'package:path/path.dart' as p;

import '../../embedder/flutter_cache.dart';
import '../../render_bundle/bundle_builder.dart';
import '../../session/job.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const rendersPluginId = 'flutterware.render';

const _pluginDescription =
    "The app's render points — widgets and pw.Documents bound in a "
    '@RenderRegistry() registrar — rendered as SVG, PNG or PDF: live in '
    'the studio, one-shot from the CLI, resident from a server through '
    '`fw render bundle`.';

/// The render plugin's behaviour: registrar scan, the warm guest, and the
/// render action.
///
/// The scan (does the target file declare a registrar?) is parse-budget work
/// and runs in [computeAll]. The point *list* is not: names are runtime
/// values the registrar binds, so it comes from a running guest — spawned
/// only when the panel asks, or when the `render` action is invoked by name.
class RendersCore extends PluginCore {
  RendersCore(super.host);

  /// Declared packages, filtered to those the workspace knows about.
  late final List<String> packages = [
    for (var path in host.packagePaths)
      if (host.workspace.exists(path)) path,
  ];

  final _registrars = <String, String?>{};
  var _scanned = false;

  final _lanes = <String, RenderLane>{};

  /// The registrar target for [package], as declared or the default.
  String targetFor(String package) {
    for (var config in host.packageConfigs) {
      if (config['path'] != package) continue;
      var target = config['target'];
      if (target is String && target.isNotEmpty) return target;
    }
    return 'lib/renders.dart';
  }

  String packageRootOf(String package) =>
      p.normalize(p.join(host.workspace.root, package));

  /// The name of the `@RenderRegistry()` function in [package]'s target, null
  /// when the file is missing or declares none, and absent before the scan.
  String? registrarFor(String package) => _registrars[package];

  bool get scanned => _scanned;

  void scan() {
    for (var package in packages) {
      var file = File(p.join(packageRootOf(package), targetFor(package)));
      _registrars[package] = file.existsSync()
          ? findRenderRegistrarName(file.readAsStringSync())
          : null;
    }
    _scanned = true;
    notifyChanged();
  }

  @override
  Future<void> computeAll() async {
    if (!_scanned) scan();
  }

  RenderLane laneFor(String package) =>
      _lanes.putIfAbsent(package, () => RenderLane(this, package));

  /// What the sidebar says while a lane is working.
  String? get busyPhase =>
      _lanes.values.map((lane) => lane.phase).nonNulls.firstOrNull;

  /// Renders one point through [package]'s warm guest, starting it if
  /// needed. `text` is set for svg, `bytes` for png and pdf.
  Future<({String text, Uint8List bytes, List<RenderWarning> warnings})>
  renderPoint({
    required String package,
    required String point,
    required String format,
    Map<String, Object?> args = const {},
    RenderSize? size,
    RenderOptions options = const RenderOptions(),
    double pixelRatio = 3,
  }) async {
    var pool = await laneFor(package).ensureStarted();
    var info = pool.points.where((info) => info.name == point).firstOrNull;
    if (info == null) {
      throw ActionRefusal(
        'no render point named "$point"; ${targetFor(package)} declares: '
        '${pool.points.map((info) => info.name).join(', ')}',
      );
    }
    if (info.kind == RenderPointKind.document) {
      if (format != 'pdf') {
        throw ActionRefusal(
          '"$point" is a document render, which only produces pdf',
        );
      }
      var result = await pool.pdf(_document(point), args, options: options);
      return (text: '', bytes: result.bytes, warnings: result.warnings);
    }
    if (size == null) {
      throw ActionRefusal('a widget render needs a size');
    }
    switch (format) {
      case 'svg':
        var result = await pool.svg(
          _widget(point),
          args,
          size: size,
          options: options,
        );
        return (
          text: result.text,
          bytes: Uint8List(0),
          warnings: result.warnings,
        );
      case 'png':
        var result = await pool.png(
          _widget(point),
          args,
          size: size,
          pixelRatio: pixelRatio,
        );
        return (text: '', bytes: result.bytes, warnings: result.warnings);
      case 'pdf':
        var result = await pool.pdfPage(
          _widget(point),
          args,
          size: size,
          options: options,
        );
        return (text: '', bytes: result.bytes, warnings: result.warnings);
      default:
        throw ActionRefusal('unknown format "$format"; use svg, png or pdf');
    }
  }

  @override
  PluginReport get report {
    return PluginReport(
      id: host.id,
      label: host.label,
      description: _pluginDescription,
      status: _status(),
      children: [
        for (var package in packages)
          PluginChild(
            id: package,
            label: package == '.' ? 'root' : package,
            status: _packageStatus(package),
          ),
      ],
      badge: _scanned && packages.any((p) => _registrars[p] == null)
          ? const StatusBadge.dot(Tone.error)
          : StatusBadge.none,
      actions: [
        PluginAction(
          'render',
          'Render',
          returns: Artifact,
          description:
              'Render one point to a file. A widget point takes svg, png or '
              'pdf and needs a size; a document point is always pdf. Spawns '
              'the render guest for the request.',
          parameters: [
            const ActionParameter(
              'point',
              'Point',
              description:
                  'The point name, as the registrar binds it — '
                  '`charts/monthly`. The panel and the report list them once '
                  'the guest has run.',
            ),
            const ActionParameter(
              'as',
              'Format',
              kind: ActionParameterKind.choice,
              required: false,
              defaultValue: 'svg',
              description: 'svg, png, or pdf',
              options: [
                ActionOption('svg'),
                ActionOption('png'),
                ActionOption('pdf'),
              ],
            ),
            const ActionParameter(
              'args',
              'Args',
              required: false,
              description: "A JSON object for the point's own decoder",
            ),
            const ActionParameter(
              'size',
              'Size',
              required: false,
              description:
                  '<width>x<height> in logical pixels — required for a '
                  'widget point',
            ),
            if (packages.length > 1)
              ActionParameter(
                'package',
                'Package',
                kind: ActionParameterKind.choice,
                required: false,
                description: 'Which declared package; the first when omitted',
                options: [for (var path in packages) ActionOption(path)],
              ),
            const ActionParameter(
              'text',
              'Text policy',
              kind: ActionParameterKind.choice,
              required: false,
              defaultValue: 'embedFont',
              description:
                  'What text becomes: glyph outlines, embedded fonts, or the '
                  "viewer's own",
              options: [
                ActionOption('vectorize'),
                ActionOption('embedFont'),
                ActionOption('systemFont'),
              ],
            ),
            const ActionParameter(
              'unsupported',
              'Unsupported ops',
              kind: ActionParameterKind.choice,
              required: false,
              defaultValue: 'rasterize',
              description:
                  'What an inexpressible op becomes: a raster patch, a flat '
                  'stand-in, or nothing',
              options: [
                ActionOption('rasterize'),
                ActionOption('flatten'),
                ActionOption('skip'),
              ],
            ),
            const ActionParameter(
              'output',
              'Output',
              required: false,
              description:
                  'Where to write, relative to the worktree; defaults under '
                  'build/flutterware/',
            ),
          ],
        ),
      ],
      view: _view(),
    );
  }

  Status _status() {
    if (packages.isEmpty) return Status.none;
    if (!_scanned) return Status.none;
    var missing = packages.where((p) => _registrars[p] == null).length;
    if (missing > 0) {
      return Status.error(
        missing == packages.length
            ? 'no registrar'
            : '$missing package(s) without a registrar',
      );
    }
    var points = _lanes.values
        .map((lane) => lane.pool?.points.length)
        .nonNulls
        .fold(0, (sum, n) => sum + n);
    if (points > 0) return Status.info('$points point(s), renderer running');
    return Status.none;
  }

  Status _packageStatus(String package) {
    if (!_scanned) return Status.none;
    if (_registrars[package] == null) {
      return Status.error('no @RenderRegistry() in ${targetFor(package)}');
    }
    var pool = _lanes[package]?.pool;
    if (pool != null) return Status.info('${pool.points.length} point(s)');
    return Status.none;
  }

  PluginView _view() {
    if (packages.isEmpty) {
      return const PluginView([
        ViewText(
          'This plugin has no packages. Add them in tool/flutterware.dart.',
          tone: Tone.warn,
        ),
      ]);
    }
    return PluginView([
      for (var package in packages)
        ViewSection(package, [
          ViewField('Registrar', targetFor(package)),
          if (!_scanned)
            const ViewText('not computed')
          else if (_registrars[package] == null)
            ViewText(
              'no @RenderRegistry() function in ${targetFor(package)}',
              tone: Tone.error,
            )
          else ...[
            ViewField('Function', _registrars[package]!),
            ..._pointNodes(package),
          ],
        ]),
    ]);
  }

  List<ViewNode> _pointNodes(String package) {
    var lane = _lanes[package];
    if (lane?.error case var error?) {
      return [ViewField('Error', error, tone: Tone.error)];
    }
    var pool = lane?.pool;
    if (pool == null) {
      return const [
        ViewText(
          'points are listed once the renderer runs; open the panel or '
          'invoke `render`',
        ),
      ];
    }
    return [
      ViewItems([
        for (var point in pool.points)
          ViewItem(point.name, detail: point.kind.name),
      ]),
    ];
  }

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    if (actionId != 'render') {
      return super.invoke(actionId, arguments: arguments);
    }
    return _renderAction(arguments);
  }

  Future<Artifact> _renderAction(Map<String, Object?> arguments) async {
    if (packages.isEmpty) {
      throw ActionRefusal(
        'this plugin has no packages; add them in tool/flutterware.dart',
      );
    }
    var package = arguments['package'] as String? ?? packages.first;
    if (!packages.contains(package)) {
      throw ArgumentError.value(
        package,
        'package',
        'not declared for this plugin. Declared: ${packages.join(', ')}',
      );
    }
    var point = arguments['point'];
    if (point is! String || point.isEmpty) {
      throw ArgumentError('render needs a point name');
    }
    var format = arguments['as'] as String? ?? 'svg';
    var args = switch (arguments['args']) {
      null => const <String, Object?>{},
      String s => parseRenderArgs(s),
      Map m => m.cast<String, Object?>(),
      _ => throw ArgumentError('args takes a JSON object'),
    };
    RenderSize? size;
    if (arguments['size'] case String value) {
      var parts = value.split('x');
      var width = parts.length == 2 ? double.tryParse(parts.first) : null;
      var height = parts.length == 2 ? double.tryParse(parts.last) : null;
      if (width == null || height == null) {
        throw ArgumentError.value(value, 'size', 'takes <width>x<height>');
      }
      size = RenderSize(width, height);
    }
    var options = RenderOptions(
      text:
          _enumArgument(TextPolicy.values, arguments['text'], 'text') ??
          TextPolicy.embedFont,
      unsupported:
          _enumArgument(
            UnsupportedPolicy.values,
            arguments['unsupported'],
            'unsupported',
          ) ??
          UnsupportedPolicy.rasterize,
    );

    var result = await renderPoint(
      package: package,
      point: point,
      format: format,
      args: args,
      size: size,
      options: options,
    );

    var relative =
        arguments['output'] as String? ??
        p.join(
          package == '.' ? '' : package,
          'build',
          'flutterware',
          'render_bundle',
          'out',
          '${point.replaceAll('/', '_')}.$format',
        );
    var file = File(p.join(host.workspace.root, relative));
    file.parent.createSync(recursive: true);
    if (format == 'svg') {
      file.writeAsStringSync(result.text);
    } else {
      file.writeAsBytesSync(result.bytes);
    }
    return Artifact(
      kind: switch (format) {
        'png' => Artifact.png,
        'svg' => 'image/svg+xml',
        _ => 'application/pdf',
      },
      address: Address(
        worktree: host.worktree.name,
        plugin: host.id,
        segments: [package, ...point.split('/')],
      ),
      path: relative,
      meta: {
        if (result.warnings.isNotEmpty)
          'warnings': [for (var w in result.warnings) w.message],
      },
    );
  }

  @override
  void dispose() {
    for (var lane in _lanes.values) {
      lane.dispose();
    }
    _lanes.clear();
    super.dispose();
  }
}

/// One package's road to a running guest: build the bundle, spawn the pool,
/// keep it warm. Owned by the core so the panel, `fw` and MCP share one.
class RenderLane {
  RenderLane(this.core, this.package);

  final RendersCore core;
  final String package;

  Future<RenderPool>? _starting;
  RenderPool? pool;
  String? error;
  var _disposed = false;

  /// What is happening right now — the bundle build narrates through here.
  String? phase;

  Future<RenderPool> ensureStarted() => _starting ??= _start();

  Future<RenderPool> _start() async {
    try {
      error = null;
      _say('building the render bundle');
      var packageRoot = core.packageRootOf(package);
      var bundle = p.join(
        packageRoot,
        'build',
        'flutterware',
        'render_bundle',
        'bundle',
      );
      await buildRenderBundle(
        packageRoot: packageRoot,
        target: core.targetFor(package),
        output: bundle,
        cache: FlutterCache(
          p.join(core.host.workspace.flutterSdk.root, 'bin', 'cache'),
        ),
        log: _say,
      );
      if (_disposed) {
        throw StateError('the renderer was shut down while starting');
      }
      _say('starting the renderer');
      var started = await RenderPool.start(bundle: bundle);
      if (_disposed) {
        // The worktree closed while the guest was coming up: without this,
        // dispose() ran against a null pool and the guest idled forever.
        unawaited(started.close());
        throw StateError('the renderer was shut down while starting');
      }
      pool = started;
      phase = null;
      core.notifyChanged();
      return started;
    } catch (e) {
      error = '$e';
      phase = null;
      _starting = null;
      core.notifyChanged();
      rethrow;
    }
  }

  /// Rebuilds the bundle and respawns the guest — the reload after an edit
  /// to the registrar or anything it renders. Rescans first: the edit may
  /// have renamed the registrar itself.
  Future<RenderPool> restart() async {
    core.scan();
    unawaited(pool?.close());
    pool = null;
    _starting = null;
    core.notifyChanged();
    return ensureStarted();
  }

  void _say(String line) {
    phase = line;
    core.notifyChanged();
  }

  void dispose() {
    _disposed = true;
    unawaited(pool?.close());
    pool = null;
  }
}

WidgetRender<Map<String, Object?>> _widget(String name) =>
    WidgetRender(name, encodeArgs: (args) => args, decodeArgs: (json) => json);

DocumentRender<Map<String, Object?>> _document(String name) => DocumentRender(
  name,
  encodeArgs: (args) => args,
  decodeArgs: (json) => json,
);

/// The declared-vocabulary refusal for an enum-valued action argument.
T? _enumArgument<T extends Enum>(List<T> values, Object? value, String name) {
  if (value == null) return null;
  for (var candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw ArgumentError.value(
    value,
    name,
    'not a $name policy. Accepted: ${values.map((v) => v.name).join(', ')}',
  );
}

/// Parses an args value: a JSON object as text.
Map<String, Object?> parseRenderArgs(String value) {
  var decoded = jsonDecode(value);
  if (decoded is! Map) {
    throw ArgumentError('args takes a JSON object, got: $value');
  }
  return decoded.cast<String, Object?>();
}

PluginCore rendersCoreFactory(PluginHost host) => RendersCore(host);
