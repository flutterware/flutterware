/// The export format, typed — written by the exporter, read by whatever
/// pushes it somewhere.
///
/// Plain Dart, and this is the point of it: a project's `tool/` script runs
/// under `dart run` with no Flutter, exactly like `tool/flutterware.dart`
/// does. Talking to a translation service is a few lines over these types, and
/// the alternative — every consumer digging through the same nested maps — is
/// the same fragile code written once per project.
///
/// This is published API. A field renamed here breaks somebody's script,
/// which is why [translationExportVersion] exists and why [TranslationExport.read]
/// refuses a major it does not know rather than handing back a half-decoded
/// object.
library;

import 'dart:convert';
import 'dart:io';

/// The format `keys.json` is written in.
///
/// Bumped only when a reader of the previous version would get something
/// wrong. Added fields do not bump it — an older reader ignoring a new key is
/// the behaviour that makes adding one cheap.
const translationExportVersion = 1;

/// The file an export's index is written to, inside its directory.
const translationExportFile = 'keys.json';

/// A box on a captured frame, **in the image's own pixels**.
///
/// Not logical pixels: the capture scale is already applied. A consumer
/// cropping, drawing, or handing this to a service that draws it should never
/// have to know what the run was captured at, and the one that has to ask is
/// the one that gets it wrong at 3x.
class ExportedRect {
  const ExportedRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  int get area => width * height;

  /// Parses the `x,y w×h` spelling the capture records.
  ///
  /// [scale] multiplies logical pixels into the image's. Null when the string
  /// is not a rect — a missing box is ordinary (a key can be recorded without
  /// one) and should not take the whole export down.
  static ExportedRect? parse(String? rect, {double scale = 1}) {
    if (rect == null) return null;
    var parts = rect.split(' ');
    if (parts.length != 2) return null;
    var origin = parts.first.split(',');
    var size = parts.last.split('×');
    if (origin.length != 2 || size.length != 2) return null;
    var x = double.tryParse(origin.first);
    var y = double.tryParse(origin.last);
    var width = double.tryParse(size.first);
    var height = double.tryParse(size.last);
    if (x == null || y == null || width == null || height == null) return null;
    return ExportedRect(
      x: (x * scale).round(),
      y: (y * scale).round(),
      width: (width * scale).round(),
      height: (height * scale).round(),
    );
  }

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  static ExportedRect? fromJson(Object? json) => switch (json) {
    Map json => ExportedRect(
      x: _int(json['x']),
      y: _int(json['y']),
      width: _int(json['width']),
      height: _int(json['height']),
    ),
    _ => null,
  };

  @override
  String toString() => '$x,$y $width×$height';
}

/// One place a key was seen, on one captured frame.
///
/// [image] is the **whole frame**, not a crop, and the same file is shared by
/// every key on it. Cropping was considered and dropped: the services this
/// feeds all take an image plus a rectangle, so a crop would mean recomputing
/// every box against it and throwing away the context the box exists to point
/// into.
class ExportedShot {
  const ExportedShot({
    required this.image,
    required this.scenario,
    required this.step,
    required this.stepIndex,
    this.rect,
    this.charStart,
    this.charEnd,
    this.locale,
    this.device,
    this.offstage = false,
    this.overflowed = false,
  });

  /// The frame, relative to the export directory. [TranslationExport.file]
  /// turns it into something openable.
  final String image;

  /// `file/name`, as a run reports a scenario.
  final String scenario;
  final String step;
  final int stepIndex;

  /// Where the words are on [image], or null when the capture recorded no box.
  final ExportedRect? rect;

  /// The span inside its paragraph, so a key sharing a `Text` with two others
  /// can still be pointed at exactly.
  final int? charStart;
  final int? charEnd;

  final String? locale;
  final String? device;

  /// Built, but not on screen — kept because "declared, reached, never shown"
  /// is a different answer from "never reached".
  final bool offstage;

