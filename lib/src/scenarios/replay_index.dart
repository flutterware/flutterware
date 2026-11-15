import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../environment.dart';
import '../translations/index.dart';
import 'asset_bundle.dart';
import 'replay_hooks.dart';

/// Where a `flutter test` run writes the replay index: the `fw.replay.index`
/// define, else the `FW_REPLAY_INDEX` variable, else nowhere.
String? get replayIndexDirectory {
  if (isWeb) return null;
  const define = String.fromEnvironment('fw.replay.index');
  if (define.isNotEmpty) return define;
  var env = processEnvironment['FW_REPLAY_INDEX'];
  return env == null || env.isEmpty ? null : env;
}

/// The asset a web build reads where the VM reads `AssetManifest.bin`.
const _webAssetManifest = 'AssetManifest.bin.json';

/// Records, for the scenario replay, what each step shows and what each
/// scenario reads, and writes it into [directory] when the file's tests end.
///
/// It runs under a plain `flutter test` on the VM and never in the page: a
/// string compiled for the web has no identity of its own, so two keys with
/// the same words could not be told apart there.
///
/// One file per test process, named after the test file. `fw` merges them.
class ReplayIndexRecorder {
  ReplayIndexRecorder(this.directory);

  final String directory;

  final _scenarios = <String, _ScenarioRecord>{};

  /// Reads made while no scenario was running: the page loads these before
  /// every replay.
  final _common = <String>{};

  final _fonts = <String>{};
  final _faces = <String>{};

  String? _running;

  /// Installs the hooks. Called by `runScenarios` while it declares, so the
  /// write can be registered as a `tearDownAll`.
  void arm() {
    scenarioDeclarationHook = (name, description, point) {
      _scenarios.putIfAbsent(
        description,
        () => _ScenarioRecord(_declaringFile(StackTrace.current)),
      );
    };
    scenarioRunningHook = (description) {
      _running = description;
      if (description != null) _listenToAssetChannel();
    };
    scenarioStepHook = _recordStep;
    scenarioAssetSource = _RecordingSource(_recordRead);
    tearDownAll(write);
  }

  void _recordRead(String key) {
    var into = switch (_running) {
      var running? => _scenarios[running]?.assets ?? _common,
      null => _common,
    };
    into.add(key);
    // The web reads its asset list from a file of its own.
    if (key == 'AssetManifest.bin') into.add(_webAssetManifest);
  }

  void _listenToAssetChannel() {
    var messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/assets', (message) {
      if (message != null) _recordRead(assetKeyOfMessage(message));
      return messenger.delegate.send('flutter/assets', message);
    });
  }

  void _recordStep(ScenarioStepEvent step) {
    var record = _scenarios[step.scenario] ??= _ScenarioRecord(null);
    var shown = readShownStep(step.tester);
    _fonts.addAll(shown.fonts);
    _faces.addAll(shown.faces);
    var keys = record.steps.putIfAbsent(step.position, () => <String>{});
    keys.addAll(shown.keys);
    record.verbs[step.position] ??= step.verb;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'scenarios': [
      for (var MapEntry(key: description, value: record) in _scenarios.entries)
        {
          'file': ?record.file,
          'scenario': description,
          'steps': [
            for (var MapEntry(key: position, value: keys)
                in record.steps.entries)
              {
                'position': position,
                'verb': ?record.verbs[position],
                'keys': keys.toList()..sort(),
              },
          ],
          'assets': record.assets.toList()..sort(),
        },
    ],
    'commonAssets': _common.toList()..sort(),
    'fonts': _fonts.toList()..sort(),
    'faces': _faces.toList()..sort(),
  };

  void write() {
    var files = {for (var record in _scenarios.values) ?record.file}.toList()
      ..sort();
    var name = files.isEmpty ? 'scenarios' : files.first;
    var slug = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    var out = File(p.join(directory, '$slug.$pid.json'))
      ..parent.createSync(recursive: true);
    out.writeAsStringSync(jsonEncode(toJson()));
  }

  /// The test file a scenario is declared in, relative to the package.
  static String? _declaringFile(StackTrace stack) {
    var root = Directory.current.path;
    for (var match in RegExp(
      r'(file:///[^\s)]+?\.dart)',
    ).allMatches('$stack')) {
      var path = Uri.parse(match.group(1)!).toFilePath();
      if (!p.isWithin(root, path)) continue;
      var relative = p.relative(path, from: root);
      if (p.split(relative).first == '.dart_tool') continue;
      return p.url.joinAll(p.split(relative));
    }
    return null;
  }
}

