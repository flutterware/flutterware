import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../plugins/native/run_core.dart';
import '../ui/design/design.dart';
import '../ui/empty_state.dart';
import '../ui/filter_bar.dart';
import '../ui/menu.dart';
import '../ui/popover.dart';
import '../ui/selectable_line.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'handle.dart';
import 'logs.dart';
import 'native/native_logs.dart';

/// What the launcher wrote, with the app's own output separable from the
/// build's.
///
/// Read from the file rather than from a stream, which is why it works before
/// the app exists and after it has gone.
///
/// Two axes, because there are two questions. The pills pick who is talking —
/// [RunLogSource] says why that split is worth having — and `Errors` narrows
/// whoever that is to the lines that went wrong. They compose: `Build` +
/// `Errors` is why the launch failed, `App` + `Errors` is what the app threw,
/// and a single five-way pill row could say neither.
class LogsTab extends StatefulWidget {
  /// A run's log — building, live, or dead but still announced.
  LogsTab({super.key, required this.core, required RunHandle this.handle})
    : logPath = handle.logPath,
      subject = handle.key;

  /// The log of a launch that never came up.
  ///
  /// A failed launch has its handle deleted on purpose — a launcher that is not
  /// there must not go on telling the next person a phone is busy — so the one
  /// state where the log matters most is the one state with no run to point at.
  /// What survives is a [RunFailure]: a path, a key, and nothing that can be
  /// asked a question. For want of this constructor the failure page printed
  /// the path as selectable text, which is the same *a path is not an offer*
  /// the building state was just cured of.
  const LogsTab.ofFailure({
    super.key,
    required this.core,
    required this.logPath,
    required this.subject,
  }) : handle = null;

  final RunCore core;

  /// The run, when there is one.
  ///
  /// Null for a failure, and that null is the `Platform` pill's gate: the
  /// device log is read by asking a session about a window of time, which needs
  /// the run this pane no longer has.
  final RunHandle? handle;

  /// The file this pane follows.
  final String? logPath;