  /// The words did not fit. The localisation bug, in one flag.
  final bool overflowed;

  Map<String, Object?> toJson() => {
    'image': image,
    'scenario': scenario,
    'step': step,
    'stepIndex': stepIndex,
    if (rect case var rect?) 'rect': rect.toJson(),
    if (charStart != null) 'charStart': charStart,
    if (charEnd != null) 'charEnd': charEnd,
    if (locale != null) 'locale': locale,
    if (device != null) 'device': device,
    if (offstage) 'offstage': true,
    if (overflowed) 'overflowed': true,
  };

  static ExportedShot fromJson(Map<String, Object?> json) => ExportedShot(
    image: json['image'] as String? ?? '',
    scenario: json['scenario'] as String? ?? '',
    step: json['step'] as String? ?? '',
    stepIndex: _int(json['stepIndex']),
    rect: ExportedRect.fromJson(json['rect']),
    charStart: json['charStart'] as int?,
    charEnd: json['charEnd'] as int?,
    locale: json['locale'] as String?,
    device: json['device'] as String?,
    offstage: json['offstage'] as bool? ?? false,
    overflowed: json['overflowed'] as bool? ?? false,
  );
}

/// How long one key's text can get, measured — with the experiment that
/// proved it.
///
/// [chars] is **the longest string proven to fit this key's tightest box**:
/// a padded string of exactly that length actually rendered there without
/// clipping, on [measuredOn]. Measured on the source language's screens by
/// re-running the suite with every value padded, so it is a fact about the
/// layout that holds for every locale at once.
///
/// [clipsChars] present means the bound is a real limit — a longer string was
/// rendered and clipped. Absent, the key never clipped at anything tried and
/// [chars] reads as "at least": every surface must render it that way, never
/// as a limit.
class ExportedMaxLength {
  const ExportedMaxLength({
    required this.chars,
    this.fitsText,
    this.clipsChars,
    this.clipsText,
    this.screen,
    this.clipped,
    this.measuredOn,
  });

  /// The longest length proven to fit, in characters of the rendered string.
  final int chars;

  /// The literal string that was rendered and fit — [chars] characters of it.
  final String? fitsText;

  /// The shortest tested length that clipped, or null when nothing did.
  final int? clipsChars;

  /// The literal string that was rendered and clipped.
  final String? clipsText;

  /// The constraining screen, unpadded, on the probe device — where the box
  /// whose limit this is lives.
  final ExportedShot? screen;

  /// The clip itself, photographed: the padded string ellipsizing in place.
  /// Only present when the probe captured evidence, and only for real limits.
  final ExportedShot? clipped;

  /// The device the claim is true for. A max length without its geometry is
  /// an opinion.
  final String? measuredOn;

  /// Whether this is a real limit rather than an open bound.
  bool get bounded => clipsChars != null;

  Map<String, Object?> toJson() => {
    'chars': chars,
    if (fitsText case var text?) 'fits': {'text': text, 'chars': chars},
    if (clipsChars case var clips?)
      'clips': {'text': ?clipsText, 'chars': clips},
    if (screen case var screen?) 'screen': screen.toJson(),
    if (clipped case var clipped?) 'clipped': clipped.toJson(),
    'measuredOn': ?measuredOn,
  };

  static ExportedMaxLength fromJson(Map<String, Object?> json) {
    ExportedShot? shot(Object? value) => switch (value) {
      Map shot => ExportedShot.fromJson(shot.cast<String, Object?>()),
      _ => null,
    };
    var fits = switch (json['fits']) {
      Map fits => fits.cast<String, Object?>(),
      _ => const <String, Object?>{},
    };
    var clips = switch (json['clips']) {
      Map clips => clips.cast<String, Object?>(),
      _ => null,
    };
    return ExportedMaxLength(
      chars: _int(json['chars']),
      fitsText: fits['text'] as String?,
      clipsChars: clips == null ? null : _int(clips['chars']),
      clipsText: clips?['text'] as String?,
      screen: shot(json['screen']),
      clipped: shot(json['clipped']),
      measuredOn: json['measuredOn'] as String?,
    );
  }
}

