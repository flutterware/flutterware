/// The compiler daemon's phase names, read back into words for a reader.
///
/// The counterpart of `readTesterPhase` for the other lane, and it exists for
/// the same reason: the daemon names its phases for a timings table it files
/// them in — `cold compile`, `host build` — and a table's vocabulary is the
/// wrong one under a progress bar.
///
/// **An unknown phase survives the trip.** A daemon newer than the client is
/// the ordinary case here — one is a spawned process, the other is the GUI that
/// spawned it, and they move independently — so a name this does not recognise
/// is shown rather than swallowed. It is the daemon's own word for what it is
/// doing, which is a worse sentence than the ones below and a much better one
/// than silence.
String daemonPhaseLabel(String phase) => switch (phase) {
  'engine framework' => 'Fetching the engine framework',
  'host build' => 'Building the preview host',
  'asset bundle' => 'Building the asset bundle',
  'compiler start' => 'Starting the compiler',
  'cold compile' => 'Compiling the previews',
  // Both of the daemon's second passes. What sent it back is a fact about the
  // daemon — a demo that would not build, an excursion to write the shared
  // half — and neither is a distinction anybody waiting has any use for.
  'rebuild after quarantine' ||
  'rebuild after seeding' => 'Rebuilding the previews',
  'seed kernel' => 'Saving a kernel for the next checkout to start from',
  'scan' => 'Looking for demos',
  'quarantine' => 'Reading what did not compile last time',
  'publish prepared kernel' => 'Publishing the kernel the previews start from',
  // The one phase whose key carries a number — `source baseline (649 files)` —
  // so it is matched by its head and the count is kept, because the count is
  // the interesting half.
  _ when phase.startsWith('source baseline') =>
    'Recording ${_countIn(phase) ?? 'the'} source files to watch',
  _ => _sentence(phase),
};

/// The parenthesised count in a phase key, or null when there is not one.
String? _countIn(String phase) =>
    RegExp(r'\((\d+) ').firstMatch(phase)?.group(1);

/// An unrecognised phase, capitalised so it reads as a line rather than as a
/// key that leaked.
String _sentence(String phase) =>
    phase.isEmpty ? phase : '${phase[0].toUpperCase()}${phase.substring(1)}';
