import 'dart:convert';

import 'package:path/path.dart' as p;

import '../embedder/build_directory.dart';
import '../embedder/tester_host.dart';
import 'catalog_entry.dart';
import 'compile_blame.dart';
import 'devices.dart';
import 'harness_generator.dart';

/// What the harness is generated from, read fresh on every sync.
///
/// A record rather than two parameters because the two move together: a canvas
/// list edited in `tool/flutterware.dart` changes the generated program exactly
/// as adding a preview does, and a fingerprint that watched only the entries
/// would leave a warm harness framing them the old way.
typedef PreviewCatalog = ({
  List<CatalogEntry> entries,
  List<PreviewCanvas> canvases,
});

/// What this lane's dill, bundle and log are called.
const previewsProgramName = 'previews';

/// The previews half of a [TesterHost].
class PreviewProgram extends TesterProgram {
  PreviewProgram({
    required this.packageRoot,
    required this.read,
    required this.lane,
  });

  final String packageRoot;

  /// Where the generated harness goes — the host's own lane, so an isolated
  /// runner never renumbers or prunes the warm one's wrappers.
  final BuildLane lane;

  String get buildDirectory => lane.path;

  /// Re-read on every sync, so a preview written while the harness is warm
  /// restarts it rather than staying invisible until the panel is reopened.
  final PreviewCatalog Function() read;

  /// Entries the compiler refused, and what it said. They are left out of the
  /// generated program — the harness imports every entry, so one that does not
  /// build fails the compile for all of them, and dropping it is what serves
  /// the rest.
  final quarantined = <String, String>{};

  /// The last read, so [writeEntrypoint] generates from what [sources]
  /// fingerprinted rather than from a second read that may have moved.
  PreviewCatalog? _last;

  /// Every entry the scan found, quarantine included — what blame is
  /// attributed against.
  List<CatalogEntry> get scanned => _last?.entries ?? const [];

  @override
  String get name => previewsProgramName;

  @override
  String get readyLine => 'flutterware previews harness ready';

  @override
  List<String> sources() {
    var catalog = _last = read();
    return [
      for (var entry in _servable(catalog)) entry.id,
      // The generated file is a function of the canvases too, and a canvas
      // change has to restart the guest for the same reason an entry change
      // does: `main` has already run and no reload re-runs it.
      'canvases:${jsonEncode([for (var c in catalog.canvases) c.toJson()])}',
    ]..sort();
  }

  /// Generates from the catalog [sources] just read.
  ///
  /// The argument is the fingerprint rather than the material — an entry id is
  /// not enough to write a wrapper from — so this reads the catalog it was
  /// computed from instead of parsing it back.
  @override
  String writeEntrypoint(List<String> sources) {
    var catalog = _last ??= read();
    return writePreviewHarness(
      packageRoot,
      _servable(catalog),
      canvases: catalog.canvases,
      directory: buildDirectory,
    );
  }

  List<CatalogEntry> _servable(PreviewCatalog catalog) => [
    for (var entry in catalog.entries)
      if (!quarantined.containsKey(entry.id)) entry,
  ];
}

/// What one entry said when the harness rendered it.
class PreviewAuditRow {
  const PreviewAuditRow({
    required this.id,
    this.compileError,
    this.failure,
    this.errors = const [],
  });

  final String id;

  /// Set when the compiler refused it, in which case nothing rendered.
  final String? compileError;

  /// Set when it did not render at all — the builder threw outright, the test
  /// timed out. A different kind of broken from an entry that rendered badly.
  final String? failure;

  /// What the framework reported while it built and painted, as
  /// `InspectErrors.toJson` wrote it.
  final List<Map<String, Object?>> errors;

  /// [errors] minus the ones that indict the lane rather than the entry.
  ///
  /// `flutter_test` answers **every** HTTP request with 400, so a preview of
  /// a widget that renders a remote image can never be anything but "broken"
  /// here — permanently, correct code and all. Its failure is marked
  /// `network` at the guest and set aside: two false positives out of ninety
  /// is enough to stop anybody reading the audit.
  List<Map<String, Object?>> get indicting => [
    for (var error in errors)
      if (error['network'] != true) error,
  ];

  bool get ok => compileError == null && failure == null && indicting.isEmpty;
}

/// One entry rendered and photographed, as [PreviewTestRunner.capture] hands
/// it over.
///
/// The picture and the tree are **paths**, not bytes: a frame is megabytes,
/// the service protocol is JSON, and the caller is going to hash and file the
/// pixels rather than look at them — the same transport the scenario
/// comparison uses.
class PreviewCaptureRow {
  const PreviewCaptureRow({
    required this.id,
    this.compileError,
    this.failure,
    this.errors = const [],
    this.image,
    this.format = 'raw',
    this.width = 0,
    this.height = 0,
    this.tree,
    this.pending = const {},
  });