/// One key, everything the run learned about it.
class ExportedKey {
  const ExportedKey({
    required this.catalog,
    required this.key,
    this.values = const {},
    this.representative,
    this.occurrences = const [],
    this.maxLength,
  });

  final String catalog;
  final String key;

  /// `catalog/key` — what a service knows the string as, and how
  /// [TranslationExport.operator []] addresses it.
  String get id => '$catalog/$key';

  /// What the catalog files say, per locale.
  final Map<String, String> values;

  /// The one shot worth showing a translator, or null when the key was
  /// declared and never seen. Ranked, not first-found — see the design.
  final ExportedShot? representative;

  /// Everywhere else it was seen, [representative] included.
  final List<ExportedShot> occurrences;

  /// What the max-length probe measured, when one ran and saw this key.
  final ExportedMaxLength? maxLength;

  Map<String, Object?> toJson() => {
    'catalog': catalog,
    'key': key,
    if (values.isNotEmpty) 'values': values,
    if (representative case var shot?) 'representative': shot.toJson(),
    if (occurrences.isNotEmpty)
      'occurrences': [for (var shot in occurrences) shot.toJson()],
    if (maxLength case var maxLength?) 'maxLength': maxLength.toJson(),
  };

  static ExportedKey fromJson(Map<String, Object?> json) => ExportedKey(
    catalog: json['catalog'] as String? ?? '',
    key: json['key'] as String? ?? '',
    values: _strings(json['values']),
    representative: switch (json['representative']) {
      Map shot => ExportedShot.fromJson(shot.cast<String, Object?>()),
      _ => null,
    },
    occurrences: [
      for (var shot in json['occurrences'] as List? ?? const [])
        if (shot is Map) ExportedShot.fromJson(shot.cast<String, Object?>()),
    ],
    maxLength: switch (json['maxLength']) {
      Map block => ExportedMaxLength.fromJson(block.cast<String, Object?>()),
      _ => null,
    },
  );
}

/// A declared catalog, as the export found it.
class ExportedCatalog {
  const ExportedCatalog({
    required this.name,
    required this.template,
    this.locales = const [],
    this.keys = 0,
  });

  final String name;

  /// The locale the source text is written in.
  final String template;

  final List<String> locales;

  /// How many keys the files define — the denominator behind
  /// [ExportFindings.notReached].
  final int keys;

  Map<String, Object?> toJson() => {
    'name': name,
    'template': template,
    'locales': locales,
    'keys': keys,
  };

  static ExportedCatalog fromJson(Map<String, Object?> json) => ExportedCatalog(
    name: json['name'] as String? ?? '',
    template: json['template'] as String? ?? 'en',
    locales: [
      for (var locale in json['locales'] as List? ?? const [])
        if (locale is String) locale,
    ],
    keys: _int(json['keys']),
  );
}

/// A key whose rendered words were not what its locale's file says.
class ExportedLocaleFinding {
  const ExportedLocaleFinding({
    required this.catalog,
    required this.key,
    required this.locale,
    required this.rendered,
    this.expected,
  });

  final String catalog;
  final String key;
  final String locale;

  /// What the app actually put on screen.
  final String rendered;

  /// What the files say it should have been, or null when they say nothing —
  /// which is what makes this a fallback rather than a disagreement.
  final String? expected;

  Map<String, Object?> toJson() => {
    'catalog': catalog,
    'key': key,
    'locale': locale,
    'rendered': rendered,
    if (expected != null) 'expected': expected,
  };

  static ExportedLocaleFinding fromJson(Map<String, Object?> json) =>
      ExportedLocaleFinding(
        catalog: json['catalog'] as String? ?? '',
        key: json['key'] as String? ?? '',
        locale: json['locale'] as String? ?? '',
        rendered: json['rendered'] as String? ?? '',
        expected: json['expected'] as String?,
      );
}

