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
    // The first point of the matrix to reach a step draws its boxes: a box
    // is where a key sat on one device, in one language.
    if (!record.boxes.containsKey(step.position)) {
      record.boxes[step.position] = keyBoxes(step.tester);
      record.points[step.position] = step.point;
    }
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
                'point': ?record.points[position],
                'boxes': [
                  for (var box in record.boxes[position]!)
                    [
                      box.key,
                      box.at,
                      box.rect.left,
                      box.rect.top,
                      box.rect.width,
                      box.rect.height,
                      (box.visible * 100).roundToDouble() / 100,
                    ],
                ],
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
  final boxes =
      <String, List<({String key, String at, Rect rect, double visible})>>{};
  final points = <String, String>{};
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

  _visitShown(tester, (render, _) {
    shown.add(render);
    switch (render) {
      case RenderParagraph paragraph:
        readSpan(paragraph.text, null);
      case RenderEditable editable:
        if (editable.text case var text?) readSpan(text, null);
    }
  });

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

/// Calls [onShown] with every render object on screen, and the view it is
/// in. A route under the one on top keeps its render objects, and they are
/// not visited.
void _visitShown(
  WidgetTester tester,
  void Function(RenderObject render, RenderView view) onShown,
) {
  for (var view in tester.binding.renderViews) {
    void visit(RenderObject render) {
      onShown(render, view);
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

    visit(view);
  }
}

/// One piece of text on screen: a span of a paragraph, or the text of a
/// widget registered with `indexTranslationsIn`.
class ShownText {
  ShownText(this.at, this.text, this._rect, this._visible);

  /// Where it is, in a form that names the same text on the next run of the
  /// same step: `p3.1` is the second span with text in the fourth paragraph
  /// on screen, `w0` the first registered widget. The words do not come
  /// into it, so a draft or another language leaves it unchanged.
  final String at;

  final String text;

  final Rect Function() _rect;

  final double Function(Rect rect) _visible;

  /// Where it is drawn, in the view's logical pixels.
  Rect get rect => _rect();

  /// How much of [rect] a person sees, from 0 to 1. Text is laid out where
  /// nobody can see it: scrolled out of its list, past the edge of the
  /// screen, or under a bar drawn over it.
  double get visible => _visible(rect);
}

/// Every piece of text on screen, in the order a walk of the screen meets
/// it, which is the same from one run of a step to the next.
List<ShownText> shownTexts(WidgetTester tester) {
  var texts = <ShownText>[];
  var shown = Set<RenderObject>.identity();
  var views = Map<RenderObject, RenderView>.identity();
  var paragraphs = 0;
  _visitShown(tester, (render, view) {
    shown.add(render);
    views[render] = view;
    if (render is! RenderParagraph) return;
    var paragraph = paragraphs++;
    var spans = 0;
    var offset = 0;
    void walk(InlineSpan span) {
      if (span is! TextSpan) {
        // A widget in the text takes one character's place.
        offset += 1;
        return;
      }
      if (span.text case var text?) {
        var start = offset;
        texts.add(
          ShownText('p$paragraph.${spans++}', text, () {
            var boxes = render.getBoxesForSelection(
              TextSelection(
                baseOffset: start,
                extentOffset: start + text.length,
              ),
            );
            if (boxes.isEmpty) return Rect.zero;
            return _inView(
              render,
              view,
              boxes
                  .map((box) => box.toRect())
                  .reduce((a, b) => a.expandToInclude(b)),
            );
          }, (rect) => _visibleShare(tester, render, view, rect)),
        );
        offset += text.length;
      }
      for (var child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }

    walk(render.text);
  });

  // Text a widget renders its own way: the widget's whole box.
  var widgets = 0;
  void element(Element e) {
    var render = e.renderObject;
    if (render != null && !shown.contains(render)) return;
    if (render is RenderBox && render.hasSize) {
      for (var source in TranslationIndex.sources) {
        if (source(e.widget) case var text?) {
          texts.add(
            ShownText(
              'w${widgets++}',
              text,
              () => _inView(render, views[render]!, Offset.zero & render.size),
              (rect) => _visibleShare(tester, render, views[render]!, rect),
            ),
          );
        }
      }
    }
    e.visitChildren(element);
  }

  if (tester.binding.rootElement case var root?) element(root);
  return texts;
}

/// Where each key the index can name is drawn at this step, with the
/// address it is drawn at, as `catalog/key`.
///
/// The index's half of locating a key. It runs where every string the
/// catalogs handed out is its own object, so a key is named exactly,
/// placeholders included.
List<({String key, String at, Rect rect, double visible})> keyBoxes(
  WidgetTester tester,
) => [
  for (var text in shownTexts(tester))
    if (TranslationIndex.keyOf(text.text) case var key?)
      if (text.rect case var rect when !rect.isEmpty)
        (key: '$key', at: text.at, rect: rect, visible: text.visible),
];

/// Where each of [keys] (`catalog/key`) is drawn at this step: the text at
/// each place it shows, for its [ShownText.rect] and [ShownText.visible].
///
/// [addresses] are where the index found each key at this step. They tell
/// apart two places showing the same words, and follow a key under a draft,
/// in another language and when its text was built from a placeholder. An
/// address counts only when the text there is still the key's: a page that
/// draws another screen at this step has other text at the same address. A
/// key with no such address is looked for over the whole screen.
Map<String, List<ShownText>> locateKeys(
  WidgetTester tester,
  Iterable<String> keys, {
  Map<String, List<String>> addresses = const {},
}) {
  var texts = shownTexts(tester);
  var byAddress = {for (var text in texts) text.at: text};
  var read = TranslationIndex.read;
  var found = <String, List<ShownText>>{};
  void add(String key, ShownText text) {
    if (!text.rect.isEmpty) (found[key] ??= []).add(text);
  }

  for (var key in keys) {
    var words = _wordsOf(key, read);
    for (var at in addresses[key] ?? const <String>[]) {
      if (byAddress[at] case var text? when _isKeys(text, key, words)) {
        add(key, text);
      }
    }
    if (found.containsKey(key)) continue;
    for (var text in texts) {
      if (_isKeys(text, key, words)) add(key, text);
    }
  }
  return found;
}

/// Why this step is not the screen the index recorded at [position], or null
/// when it is: it shows none of [seen], the keys the index saw there.
///
/// A page and `flutter test` draw different screens when the app reads
/// something that differs between them, such as `kIsWeb`.
String? describeOtherScreen(
  WidgetTester tester,
  String position,
  Set<String> seen,
) {
  if (seen.isEmpty) return null;
  // Read the way the index read the step, text fields included.
  if (seen.any(readShownStep(tester).keys.contains)) return null;
  var texts = shownTexts(tester);
  var read = TranslationIndex.read;
  for (var key in seen) {
    if (_wordsOf(key, read) case var words?) {
      if (texts.any((text) => text.text == words)) return null;
    }
  }
  var keys = seen.toList()..sort();
  var listed = keys.length <= 3
      ? keys.join(', ')
      : '${keys.take(3).join(', ')} and ${keys.length - 3} more';
  var missing = keys.length == 1
      ? 'the key it showed there is not on it ($listed)'
      : 'none of the ${keys.length} keys it showed there is on it ($listed)';
  return 'This is not the screen `flutter test` showed at $position: '
      '$missing. The app may read something the page has another way, such '
      'as `kIsWeb`.';
}

/// Whether [text] is [key]'s: the catalog handed it out for that key, or it
/// reads [words], the key's words now.
///
/// The words are needed besides the catalog because a web build gives a
/// string no identity of its own: two keys with the same words are one
/// string there, and the catalog names the last one read.
bool _isKeys(ShownText text, String key, String? words) =>
    TranslationIndex.keyOf(text.text)?.toString() == key ||
    (words != null && text.text == words);

/// What [key] reads now: the draft, else what the catalog answered. Null
/// for a key nothing read, or one that reads nothing.
String? _wordsOf(String key, Map<String, Map<String, String>> read) {
  var slash = key.indexOf('/');
  if (slash < 0) return null;
  var words =
      TranslationIndex.drafts[key] ??
      read[key.substring(0, slash)]?[key.substring(slash + 1)];
  return words == null || words.isEmpty ? null : words;
}

/// Points sampled across a text to measure how much of it is seen.
const _visibleColumns = 5;
const _visibleRows = 3;

/// How much of [rect], the text [render] draws, a person sees, from 0 to 1:
/// the share of points across it that are on the screen, inside every clip
/// above [render], and not under something drawn over it.
double _visibleShare(
  WidgetTester tester,
  RenderObject render,
  RenderView view,
  Rect rect,
) {
  if (rect.isEmpty) return 0;
  var clip = Offset.zero & view.size;
  var child = render;
  for (var parent = render.parent; parent != null; parent = parent.parent) {
    if (parent.describeApproximatePaintClip(child) case var own?) {
      clip = clip.intersect(_inView(parent, view, own));
    }
    child = parent;
  }
  var seen = 0;
  for (var row = 0; row < _visibleRows; row++) {
    for (var column = 0; column < _visibleColumns; column++) {
      var point = Offset(
        rect.left + rect.width * (column + .5) / _visibleColumns,
        rect.top + rect.height * (row + .5) / _visibleRows,
      );
      if (clip.contains(point) && _reaches(tester, view, render, point)) {
        seen++;
      }
    }
  }
  return seen / (_visibleRows * _visibleColumns);
}

/// Whether a tap at [point] lands on [render]: on it, on what it holds, or
/// on what holds it when it ignores pointers itself. Anything else there is
/// drawn over it, except a text field's input, which lies over its own hint
/// and draws nothing where it is empty.
bool _reaches(
  WidgetTester tester,
  RenderView view,
  RenderObject render,
  Offset point,
) {
  var result = HitTestResult();
  tester.binding.hitTestInView(result, point, view.flutterView.viewId);
  for (var entry in result.path) {
    // The deepest render object; a span of the text is not one.
    if (entry.target case RenderObject hit) {
      return identical(hit, render) ||
          _holds(hit, render) ||
          _holds(render, hit) ||
          hit is RenderEditable;
    }
  }
  return false;
}

bool _holds(RenderObject ancestor, RenderObject descendant) {
  for (var at = descendant.parent; at != null; at = at.parent) {
    if (identical(at, ancestor)) return true;
  }
  return false;
}

/// [rect], in [render]'s coordinates, in [view]'s logical pixels. The view's
/// own transform scales to physical pixels, so it is taken back out.
Rect _inView(RenderObject render, RenderView view, Rect rect) {
  var physical = MatrixUtils.transformRect(render.getTransformTo(view), rect);
  var ratio = view.configuration.devicePixelRatio;
  return Rect.fromLTRB(
    physical.left / ratio,
    physical.top / ratio,
    physical.right / ratio,
    physical.bottom / ratio,
  );
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
