import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'handle.dart';
import 'run_files.dart';

/// The story of a run: every tool step appended to one file beside the
/// handle, in the run dir — same files-not-memory rule, same payoff. The GUI
/// renders it as a step strip, an agent reads it to remember what its own
/// previous hops did (a CLI invocation is a fresh process), and a human
/// reviews what the AI clicked while they were not looking.
///
/// Tool steps — acts, reloads, restarts — plus the human's taps between
/// them: the guest records pointer-ups (`HumanActions`), they ride the next
/// act reply as a since-last-step delta, and land here as `actor: human`
/// entries ahead of the step that carried them. No screenshot on those; the
/// step that follows photographs the screen they produced.
class JournalEntry {
  JournalEntry({
    required this.at,
    required this.verb,
    this.actor,
    this.target,
    this.error,
    this.failure,
    this.attempts,
    this.elapsedMs,
    this.settled,
    this.settleMs,
    this.lifecycle,
    this.capture,
    this.reported,
    this.screenshot,
    this.tree,
    this.texts,
    this.semantics,
    this.logLines,
    this.errorCount,
    this.layer,
    this.reconciled,
    this.device,
    this.rotated = false,
  });

  factory JournalEntry.fromJson(Map<String, Object?> json) => JournalEntry(
    at: json['at'] as String? ?? '',
    verb: json['verb'] as String? ?? '',
    actor: json['actor'] as String?,
    target: json['target'] as String?,
    error: json['error'] as String?,
    failure: json['failure'] as String?,
    attempts: json['attempts'] as int?,
    elapsedMs: json['elapsedMs'] as int?,
    settled: json['settled'] as bool?,
    settleMs: json['settleMs'] as int?,
    lifecycle: json['lifecycle'] as String?,
    capture: json['capture'] as String?,
    reported: switch (json['reported']) {
      List reported => [for (var what in reported) '$what'],
      _ => null,
    },
    screenshot: json['screenshot'] as String?,
    tree: json['tree'] as String?,
    texts: json['texts'] as String?,
    semantics: json['semantics'] as String?,
    logLines: json['logLines'] as int?,
    errorCount: json['errorCount'] as int?,
    layer: json['layer'] as String?,
    reconciled: json['reconciled'] as int?,
    device: switch (json['device']) {
      Map device => device.cast<String, Object?>(),
      _ => null,
    },
    rotated: json['rotated'] as bool? ?? false,
  );

  /// ISO-8601, UTC. Entries order by file position; this is for reading.
  final String at;

  /// A drive verb, `reload` / `restart` / `stop` / `launch`, or `set` for a
  /// write to the device the app is running on.
  final String verb;

  /// Who acted — `agent`, `human`, `device`, or absent when the surface did not
  /// say.
  final String? actor;

  final String? target;

  /// The refusal, when the verb was refused. A journal that only kept
  /// successes would read as a cleaner session than anyone had.
  final String? error;

  final String? failure;
  final int? attempts;
  final int? elapsedMs;
  final bool? settled;
  final int? settleMs;
  final String? lifecycle;

  /// The `fw://` address of this step's capture — what to hand back to ask a
  /// different question about this moment.
  ///
  /// The manifest beside it (`<stamp>.capture.json`) lists the four legs and
  /// what is in each.
  final String? capture;

  /// What this step actually handed back — `screen`, `tree`, `screenshot`,
  /// `find`, `at`, `styles`.
  ///
  /// This is where the scoping lives, and the reason the artifacts no longer
  /// carry it. A journal is testimony: it has to say what the step reported,
  /// or a reviewer reads a complete tree beside a step that returned two
  /// levels of one subtree and concludes the agent saw more than it did. The
  /// files beside it are the archive and hold the whole screen. One file
  /// cannot be both, and when it tried, the archive lost — measured, 17 steps
  /// had left 5 screenshots.
  final List<String>? reported;

  /// Absolute path of the step's screenshot. Always taken; see [reported] for
  /// whether the step *returned* it.
  final String? screenshot;

  /// The step's widget tree, written beside the screenshot — persisted even
  /// when the caller did not ask for it inline, so a later reviewer has the
  /// same three legs a scenario step has.
  final String? tree;

  /// The step's visible-text projection, as a JSON list beside the tree.
  final String? texts;

  /// The semantics tree as the app published it, beside the rest.
  final String? semantics;