  /// Which run this is about, for telling a rebuild from a different subject.
  ///
  /// Watched alongside [logPath] rather than instead of it: a run's key is a
  /// hash of the worktree, the device and the entry point and survives a
  /// relaunch on purpose, while the file it writes does not.
  final String subject;

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> {
  RunLogSource? _only;

  /// Applied here rather than passed to [RunCore.readLogs], and the difference
  /// is which window it bounds. Asked of the reader it would answer the last
  /// [_tail] *errors*, dredging up a failure from an hour ago and showing it as
  /// if it were now; applied to what was read it answers the errors in the last
  /// [_tail] lines, which is the part of the run anybody is looking at. It also
  /// means the toggle costs nothing to flip, and works on the platform log,
  /// which is fetched rather than read.
  var _errorsOnly = false;

  final _needle = TextEditingController();

  /// The launcher's log, followed rather than re-read.
  ///
  /// It holds every source, and the pills narrow what is drawn rather than what
  /// is read: switching one then costs nothing, and `Errors` can compose with
  /// it without a second trip to the file.
  RunLogTail? _log;

  /// What the filters let through, and how many they were chosen from.
  ///
  /// Computed when something changes it, never in `build`. The panel rebuilds
  /// on every probe and on every frame of any animation above it, and this walks
  /// up to [RunLogTail.keep] lines.
  List<RunLogLine> _shown = const [];
  var _available = 0;

  StreamSubscription<void>? _refresh;

  /// The platform log, once it has been asked for.
  ///
  /// A fetch rather than a filter, which the tab shows by loading. The other
  /// three pills narrow a file this tab already holds; this one spends a `log
  /// show` or an `adb logcat` against the device. Selecting it is the request,
  /// and selecting it again refreshes — there is nothing to poll, because
  /// unlike the launcher's log nothing here changes on disk.
  NativeLogRead? _native;
  var _readingNative = false;

  final _scroll = ScrollController();

  /// Whether the view is riding the end of the log.
  ///
  /// The tab used to get this from a `reverse: true` list, which pins the
  /// newest line for free — and charges for it. Measured: with three lines
  /// appended, a line the reader was looking at moved 60 px, because a reversed
  /// list lays out from the bottom and every arrival pushes what is above it
  /// along. Reading the history of a live run meant chasing it up the screen.
  /// It also left a band of empty space over any log shorter than the viewport,
  /// which is what the tab looks like for the first second of every launch.
  ///
  /// So the list runs the normal way up and this says whether to follow. It
  /// follows until the reader scrolls away from the end, and offers to take
  /// them back rather than doing it behind them.
  var _following = true;

  /// The platform log is fetched rather than followed, so it is bounded at the
  /// ask. The launcher's log is bounded by [RunLogTail.keep] instead, which is
  /// a boundary the tab can see and say out loud.
  static const _nativeTail = 2000;

  @override
  void initState() {
    super.initState();
    _log = RunLogTail(widget.logPath, files: widget.core.files);
    _reread();
    _watch();
    _scroll.addListener(_watchScroll);
  }

  @override
  void didUpdateWidget(LogsTab old) {
    super.didUpdateWidget(old);
    // The log path, not only the key. A run's key is a hash of the worktree,
    // the device and the entry point, and `run_address.dart` keeps it that way
    // on purpose — it is what lets an address still name a run after you stop
    // and start it. The log file has no such wish: it is
    // `<key>-<pid>-<n>.log`, so a relaunch is the one case where everything
    // this tab reads changes and the key does not. Watching the key alone left
    // it tailing the dead run's file for as long as it stayed open.
    if (old.subject != widget.subject || old.logPath != widget.logPath) {
      _log = RunLogTail(widget.logPath, files: widget.core.files);
      _watch();
      _native = null;
      _following = true;
      _reread();
      // A different run is a different device: what was read for the last one
      // says nothing about this one, and an empty list would read as "it
      // logged nothing" rather than as "nobody has asked yet".
      if (_only == RunLogSource.native) unawaited(_rereadNative());
    }
  }

  void _watch() {
    unawaited(_refresh?.cancel());
    var path = widget.logPath;
    _refresh = path == null
        ? null
        : widget.core.files.changes(path).listen((_) => _reread());
  }

  @override
  void dispose() {
    unawaited(_refresh?.cancel());
    _scroll.dispose();
    _needle.dispose();
    super.dispose();
  }

  /// Not in `build`. A log is a file, the panel rebuilds on every probe and
  /// on every frame of any animation above it, and `RunCore.logOf` says in as
  /// many words why a panel must not read one from there. the file's change stream is
  /// the right shape: the file changing is what makes this stale.
  void _reread() {
    if (!mounted) return;
    _log?.read();
    _refilter();
    _keepUp();
  }

  /// Works out what the pills, the toggle and the box leave, in the order it
  /// was logged.
  void _refilter() {
    var lines = _only == RunLogSource.native
        ? _native?.lines ?? const <RunLogLine>[]
        : [
            for (var line in _log?.lines ?? const <RunLogLine>[])
              if (_only == null || line.source == _only) line,
          ];
    var needle = _needle.text.trim().toLowerCase();
    var shown = !_errorsOnly && needle.isEmpty
        ? lines
        : [
            for (var line in lines)
              if ((!_errorsOnly || line.error) &&
                  (needle.isEmpty || line.text.toLowerCase().contains(needle)))
                line,
          ];
    setState(() {
      _shown = shown;
      _available = lines.length;
    });
  }

  /// Never on the file's change stream. The launcher's log file changes constantly while
  /// an app runs, and this spawns a process: hanging it off the same callback
  /// would fire a `log show` every poll. It runs on request — which is what
  /// selecting the filter is.
  Future<void> _rereadNative() async {
    setState(() => _readingNative = true);
    var read = await widget.core.readNativeLogs(
      // Only reachable while the pill is offered, and the pill is offered only
      // for a run that exists.
      widget.handle!,
      tail: _nativeTail,
    );
    if (!mounted) return;
    setState(() {
      _native = read;
      _readingNative = false;
    });
    _refilter();
    _keepUp();
  }

  /// Rides the end of the log, one frame after the lines that grew it.
  ///
  /// After the frame, not during it: the extent to scroll to is the extent the
  /// new rows produce, and that is not known until they have been laid out.
  void _keepUp() {
    if (!_following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_following || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// A reader who scrolls away from the end has taken over; one who arrives
  /// back at it hands over again. The threshold is a line or so of slack, so
  /// that a trackpad's last fraction of a pixel does not count as leaving.
  void _watchScroll() {
    if (!_scroll.hasClients) return;
    var position = _scroll.position;
    var atEnd = position.maxScrollExtent - position.pixels < 24;
    if (atEnd != _following) setState(() => _following = atEnd);
  }

  void _refollow() {
    setState(() => _following = true);
    _keepUp();
  }

  void _select(RunLogSource? value) {
    setState(() => _only = value);
    // Immediately, not on the next tick: a filter that took most of a second
    // to answer would read as broken. Only the platform log costs a trip; the
    // other three are already in hand.
    if (value == RunLogSource.native) {
      unawaited(_rereadNative());
    } else {
      _refilter();
    }
  }

  @override
  Widget build(BuildContext context) {
    var shown = _shown;
    var filtered = shown.length != _available;
    // Only the launcher's log has a front that can fall off; the platform log
    // is a bounded fetch, and its bound is the one that was asked for.
    var dropped = _only == RunLogSource.native ? 0 : _log?.dropped ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwFilterBar(
          pills: [
            for (var (label, value) in [
              const ('All', null),
              const ('App', RunLogSource.app),
              const ('Build', RunLogSource.tool),
              // Dropped rather than offered-and-refused for a failure: it is
              // read by asking a device about a session, and a launch that
              // never came up has no session to ask about.
              if (widget.handle != null)
                const ('Platform', RunLogSource.native),
            ])
              (label, _only == value, () => _select(value)),
          ],
          toggles: [
            (
              'Errors',
              _errorsOnly,
              () {
                _errorsOnly = !_errorsOnly;
                _refilter();
              },
            ),
          ],
          hint: 'Find in the log…',
          searchController: _needle,
          onSearch: (_) => _refilter(),
          count: _readingNative
              ? 'reading…'
              : filtered
              ? '${shown.length} of $_available'
              : '$_available lines',
          trailing: _LogMenu(
            lines: shown,
            path: widget.logPath,
            filtered: filtered,
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? _emptyState(_available == 0)
              : Stack(
                  children: [
                    SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                          horizontal: FwSpacing.lg,
                          vertical: FwSpacing.sm,
                        ),
                        // The notice rides at the top of the scrollback, where
                        // the missing lines would have been, rather than in a
                        // band of its own — it is the beginning of what is
                        // here, and it scrolls away like one.
                        itemCount: shown.length + (dropped > 0 ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (dropped > 0) {
                            if (index == 0) {
                              return _EarlierLines(
                                dropped: dropped,
                                path: widget.logPath,
                              );
                            }
                            index -= 1;
                          }
                          return _LogRow(
                            shown[index],
                            needle: _needle.text.trim(),
                          );
                        },
                      ),
                    ),
                    if (!_following)
                      Positioned(
                        right: FwSpacing.lg,
                        bottom: FwSpacing.lg,
                        child: _JumpToLatest(onTap: _refollow),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _emptyState(bool nothingAtAll) {
    if (!nothingAtAll) {
      return const EmptyState(
        icon: Icons.search_off,
        title: 'Nothing matches this filter',
      );
    }
    return switch (_only) {
      RunLogSource.app => const EmptyState(
        icon: Icons.notes,
        title: 'The app has printed nothing',
        message: 'The build output is under Build.',
      ),
      RunLogSource.native => EmptyState(
        icon: Icons.phonelink,
        title: _readingNative
            ? 'Asking the platform…'
            : 'The native half of this app has logged nothing',
        message: _readingNative ? null : _native?.note,
      ),
      _ => const EmptyState(icon: Icons.notes, title: 'Nothing logged yet'),
    };
  }
}

/// One logged line.
///
/// [FwSelectableLine] rather than a [SelectableText], which is the whole
/// difference between a log you can take somewhere and a log you cannot: a
/// `SelectableText` per line is a selection scope per line, so a drag stopped
/// at the line it started in.
///
/// Wrapped, not clipped. A log line is prose often enough — a Gradle warning, a
/// CocoaPods paragraph, an exception message — that hiding its right-hand half
/// behind a scrollbar hides the part that says what happened. Wrapping is free
/// of the usual objection here because the selection is per *line*, not per
/// visual row: a line that wraps to eleven rows still copies as one line.
class _LogRow extends StatelessWidget {
  const _LogRow(this.line, {this.needle = ''});

  final RunLogLine line;

  /// Lit up where the filter matched, so a hit in a 200-character line does not
  /// have to be hunted for.
  final String needle;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var style = context.type.mono.copyWith(
      color: line.error
          ? colors.red
          : line.source == RunLogSource.app
          ? colors.ink
          : colors.mut2,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: FwSelectableLine(
        child: needle.isEmpty
            ? Text(line.text, style: style)
            : Text.rich(_lit(context, style), style: style),
      ),
    );
  }

  /// The line with every occurrence of [needle] marked.
  ///
  /// By run rather than by character: a span per character turns a 200-column
  /// line into 200 spans, and there are two thousand of them.
  TextSpan _lit(BuildContext context, TextStyle style) {
    var mark = style.copyWith(
      backgroundColor: context.colors.searchMark,
      color: context.colors.ink,
    );
    var spans = <TextSpan>[];
    var hay = line.text.toLowerCase();
    var pin = needle.toLowerCase();
    var at = 0;
    while (true) {
      var hit = hay.indexOf(pin, at);
      if (hit < 0) break;
      if (hit > at) spans.add(TextSpan(text: line.text.substring(at, hit)));
      spans.add(
        TextSpan(text: line.text.substring(hit, hit + pin.length), style: mark),
      );
      at = hit + pin.length;
    }
    if (at < line.text.length) {
      spans.add(TextSpan(text: line.text.substring(at)));
    }
    return TextSpan(children: spans);
  }
}

/// Where the scrollback starts, when that is not where the log starts.
///
/// A run that logs in a loop is exactly the run somebody leaves open for an
/// hour, so the tab holds a bounded number of lines and lets the oldest go.
/// What it may not do is let them go quietly: a reader scrolled to the top of
/// a log that begins mid-sentence is entitled to know that the beginning is
/// still on disk, and where.
class _EarlierLines extends StatelessWidget {
  const _EarlierLines({required this.dropped, required this.path});

  final int dropped;
  final String? path;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.sm),
      child: Row(
        children: [
          Icon(Icons.more_horiz, size: 14, color: colors.mut3),
          const Gap(FwSpacing.xs),
          Expanded(
            child: Text(
              path == null
                  ? '$dropped earlier lines are no longer held here.'
                  : '$dropped earlier lines are no longer held here — all of '
                        'it is in $path',
              style: context.type.caption.copyWith(color: colors.mut3),
            ),
          ),
        ],
      ),
    );
  }
}

/// Back to the end of the log.
///
/// Offered rather than done. A view that jumped to the newest line on its own
/// would be a view that yanked the line somebody was reading off the screen,
/// which is exactly what the reversed list used to do.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.panel2,
          borderRadius: BorderRadius.circular(context.radii.pill),
          border: Border.all(color: colors.line),
          boxShadow: context.elevation.md,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.arrow_downward, size: 14, color: colors.mut),
            const Gap(FwSpacing.xs),
            Text('Jump to latest', style: context.type.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// What to do with the log other than read it here.
///
/// The lines go to the clipboard the way the filters left them, because the
/// reason to copy a filtered log is that the filter is what found the problem.
/// The path goes too: everything above is a tail of a file that is still on
/// disk, and the file is what an editor, a `grep` or a bug report wants.
class _LogMenu extends StatelessWidget {
  const _LogMenu({
    required this.lines,
    required this.path,
    required this.filtered,
  });

  final List<RunLogLine> lines;
  final String? path;
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Menu(
      align: PopoverAlign.end,
      entries: [
        MenuItem(
          filtered
              ? 'Copy these ${lines.length} lines'
              : 'Copy all ${lines.length} lines',
          icon: Icons.copy_all,
          onSelected: lines.isEmpty
              ? null
              : () => Clipboard.setData(
                  ClipboardData(
                    text: [for (var line in lines) line.text].join('\n'),
                  ),
                ),
        ),
        MenuItem(
          'Copy the path to the log file',
          icon: Icons.description_outlined,
          onSelected: path == null
              ? null
              : () => Clipboard.setData(ClipboardData(text: path!)),
        ),
      ],
      builder: (context, controller) => Tappable(
        onTap: controller.toggle,
        borderRadius: BorderRadius.circular(context.radii.radius),
        child: Padding(
          padding: const EdgeInsets.all(FwSpacing.xs),
          child: Icon(Icons.more_horiz, size: 16, color: colors.mut),
        ),
      ),
    );
  }
}