  final String id;

  /// Set when the compiler refused it, in which case nothing rendered.
  final String? compileError;

  /// Set when the entry's test did not come out clean — the builder threw,
  /// a timer outlived the audit clock. A frame may still exist beside it.
  final String? failure;

  /// What the framework reported, as `InspectErrors.toJson` wrote it.
  final List<Map<String, Object?>> errors;

  /// The settled screen on disk, or null when nothing rendered.
  final String? image;

  /// How [image] is encoded — `raw` (rgba8888 rows) or `png`. The same
  /// vocabulary `ShotRecord.format` uses, so a captured row can be filed
  /// without translating.
  final String format;

  final int width;
  final int height;

  /// `InspectTree.toJson` on disk, beside the image.
  final String? tree;

  /// What the app had announced and not finished when [image] was taken —
  /// `tracked` labels, `images` and `assets` counts — or empty when nothing
  /// was. Always empty from a harness that predates the field.
  final Map<String, Object?> pending;
}

/// Renders a package's whole catalog under `flutter_tester` and reports what
/// each entry said.
///
/// The embedder guest renders one entry at a time in real time, which is right
/// for a panel being watched and wrong for a catalog-wide check: a
/// demo that animates for ever costs three real seconds there and microseconds
/// of fake clock here. What is *not* given up is fidelity — the harness spawns
/// its own tester precisely so it can omit `--use-test-fonts`, mounts each
/// entry under the same `CatalogGuest` the guest entrypoint mounts, and reports
/// through the same [GuestErrors] buffer, so the two backends' rows are
/// comparable.
class PreviewTestRunner {
  /// [buildDirectory] is what this runner would *rather* build in; where it
  /// actually builds is [takeBuildLane]'s answer, because another process may
  /// already hold it.
  PreviewTestRunner({
    required String packageRoot,
    required String flutterSdkRoot,
    required PreviewCatalog Function() read,
    String buildDirectory = TesterHost.defaultBuildDirectory,
    bool followEdits = true,
    void Function(String line)? onLog,
  }) : this._(
         PreviewProgram(
           packageRoot: packageRoot,
           read: read,
           lane: BuildLane(
             packageRoot,
             preferred: buildDirectory,
             program: previewsProgramName,
           ),
         ),
         (program) => TesterHost(
           packageRoot: packageRoot,
           flutterSdkRoot: flutterSdkRoot,
           program: program,
           lane: program.lane,
           followEdits: followEdits,
           onLog: onLog,
         ),
       );

  /// Another guest running [leader]'s harness, spawned from the kernel
  /// [leader] compiled — see [TesterHost.sharing]. [leader] must have been
  /// built with `followEdits: false`, and [prepare]d before this captures:
  /// what the leader's compile quarantined is what this guest's program is
  /// missing, and it reads that from the leader.
  PreviewTestRunner.sharing(
    PreviewTestRunner leader, {
    required int guest,
    void Function(String line)? onLog,
  }) : this._(
         leader._program,
         (_) => TesterHost.sharing(leader._host, guest: guest, onLog: onLog),
       );

  PreviewTestRunner._(
    this._program,
    TesterHost Function(PreviewProgram program) host,
  ) : _host = host(_program);

  final PreviewProgram _program;
  final TesterHost _host;

  /// Where this runner's artifacts live, relative to [packageRoot] — the lane
  /// it took, which is not always the one it asked for.
  String get buildDirectory => _program.buildDirectory;

  /// The package these previews belong to — where an entry's `path` is
  /// relative to.
  String get packageRoot => _program.packageRoot;

  /// Rounds of drop-and-retry. Bounded for the reason the daemon's own loop is:
  /// each round quarantines at least one entry, and errors in one file
  /// routinely hide errors in the next.
  static const _blameRounds = 10;

  /// Renders [entryIds] — or everything — and reports each entry's verdict.
  Future<List<PreviewAuditRow>> audit({
    List<String>? entryIds,
    String? device,
    String? orientation,
    DateTime? clock,
  }) => _host.exclusive(() async {
    _program.quarantined.clear();
    await _bringUp();

    var response = await _host.vm.requireExtension(
      'ext.flutterware.previews.audit',
      args: {
        'entries': ?entryIds?.join(','),
        'device': ?device,
        'orientation': ?orientation,
        'clock': ?clock?.toIso8601String(),
      },
    );
    if (response!['error'] case String error) {
      throw StateError('the previews harness failed:\n$error');
    }

    var reported = (response['entries'] as Map).cast<String, Object?>();
    return [
      for (var entry in _program.quarantined.entries)
        if (entryIds == null || entryIds.contains(entry.key))
          PreviewAuditRow(id: entry.key, compileError: entry.value),
      for (var row in reported.entries)
        if (row.value case Map reported)
          PreviewAuditRow(
            id: row.key,
            failure: reported['failure'] as String?,
            errors: [
              for (var error in (reported['errors'] as List? ?? const []))
                if (error case Map fields) fields.cast<String, Object?>(),
            ],
          ),
    ];
  });