  /// How many log lines the step produced. The lines themselves ride the act
  /// result; the journal keeps the count.
  final int? logLines;

  final int? errorCount;

  /// Which tree the step addressed: absent or `flutter` for the drive layer,
  /// `native` for a step taken through the platform's own accessibility tree.
  /// A reviewer reading the strip should be able to see that the agent went
  /// below the widget tree — that is usually the interesting part of the
  /// story, not a footnote.
  final String? layer;

  /// How many human entries this step absorbed as its own echo.
  ///
  /// A native tap arrives at the guest as ordinary platform input, so the
  /// app's human-action recorder reports the agent's own tap back as a
  /// human's. The host drops those (see `RunCore`), and states the count
  /// rather than hiding the correction — the stated-caps rule, applied to a
  /// subtraction.
  final int? reconciled;

  /// What a `set` step asked the device for, and what the device answered.
  ///
  /// `{setting, asked, answered, provenance}`, and the reason it is four facts
  /// rather than one: a device write is the only actor that changes a screen
  /// while leaving **no** trace in the app. A native tap at least comes back in
  /// the next observe's `human` field; this comes back as nothing at all, so
  /// without the entry the Steps tab shows a screen changing with no cause.
  ///
  /// `asked` and `answered` are kept apart because they disagree in ordinary
  /// use — a locale set on the iOS simulator lands on the device and the
  /// running app keeps the old one until it is relaunched. An entry that
  /// recorded only what was asked would be testimony to something that did not
  /// happen.
  final Map<String, Object?>? device;

  /// A marker entry: the file was rotated here (see [appendJournal]).
  final bool rotated;

  Map<String, Object?> toJson() => {
    'at': at,
    'verb': verb,
    if (actor != null) 'actor': actor,
    if (target != null) 'target': target,
    if (error != null) 'error': error,
    if (failure != null) 'failure': failure,
    if (attempts != null) 'attempts': attempts,
    if (elapsedMs != null) 'elapsedMs': elapsedMs,
    if (settled != null) 'settled': settled,
    if (settleMs != null) 'settleMs': settleMs,
    if (lifecycle != null) 'lifecycle': lifecycle,
    if (capture != null) 'capture': capture,
    if (reported != null) 'reported': reported,
    if (screenshot != null) 'screenshot': screenshot,
    if (tree != null) 'tree': tree,
    if (texts != null) 'texts': texts,
    if (semantics != null) 'semantics': semantics,
    if (logLines != null) 'logLines': logLines,
    if (errorCount != null) 'errorCount': errorCount,
    if (layer != null) 'layer': layer,
    if (reconciled != null) 'reconciled': reconciled,
    if (device != null) 'device': device,
    if (rotated) 'rotated': true,
  };
}

/// `app-<key>.journal.jsonl`, beside the handle. Null for a handle that was
/// never published — there is no run dir to write into.
String? journalPathFor(RunHandle handle) {
  var handlePath = handle.handlePath;
  if (handlePath == null) return null;
  return '${p.withoutExtension(handlePath)}.journal.jsonl';
}

/// Where a step's artifacts (screenshots) land: `journal/app-<key>/` in the
/// run dir. Beside the handle's naming scheme, not a new one.
String? journalArtifactsDirFor(RunHandle handle) {
  var handlePath = handle.handlePath;
  if (handlePath == null) return null;
  return p.join(
    p.dirname(handlePath),
    'journal',
    p.basenameWithoutExtension(handlePath),
  );
}

/// The cap, stated rather than discovered: a journal past this rotates once —
/// the previous file becomes `.1`, replacing any older `.1` — so a long
/// session keeps its recent story and a runaway loop cannot fill the disk.
const journalMaxBytes = 5 << 20;

/// What a run's *artifacts* may weigh — the pictures, which is all the weight
/// there is. [journalMaxBytes] bounds the story; this bounds the evidence.
///
/// It needs its own number because the two grew at wildly different rates once
/// the human's own steps were journaled. A line of JSON is ~200 bytes; the
/// picture it points at is ~187KB on a dense screen (measured 2026-08-24), so
/// a person simply *using* their app at 20-40 bursts a minute writes
/// **0.23-0.46 GB an hour**. For scale, the litter that gave `sweepRunDir` its
/// caller was 161MB over two days.
///
/// 64MB is about 340 dense beats or 1,100 plain ones — days of an agent's
/// steps, or a long sitting of a human's. Past it the oldest are let go, which
/// is the same degradation everything else here takes: the entry stays, the
/// picture does not, and the Steps tab draws a verb icon where the thumbnail
/// was.
const journalArtifactsMaxBytes = 64 << 20;