/// A key named by one of the two coverage lists.
class ExportedKeyRef {
  const ExportedKeyRef({required this.catalog, required this.key});

  final String catalog;
  final String key;

  String get id => '$catalog/$key';

  Map<String, Object?> toJson() => {'catalog': catalog, 'key': key};

  static ExportedKeyRef fromJson(Map<String, Object?> json) => ExportedKeyRef(
    catalog: json['catalog'] as String? ?? '',
    key: json['key'] as String? ?? '',
  );
}

/// Words on a screen that belonged to no catalog.
class ExportedUnkeyed {
  const ExportedUnkeyed({
    required this.text,
    required this.scenario,
    required this.step,
    this.source,
    this.locale,
  });

  final String text;
  final String scenario;
  final String step;

  /// `home.dart:42:7` — where the widget was built, which is what turns this
  /// from a list into somewhere to go.
  final String? source;

  final String? locale;

  Map<String, Object?> toJson() => {
    'text': text,
    'scenario': scenario,
    'step': step,
    if (source != null) 'source': source,
    if (locale != null) 'locale': locale,
  };

  static ExportedUnkeyed fromJson(Map<String, Object?> json) => ExportedUnkeyed(
    text: json['text'] as String? ?? '',
    scenario: json['scenario'] as String? ?? '',
    step: json['step'] as String? ?? '',
    source: json['source'] as String?,
    locale: json['locale'] as String?,
  );
}

/// A screen a max-length probe broke — a fact about the app, not about any one
/// string, because under batch expansion every value on it moved at once.
class ExportedExpansionBreak {
  const ExportedExpansionBreak({
    required this.scenario,
    required this.level,
    this.step,
    this.stepIndex,
    this.overflows = 0,
    this.failure,
  });

  /// `file/name`, as a run reports a scenario.
  final String scenario;

  /// The lowest probed level at which it broke.
  final int level;

  /// The step it broke on, when the break was a layout overflow the probe
  /// swallowed. Absent when the whole scenario went red instead.
  final String? step;
  final int? stepIndex;

  /// Layout overflow errors on that step, at [level].
  final int overflows;

  /// Set when the scenario itself failed under expansion — the suite cannot
  /// even complete at this level, which is the strongest break there is.
  final String? failure;

  Map<String, Object?> toJson() => {
    'scenario': scenario,
    'level': level,
    if (step != null) 'step': step,
    if (stepIndex != null) 'stepIndex': stepIndex,
    if (overflows > 0) 'overflows': overflows,
    if (failure != null) 'failure': failure,
  };

  static ExportedExpansionBreak fromJson(Map<String, Object?> json) =>
      ExportedExpansionBreak(
        scenario: json['scenario'] as String? ?? '',
        level: _int(json['level']),
        step: json['step'] as String?,
        stepIndex: json['stepIndex'] as int?,
        overflows: _int(json['overflows']),
        failure: json['failure'] as String?,
      );
}

/// Everything the export noticed that is worth acting on.
///
/// Findings, deliberately not failures: a run that produced them is still a
/// good export, and the reason to look at it.
class ExportFindings {
  const ExportFindings({
    this.fallingBack = const [],
    this.disagrees = const [],
    this.notReached = const [],
    this.absentFromCatalog = const [],
    this.overflowing = const [],
    this.unkeyed = const [],
    this.expansionBreaks = const [],
  });

  /// Every place the app showed the source language to a reader who asked for
  /// another one. The most valuable list here.
  final List<ExportedLocaleFinding> fallingBack;

  /// The files and what ran disagree — a stale build, or a value overridden
  /// somewhere the files do not know about.
  final List<ExportedLocaleFinding> disagrees;