  /// Renders and photographs [entryIds], handing each row over as it lands.
  ///
  /// One extension call per entry rather than one for the batch, because the
  /// caller is a comparison and a comparison answers rows as they become
  /// answerable — a batch reply would hold every verdict until the last
  /// render. The harness is brought up **once**: quarantine survives the
  /// loop, so one broken entry costs one blame pass rather than a recompile
  /// per row.
  ///
  /// Frames land under `<outDir>/<index>/`, one directory per entry so the
  /// harness's own within-call numbering cannot collide across calls.
  /// **Three knobs for the caller that wants pictures rather than evidence.**
  /// Measured on this repo's 154 previews, warm, against a median entry that
  /// takes 43ms to render — so what these move is the disk, not the clock,
  /// with one exception:
  ///
  /// | | per entry | whole catalog |
  /// |---|---|---|
  /// | raw, 1x | 0.11ms | 368MB |
  /// | raw, quarter | 0.11ms | 23MB |
  /// | png, 700px side | 7.77ms | 4.2MB |
  /// | png, quarter | 1.07ms | 0.6MB |
  /// | `tree.json` beside it | 9.07ms | — |
  ///
  /// [pixelRatio] is physical pixels per logical pixel — the resolution, not a
  /// fraction of the screen, and the same word the guest's `FrameCapture`
  /// takes. `1` renders a 3× phone at its logical 440×956, which is what a
  /// comparison and a thumbnail want; a picture somebody will read a 16pt
  /// glyph in passes the staged device's own ratio. Barely a millisecond
  /// either way, and the bytes as its square.
  ///
  /// [format] is `raw` or `png`, the same vocabulary `ShotRecord` files under.
  /// PNG costs about 8ms of encode and takes the store from hundreds of
  /// megabytes to single-digit ones, which is what makes keeping a picture per
  /// entry affordable at all. A comparison stays raw — it diffs pixels, so a
  /// PNG would be encoded on the way in and decoded straight back out.
  ///
  /// [tree] off skips the `InspectTree` walk and the JSON beside the frame,
  /// which is **9× what the picture costs**. A caller that only wants pixels
  /// should say so.
  ///
  /// [timings] makes the harness narrate its stages onto stderr, for measuring
  /// this. Off by default; see `tool/spike/capture_cost.dart`.
  ///
  /// [sync] brings the harness up to date with what is on disk first, which
  /// is a sweep of every source and the asset bundle — measured at 1.5–1.9s
  /// even when nothing moved. Right for a comparison or an audit, which are
  /// asked for once and must not answer about code the user has since edited;
  /// wrong for a caller rendering one entry behind a pointer, which has its
  /// own idea of when its answers went stale and cannot pay two seconds a
  /// hover to ask.
  Future<void> capture({
    required List<String> entryIds,
    required String outDir,
    required Future<void> Function(PreviewCaptureRow row) onRow,
    bool sync = true,
    double pixelRatio = 1,
    bool tree = true,
    bool timings = false,
    String format = 'raw',
    DateTime? clock,
  }) => _host.exclusive(() async {
    // Only when syncing. The quarantine is filled by the blame rounds inside
    // [_bringUp], so clearing it without one would throw away what the last
    // compile learned and put nothing in its place.
    if (sync) _program.quarantined.clear();
    await _bringUp(sync: sync);

    for (var (index, id) in entryIds.indexed) {
      if (_program.quarantined[id] case var error?) {
        await onRow(PreviewCaptureRow(id: id, compileError: error));
        continue;
      }
      var response = await _host.vm.requireExtension(
        'ext.flutterware.previews.audit',
        args: {
          'entries': id,
          'output': p.join(outDir, '$index'),
          if (pixelRatio != 1) 'pixelRatio': '$pixelRatio',
          if (!tree) 'tree': 'false',
          if (timings) 'timings': 'true',
          if (format != 'raw') 'format': format,
          // Silently ignored by a `package:flutterware` from before the
          // preview clock was pinned, which is a base checkout rendering at
          // its wall clock against a head that does not. That is a one-time
          // re-baseline rather than a wrong picture, and `ShotKey.revision`
          // is what stops the two being served from one cache.
          'clock': ?clock?.toIso8601String(),
        },
      );
      if (response!['error'] case String error) {
        throw StateError('the previews harness failed:\n$error');
      }
      var reported = (response['entries'] as Map).cast<String, Object?>();
      if (reported[id] case Map fields) {
        var row = fields.cast<String, Object?>();
        var failure = row['failure'] as String?;
        // Rendered, no failure, and yet no picture: this harness does not
        // know the `output` argument. That is version skew, not a broken
        // entry — a comparison's base side resolves the base commit's own
        // `package:flutterware`, and one from before capture ignores the
        // request silently. Name it, or every row reads "did not render"
        // against a checkout where nothing is wrong.
        if (failure == null && row['image'] == null) {
          failure =
              "this checkout's package:flutterware predates preview "
              'capture: the harness rendered the entry but handed back no '
              'picture';
        }
        await onRow(
          PreviewCaptureRow(
            id: id,
            failure: failure,
            errors: [
              for (var error in (row['errors'] as List? ?? const []))
                if (error case Map found) found.cast<String, Object?>(),
            ],
            image: row['image'] as String?,
            // What the harness says it wrote, not what was asked for: a base
            // checkout's `package:flutterware` may predate the option and
            // answer in raw whatever the request said.
            format: row['format'] as String? ?? 'raw',
            width: row['width'] as int? ?? 0,
            height: row['height'] as int? ?? 0,
            tree: row['tree'] as String?,
            pending: switch (row['pending']) {
              Map found => found.cast<String, Object?>(),
              _ => const {},
            },
          ),
        );
      } else {
        await onRow(
          PreviewCaptureRow(
            id: id,
            failure: 'the harness returned nothing for this entry',
          ),
        );
      }
    }
  });

