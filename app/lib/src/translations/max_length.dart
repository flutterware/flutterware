/// Joining a probe baseline against its ladder of expansion passes — the
/// per-key max length, with the experiment that proved it.
///
/// Pure data, like the survey it reads: the exporter hands it the probe
/// baseline, one survey per ladder rung, and the evidence passes, and it
/// answers how long each key's text can get. No IO, so the whole join is
/// testable against runs that were never written to disk.
library;

import 'package:flutterware/translations.dart';

import 'survey.dart';

/// One ladder rung: the suite re-run with every value expanded by [level]
/// percent, captureless.
class ProbePass {
  const ProbePass({
    required this.level,
    required this.survey,
    this.failures = const [],
  });

  final int level;
  final TranslationSurvey survey;

  /// Scenarios that came back red under this expansion — the suite cannot
  /// even complete at this level, which is a break of its own rather than a
  /// broken run.
  final List<({String scenario, String failure})> failures;
}

/// What the probe proved for one key.
class KeyMaxLength {
  const KeyMaxLength({
    required this.chars,
    this.fitsText,
    this.clipsChars,
    this.clipsText,
    this.screen,
    this.clipped,
  });

  /// The longest rendered length proven to fit, in characters.
  final int chars;

  /// The literal string that was rendered and fit.
  final String? fitsText;

  /// The shortest tested length that clipped, or null — an open bound.
  final int? clipsChars;
  final String? clipsText;

  /// The constraining cell, unpadded, from the probe baseline — it has the
  /// screenshot of the box on the probe device.
  final KeySighting? screen;

  /// The clip itself, from an evidence pass: the padded string ellipsizing
  /// in place.
  final KeySighting? clipped;

  /// A real limit, as opposed to "at least [chars]".
  bool get bounded => clipsChars != null;
}

/// A screen the probe broke: a swallowed layout overflow, or a scenario that
/// went red under expansion. Screen-level by construction — every value on it
/// moved at once — so it is a percentage, not a character count.
class MaxLengthBreak {
  const MaxLengthBreak({
    required this.scenario,
    required this.level,
    this.step,
    this.stepIndex,
    this.overflows = 0,
    this.failure,
  });

  final String scenario;
  final int level;
  final String? step;
  final int? stepIndex;
  final int overflows;
  final String? failure;
}

class TranslationMaxLengths {
  const TranslationMaxLengths({
    required this.byKey,
    required this.breaks,
    required this.devices,
  });

  /// `catalog/key` to what the probe proved. A key absent here was never
  /// paired: not seen by any pass, or clipped already at the probe baseline —
  /// both fail closed into "not measured" rather than into a number.
  final Map<String, KeyMaxLength> byKey;

  final List<MaxLengthBreak> breaks;

  /// The devices the measured cells ran on, sorted — the geometry the claims
  /// are true for.
  final List<String> devices;

  int get bounded => byKey.values.where((it) => it.bounded).length;
}

/// The probe baseline's cells, indexed once — what the ladder's flip checks
/// and the final join both read.
///
/// The pairing unit is a **sighting cell** — (scenario, step *position*,
/// key). Position rather than index, deliberately: the passes this joins
/// differ in expansion and in whether they capture pixels, and both of those
/// move step *indices* — a pixel pass merges a named screen a probe pass
/// emits, and a defensive scroll takes a step only where the expanded text
/// makes the page scroll. A position is consumed either way, so cells stay
/// paired; the one flipped step exists in one pass only and honestly pairs
/// with nothing. A sighting clipped at the probe baseline is excluded (it
/// ellipsizes today by someone's choice, and the findings audit already
/// established no signal can litigate that choice); a cell a pass never
/// reached — a diverged scenario — pairs with nothing and attributes nothing.
class ProbeBaseline {
  ProbeBaseline(TranslationSurvey survey) {
    for (var sighting in survey.sightings) {
      if (sighting.offstage) continue;
      var cell = _cell(sighting);
      if (sighting.overflowed) {
        _clipped[cell] = (_clipped[cell] ?? 0) + 1;
      } else {
        (_clean[cell] ??= []).add(sighting);
      }
    }
    // The constraining pick must not depend on arrival order — same rule as
    // the representative ranking's total comparator.
    for (var sightings in _clean.values) {
      sightings.sort((a, b) {
        var start = (a.charStart ?? -1).compareTo(b.charStart ?? -1);
        return start != 0 ? start : (a.rect ?? '').compareTo(b.rect ?? '');
      });
    }
  }

  final _clean = <String, List<KeySighting>>{};
  final _clipped = <String, int>{};

  /// Every key with something to measure.
  Set<String> get measurableIds => {
    for (var sightings in _clean.values)
      for (var sighting in sightings) sighting.id,
  };

  /// The cells [pass] flipped: baseline-clean, clipped under expansion.
  ///
  /// A cell flips when the pass shows *more* clipped sightings in it than the
  /// baseline did — so a step with one designed ellipsis and one clean
  /// sibling still measures the sibling.
  Map<String, KeySighting> flippedCells(TranslationSurvey pass) {
    var clippedNow = <String, int>{};
    for (var sighting in pass.sightings) {
      if (sighting.offstage) continue;
      if (sighting.overflowed) {
        var cell = _cell(sighting);
        clippedNow[cell] = (clippedNow[cell] ?? 0) + 1;
      }
    }
    var flipped = <String, KeySighting>{};
    for (var entry in clippedNow.entries) {
      var clean = _clean[entry.key];
      if (clean == null || clean.isEmpty) continue;
      if (entry.value <= (_clipped[entry.key] ?? 0)) continue;
      flipped[entry.key] = clean.first;
    }
    return flipped;
  }
}