  /// Declared, and this run never asked for it. **A statement about the
  /// suite's coverage as much as the product's** — never call it unused.
  final List<ExportedKeyRef> notReached;

  /// Read, and no declared catalog defines it.
  final List<ExportedKeyRef> absentFromCatalog;

  final List<ExportedShot> overflowing;

  final List<ExportedUnkeyed> unkeyed;

  /// Screens the max-length probe broke, lowest breaking level each. Empty when
  /// no probe ran — absence of a probe is not evidence of room.
  final List<ExportedExpansionBreak> expansionBreaks;

  bool get isEmpty =>
      fallingBack.isEmpty &&
      disagrees.isEmpty &&
      notReached.isEmpty &&
      absentFromCatalog.isEmpty &&
      overflowing.isEmpty &&
      unkeyed.isEmpty &&
      expansionBreaks.isEmpty;

  Map<String, Object?> toJson() => {
    'fallingBack': [for (var it in fallingBack) it.toJson()],
    'disagrees': [for (var it in disagrees) it.toJson()],
    'notReached': [for (var it in notReached) it.toJson()],
    'absentFromCatalog': [for (var it in absentFromCatalog) it.toJson()],
    'overflowing': [for (var it in overflowing) it.toJson()],
    'unkeyed': [for (var it in unkeyed) it.toJson()],
    if (expansionBreaks.isNotEmpty)
      'expansionBreaks': [for (var it in expansionBreaks) it.toJson()],
  };

  static ExportFindings fromJson(Map<String, Object?> json) => ExportFindings(
    fallingBack: _list(json['fallingBack'], ExportedLocaleFinding.fromJson),
    disagrees: _list(json['disagrees'], ExportedLocaleFinding.fromJson),
    notReached: _list(json['notReached'], ExportedKeyRef.fromJson),
    absentFromCatalog: _list(
      json['absentFromCatalog'],
      ExportedKeyRef.fromJson,
    ),
    overflowing: _list(json['overflowing'], ExportedShot.fromJson),
    unkeyed: _list(json['unkeyed'], ExportedUnkeyed.fromJson),
    expansionBreaks: _list(
      json['expansionBreaks'],
      ExportedExpansionBreak.fromJson,
    ),
  );
}

/// A written export, read back.
///
/// ```dart
/// var export = await TranslationExport.read('build/translations');
/// for (var key in export.keys) {
///   var shot = key.representative;
///   if (shot == null) continue;
///   await service.attach(export.file(shot.image), key.id, shot.rect);
/// }
/// ```
class TranslationExport {
  const TranslationExport({
    this.version = translationExportVersion,
    this.directory = '.',
    this.catalogs = const [],
    this.keys = const [],
    this.findings = const ExportFindings(),
    this.measuredMaxLengths = false,
    this.maxLengthDevices = const [],
  });

  final int version;

  /// Whether a max-length probe ran at all. False is "not measured", which a
  /// reader must keep distinguishable from "measured and roomy" — absence of
  /// a probe is not evidence of room.
  final bool measuredMaxLengths;

  /// The devices the probe measured on, sorted — the geometry every
  /// [ExportedMaxLength.measuredOn] refers to.
  final List<String> maxLengthDevices;

  /// Where it was read from — what [file] resolves against. Not serialized:
  /// an export is movable, and a path baked into it would survive the move and
  /// be wrong.
  final String directory;

  final List<ExportedCatalog> catalogs;

  /// Every key, most-seen first, then declared-but-unseen.
  final List<ExportedKey> keys;

  final ExportFindings findings;

  /// The key with this `catalog/key` id, or null.
  ///
  /// Indexed on the first lookup, because the reader's whole job is a join:
  /// every caller walks its own catalog and probes this once per key. A scan
  /// made that quadratic, and quietly: the panel's table cost 5ms a rebuild
  /// before an export existed and 324ms after one, at 2000 keys — and the
  /// studio rebuilds it whenever any plugin says anything at all.
  ExportedKey? operator [](String id) => _indexOf(this)[id];