/// Lets go of a run's oldest step artifacts until the directory is inside
/// [maxBytes]. Returns how many bytes were freed.
///
/// Whole steps at a time. A step writes several files under one stamp — the
/// picture, the texts, the tree, the semantics — and deleting the picture
/// alone would leave a detail pane reading from artifacts whose screenshot has
/// gone, which is worse than a step with no picture at all.
///
/// Best-effort throughout, like the rotation above: this is housekeeping, and
/// another process winning a race to delete the same file is the expected case
/// rather than an error. The newest step is never let go, however big it is —
/// a bound that could delete the step somebody is looking at is a bug, not a
/// bound.
int boundJournalArtifacts(
  RunHandle handle, {
  int maxBytes = journalArtifactsMaxBytes,
}) {
  var dir = journalArtifactsDirFor(handle);
  if (dir == null) return 0;
  List<FileSystemEntity> entries;
  try {
    entries = Directory(dir).listSync();
  } on FileSystemException {
    return 0;
  }
  // Grouped by the stamp every one of a step's files starts with, which is
  // `<millis>-<pid>` and therefore sorts chronologically as a number.
  var groups = <String, List<File>>{};
  var bytes = <String, int>{};
  var total = 0;
  for (var entity in entries) {
    if (entity is! File) continue;
    var name = p.basename(entity.path);
    var stamp = name.split('.').first;
    int length;
    try {
      length = entity.lengthSync();
    } on FileSystemException {
      continue;
    }
    (groups[stamp] ??= []).add(entity);
    bytes[stamp] = (bytes[stamp] ?? 0) + length;
    total += length;
  }
  if (total <= maxBytes || groups.length < 2) return 0;
  int millisOf(String stamp) => int.tryParse(stamp.split('-').first) ?? 0;
  var oldest = groups.keys.toList()
    ..sort((a, b) => millisOf(a).compareTo(millisOf(b)));
  // Never the last one.
  oldest.removeLast();
  var freed = 0;
  for (var stamp in oldest) {
    if (total <= maxBytes) break;
    for (var file in groups[stamp]!) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Somebody else got there first, which is fine.
      }
    }
    total -= bytes[stamp]!;
    freed += bytes[stamp]!;
  }
  return freed;
}

/// Appends one entry. JSON-lines because two processes append to the same
/// story — a GUI and an `fw` are both actors — and appending a line is the
/// one write that composes.
void appendJournal(RunHandle handle, JournalEntry entry) {
  var path = journalPathFor(handle);
  if (path == null) return;
  var file = File(path);
  if (file.existsSync() && file.lengthSync() > journalMaxBytes) {
    // Best-effort, like the torn-line tolerance above: two writers can cross
    // the cap together, and the loser of the rename race must append its
    // entry to the freshly rotated file, not fail the caller's action over
    // housekeeping.
    try {
      var previous = File('$path.1');
      if (previous.existsSync()) previous.deleteSync();
      file.renameSync(previous.path);
      File(path).writeAsStringSync(
        '${jsonEncode(JournalEntry(at: entry.at, verb: 'rotated', rotated: true).toJson())}\n',
      );
    } on FileSystemException {
      // The other writer rotated first; the append below lands either way.
    }
  }
  File(
    path,
  ).writeAsStringSync('${jsonEncode(entry.toJson())}\n', mode: FileMode.append);
}

/// The entries, oldest first. A malformed line — a torn concurrent write — is
/// skipped rather than fatal: the journal is a narrative, not a ledger.
List<JournalEntry> readJournal(
  RunHandle handle, {
  int? tail,
  RunFiles files = const DiskRunFiles(),
}) {
  var path = journalPathFor(handle);
  if (path == null) return const [];
  var text = files.readString(path);
  if (text == null) return const [];
  var entries = <JournalEntry>[];
  for (var line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    try {
      entries.add(
        JournalEntry.fromJson(jsonDecode(line) as Map<String, Object?>),
      );
    } on Object {
      continue;
    }
  }
  if (tail != null && entries.length > tail) {
    return entries.sublist(entries.length - tail);
  }
  return entries;
}