class _ScenarioRecord {
  _ScenarioRecord(this.file);

  final String? file;
  final steps = <String, Set<String>>{};
  final verbs = <String, String?>{};
  final assets = <String>{};
}

/// The asset key a `flutter/assets` message asks for.
String assetKeyOfMessage(ByteData message) =>
    Uri.decodeFull(utf8.decode(Uint8List.sublistView(message)));

/// What one step shows: the translation keys on screen, as `catalog/key`,
/// the font families its text is drawn in, and each face as
/// `family:weight`, with an `i` for italic: `Roboto:500`, `Roboto:400i`.
///
/// Only what is on screen. A route under the one on top keeps its render
/// objects, and its words are not what this step shows.
({Set<String> keys, Set<String> fonts, Set<String> faces}) readShownStep(
  WidgetTester tester,
) {
  var keys = <String>{};
  var fonts = <String>{};
  var faces = <String>{};
  var shown = Set<RenderObject>.identity();

  void addKey(String? text) {
    if (text == null) return;
    if (TranslationIndex.keyOf(text) case var found?) keys.add('$found');
  }

  void addStyle(TextStyle? style) {
    if (style == null) return;
    var family = style.fontFamily;
    if (family != null) {
      var weight = (style.fontWeight ?? FontWeight.normal).value;
      var italic = style.fontStyle == FontStyle.italic ? 'i' : '';
      faces.add('$family:$weight$italic');
    }
    fonts.addAll(style.fontFamilyFallback ?? const []);
  }

  // Each span with what it inherits: a child that names no family is drawn
  // in its parent's.
  void readSpan(InlineSpan span, TextStyle? inherited) {
    var style = inherited?.merge(span.style) ?? span.style;
    addStyle(style);
    if (span is TextSpan) {
      addKey(span.text);
      for (var child in span.children ?? const <InlineSpan>[]) {
        readSpan(child, style);
      }
    }
  }

  void visit(RenderObject render) {
    shown.add(render);
    switch (render) {
      case RenderParagraph paragraph:
        readSpan(paragraph.text, null);
      case RenderEditable editable:
        if (editable.text case var text?) readSpan(text, null);
    }
    var onScreen = Set<RenderObject>.identity();
    if (_showsAllChildren(render)) {
      render.visitChildren(onScreen.add);
    } else {
      render.visitChildrenForSemantics(onScreen.add);
    }
    render.visitChildren((child) {
      if (onScreen.contains(child)) visit(child);
    });
  }

  for (var view in tester.binding.renderViews) {
    visit(view);
  }

  // Text a widget renders its own way, read off the property the project
  // registered with `indexTranslationsIn`.
  void element(Element e) {
    var render = e.renderObject;
    if (render != null && !shown.contains(render)) return;
    for (var source in TranslationIndex.sources) {
      addKey(source(e.widget));
    }
    e.visitChildren(element);
  }

  if (tester.binding.rootElement case var root?) element(root);
  for (var face in faces) {
    fonts.add(face.substring(0, face.lastIndexOf(':')));
  }
  return (keys: keys, fonts: fonts, faces: faces);
}

/// Whether every child of [render] is painted although the semantics walk
/// skips it: excluding semantics is these classes' whole job.
bool _showsAllChildren(RenderObject render) =>
    render is RenderExcludeSemantics ||
    render is RenderIgnorePointer ||
    render is RenderAbsorbPointer ||
    render is RenderSliverIgnorePointer ||
    render is SemanticsAnnotationsMixin;

class _RecordingSource extends AssetBundle {
  _RecordingSource(this._onRead);

  final void Function(String key) _onRead;

  @override
  Future<ByteData> load(String key) {
    _onRead(key);
    return rootBundle.load(key);
  }

  @override
  Future<ui.ImmutableBuffer> loadBuffer(String key) {
    _onRead(key);
    return rootBundle.loadBuffer(key);
  }

  @override
  Future<T> loadStructuredData<T>(
    String key,
    Future<T> Function(String value) parser,
  ) async => parser(await loadString(key));
}