  /// Every key that was actually seen on a screen.
  Iterable<ExportedKey> get seen =>
      keys.where((key) => key.representative != null);

  /// Turns an export-relative path — [ExportedShot.image] — into a file.
  File file(String exportRelative) => File(
    '$directory${Platform.pathSeparator}'
    '${exportRelative.replaceAll('/', Platform.pathSeparator)}',
  );

  /// Reads the `keys.json` in [directory].
  ///
  /// Throws [FormatException] when the directory holds no export, or holds one
  /// this version cannot read. Both name what was found and what was expected,
  /// since the reader is usually looking at build output from elsewhere.
  static Future<TranslationExport> read(String directory) async {
    var file = File(
      '$directory${Platform.pathSeparator}$translationExportFile',
    );
    if (!file.existsSync()) {
      throw FormatException(
        'No $translationExportFile in "$directory". '
        'Run the translations export first.',
      );
    }
    return fromJson(switch (jsonDecode(await file.readAsString())) {
      Map json => json.cast<String, Object?>(),
      var other => throw FormatException(
        '${file.path} is ${other.runtimeType}, not an object.',
      ),
    }, directory: directory);
  }

  /// Decodes an already-parsed `keys.json`.
  ///
  /// [directory] is what [file] will resolve shots against; the default only
  /// suits a caller that will not open one.
  static TranslationExport fromJson(
    Map<String, Object?> json, {
    String directory = '.',
  }) {
    var version = _int(json['version']);
    if (version > translationExportVersion) {
      throw FormatException(
        'This export is version $version and this is a reader for '
        '$translationExportVersion. Upgrade the flutterware dependency of '
        'whatever reads it.',
      );
    }
    return TranslationExport(
      version: version,
      directory: directory,
      catalogs: _list(json['catalogs'], ExportedCatalog.fromJson),
      keys: _list(json['keys'], ExportedKey.fromJson),
      findings: switch (json['findings']) {
        Map findings => ExportFindings.fromJson(
          findings.cast<String, Object?>(),
        ),
        _ => const ExportFindings(),
      },
      measuredMaxLengths: json['maxLengths'] is Map,
      maxLengthDevices: switch (json['maxLengths']) {
        Map block => [
          for (var device in block['devices'] as List? ?? const [])
            if (device is String) device,
        ],
        _ => const [],
      },
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    if (measuredMaxLengths) 'maxLengths': {'devices': maxLengthDevices},
    'catalogs': [for (var it in catalogs) it.toJson()],
    'keys': [for (var it in keys) it.toJson()],
    'findings': findings.toJson(),
  };
}

int _int(Object? value) => switch (value) {
  int value => value,
  num value => value.round(),
  String value => int.tryParse(value) ?? 0,
  _ => 0,
};

Map<String, String> _strings(Object? value) => switch (value) {
  Map value => {
    for (var entry in value.entries)
      if (entry.value is String) '${entry.key}': entry.value as String,
  },
  _ => const {},
};

List<T> _list<T>(Object? value, T Function(Map<String, Object?>) decode) => [
  for (var entry in value as List? ?? const [])
    if (entry is Map) decode(entry.cast<String, Object?>()),
];

/// One `catalog/key` → key map per export, built on the first lookup.
///
/// An [Expando] rather than a field: the constructor is `const` and staying
/// that way is worth more than the field would be. First-wins, like the scan
/// it replaced — a duplicate id is a malformed export, and the two spellings
/// must not disagree about which key it names.
Map<String, ExportedKey> _indexOf(TranslationExport export) {
  var index = _indexes[export];
  if (index != null) return index;
  index = <String, ExportedKey>{};
  for (var key in export.keys) {
    index.putIfAbsent(key.id, () => key);
  }
  _indexes[export] = index;
  return index;
}

final _indexes = Expando<Map<String, ExportedKey>>('TranslationExport index');