/// Joins the [baseline] against the ladder's [passes] and the [evidence]
/// passes, and prices every measurable key in characters.
///
/// [values] answers what each key's source text is — what the padding grew —
/// so the proven strings can be reconstructed character-for-character (the
/// padding is deterministic). For a key that substitutes, that is the
/// template value, which is approximate by construction.
TranslationMaxLengths computeMaxLengths({
  required ProbeBaseline baseline,
  required List<ProbePass> passes,
  required String? Function(String catalog, String key) values,
  List<({int level, TranslationSurvey survey})> evidence = const [],
}) {
  var sorted = passes.toList()..sort((a, b) => a.level.compareTo(b.level));

  var clipsAtLevel = <String, int>{};
  var constraining = <String, KeySighting>{};
  var observedAtLevel = <String, Set<int>>{};

  for (var pass in sorted) {
    for (var sighting in pass.survey.sightings) {
      if (sighting.offstage) continue;
      observedAtLevel.putIfAbsent(sighting.id, () => {}).add(pass.level);
    }
    for (var flipped in baseline.flippedCells(pass.survey).values) {
      var id = flipped.id;
      if (clipsAtLevel.containsKey(id)) continue; // ascending; first wins
      clipsAtLevel[id] = pass.level;
      constraining[id] = flipped;
    }
  }

  // The clip photographed: the evidence pass at the key's clipping level,
  // same cell, the clipped sighting.
  KeySighting? clippedShot(String id, int level) {
    for (var pass in evidence) {
      if (pass.level != level) continue;
      for (var sighting in pass.survey.sightings) {
        if (sighting.id != id || !sighting.overflowed) continue;
        var cell = constraining[id];
        if (cell != null &&
            sighting.scenario == cell.scenario &&
            sighting.position == cell.position) {
          return sighting;
        }
      }
    }
    return null;
  }

  String rendered(String catalog, String key, String value, int level) =>
      level == 0
      ? value
      : value +
            TranslationIndex.expansionPadding(
              catalog,
              key,
              TranslationIndex.expansionLength(value.length, level),
            );

  var measurable = baseline.measurableIds;
  var byKey = <String, KeyMaxLength>{};
  for (var entry in observedAtLevel.entries) {
    var id = entry.key;
    if (!measurable.contains(id)) continue;
    var screen = constraining[id];
    var parts = id.split('/');
    var catalog = parts.first;
    var key = parts.skip(1).join('/');
    var value = values(catalog, key);
    if (value == null || value.isEmpty) continue;

    var clips = clipsAtLevel[id];
    var below = [
      for (var level in entry.value)
        if (clips == null || level < clips) level,
    ]..sort();
    // Proven at the baseline itself when the first rung already clipped:
    // the cell was clean unpadded, so the value's own length is the bound.
    var fitsLevel = below.isEmpty ? 0 : below.last;
    var fits = rendered(catalog, key, value, fitsLevel);
    var clipsText = clips == null ? null : rendered(catalog, key, value, clips);
    byKey[id] = KeyMaxLength(
      chars: fits.length,
      fitsText: fits,
      clipsChars: clipsText?.length,
      clipsText: clipsText,
      screen: screen ?? _firstCleanFor(baseline, id),
      clipped: clips == null ? null : clippedShot(id, clips),
    );
  }

  // Screen breaks, each at the lowest level it appeared.
  var overflowBreaks = <String, MaxLengthBreak>{};
  var redBreaks = <String, MaxLengthBreak>{};
  for (var pass in sorted) {
    for (var overflow in pass.survey.screenOverflows) {
      overflowBreaks.putIfAbsent(
        // By position, not index: the same screen sits at different indices
        // on different rungs (see [ProbeBaseline]), and one break must not
        // count once per rung.
        '${overflow.scenario} ${overflow.position}',
        () => MaxLengthBreak(
          scenario: overflow.scenario,
          level: pass.level,
          step: overflow.step,
          stepIndex: overflow.stepIndex,
          overflows: overflow.count,
        ),
      );
    }
    for (var failure in pass.failures) {
      redBreaks.putIfAbsent(
        failure.scenario,
        () => MaxLengthBreak(
          scenario: failure.scenario,
          level: pass.level,
          failure: failure.failure,
        ),
      );
    }
  }
  var breaks = [...overflowBreaks.values, ...redBreaks.values]
    ..sort((a, b) {
      var scenario = a.scenario.compareTo(b.scenario);
      if (scenario != 0) return scenario;
      return (a.stepIndex ?? -1).compareTo(b.stepIndex ?? -1);
    });

  var devices = <String>{
    for (var it in byKey.values) ?it.screen?.device,
  }.toList()..sort();

  return TranslationMaxLengths(byKey: byKey, breaks: breaks, devices: devices);
}

/// The deterministic stand-in screen for a key that never clipped: its first
/// clean baseline cell, in the same total order the constraining pick uses.
KeySighting? _firstCleanFor(ProbeBaseline baseline, String id) {
  KeySighting? best;
  for (var sightings in baseline._clean.values) {
    for (var sighting in sightings) {
      if (sighting.id != id) continue;
      if (best == null || _order(sighting, best) < 0) best = sighting;
    }
  }
  return best;
}

int _order(KeySighting a, KeySighting b) {
  var scenario = a.scenario.compareTo(b.scenario);
  if (scenario != 0) return scenario;
  var step = a.stepIndex.compareTo(b.stepIndex);
  if (step != 0) return step;
  var start = (a.charStart ?? -1).compareTo(b.charStart ?? -1);
  return start != 0 ? start : (a.rect ?? '').compareTo(b.rect ?? '');
}

String _cell(KeySighting sighting) =>
    '${sighting.scenario} ${sighting.position} ${sighting.id}';