  /// One entry, rendered and asked about — the single-entry counterpart of
  /// [audit].
  ///
  /// Refuses rather than approximates, in four different ways and each with
  /// its own words: a harness too old to know the extension, a harness that
  /// knows it and will not answer this request, an entry the compiler
  /// quarantined, and an entry that did not render.
  ///
  /// [sync] as [capture] means it: right for a caller answering a question
  /// about the code as it is now, wrong for one rendering behind a pointer.
  Future<Map<String, Object?>> render({
    required String entryId,
    required Map<String, Object?> request,
    bool sync = true,
  }) => _host.exclusive(() async {
    if (sync) _program.quarantined.clear();
    await _bringUp(sync: sync);
    if (_program.quarantined[entryId] case var error?) {
      throw StateError('$entryId did not compile:\n$error');
    }
    var response = await _host.vm.callExtension(
      'ext.flutterware.previews.render',
      args: {'request': jsonEncode(request)},
    );
    if (response == null) {
      throw StateError(
        "this checkout's package:flutterware predates single-entry render: "
        'the harness came up but registers no '
        '`ext.flutterware.previews.render`.',
      );
    }
    if (response['error'] case String error) throw StateError(error);
    var entries = (response['entries'] as Map?)?.cast<String, Object?>();
    if (entries?[entryId] case Map row) {
      var reported = row.cast<String, Object?>();
      if (reported['failure'] case String failure) {
        throw StateError('$entryId did not render:\n$failure');
      }
      return reported;
    }
    throw StateError('the harness returned nothing for $entryId');
  });

  /// A live harness, dropping whatever will not compile until one exists.
  ///
  /// The generated program imports every entry, so a single demo mid-edit fails
  /// the compile for the whole catalog. This reads the compiler's own
  /// diagnostics, quarantines the entries declared in the files it blamed, and
  /// tries again with the rest — the same bargain the catalog daemon strikes,
  /// and the reason an audit answers at all while something is broken.
  ///
  /// Errors in files that declare no entry — a shared helper, the app itself —
  /// cannot be fixed by dropping anything, so they stay fatal.
  Future<void> _bringUp({bool sync = true}) async {
    for (var round = 0; round < _blameRounds; round++) {
      try {
        await _host.ensureGuest();
        // Warm: what is on disk may have moved since the last audit, and an
        // audit of code the user has already edited is worse than a slow one.
        if (round == 0 && sync) await _host.sync();
        return;
      } on TesterCompileException catch (e) {
        var blame = CompileBlame.of(
          e.output,
          entries: _program.scanned,
          projectRoot: _program.packageRoot,
          workingDirectory: _program.packageRoot,
        );
        if (blame.isEmpty) rethrow;
        var diagnostics = e.output.join('\n');
        for (var id in blame.entryIds) {
          _program.quarantined[id] = diagnostics;
        }
      }
    }
    throw StateError(
      'the previews harness still would not compile after $_blameRounds '
      'rounds of dropping what the compiler blamed',
    );
  }

  /// Compiles the harness and brings a guest up, dropping what the compiler
  /// blames, without capturing anything — what a [PreviewTestRunner.sharing]
  /// guest waits on.
  Future<void> prepare() => _host.exclusive(() => _bringUp(sync: false));

  Future<void> dispose() => _host.dispose();
}
