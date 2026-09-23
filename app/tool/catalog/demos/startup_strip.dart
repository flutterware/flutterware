import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/design/design.dart';
import 'package:flutterware_app/src/ui/startup_progress.dart';

import 'app_theme.dart';

/// What a page waiting on a compiler says while it waits.
///
/// The band takes its own room above the content rather than covering it, which
/// is the whole arrangement: the page filling in is the thing being waited for,
/// and covering it to report on itself makes the filling invisible.
///
/// Two bars, and the difference is a claim. A render pass has a real count, so
/// its bar is determinate. A compile has no denominator and is not given a fake
/// one — a bar that fills at a rate nobody measured is a bar that lies, and the
/// climbing seconds beside it already do the one job it would be pretending to
/// do: telling slow from hung.
///
/// No Figma behind this; it is flutterware's own chrome.

/// The long pole of a first open, and the state the strip exists for.
@Preview(name: 'Compiling', group: 'Startup strip', wrapper: wrapInAppTheme)
Widget stripCompiling() =>
    _Strip(const StartupTask('Compiling the catalog'), seconds: 14);

/// The half with a denominator. The count is the page's own ask — what it built
/// and asked the harness for — not the whole package.
@Preview(name: 'Rendering', group: 'Startup strip', wrapper: wrapInAppTheme)
Widget stripRendering() => _Strip(
  const StartupTask('Rendering the previews', done: 47, total: 53),
  seconds: 26,
);

/// A phase from a daemon newer than this app: shown in the daemon's own word
/// for it rather than swallowed, because the two move independently.
@Preview(
  name: 'A phase it does not know',
  group: 'Startup strip',
  wrapper: wrapInAppTheme,
)
Widget stripUnknown() =>
    _Strip(const StartupTask('Linking the widget graph'), seconds: 3);

@Preview(name: 'Dark', group: 'Startup strip', wrapper: wrapInDarkTheme)
Widget stripDark() => _Strip(
  const StartupTask('Rendering the previews', done: 47, total: 53),
  seconds: 26,
);

/// The strip over the page it is holding up, so the arrangement is what is
/// photographed rather than the band alone.
class _Strip extends StatefulWidget {
  const _Strip(this.task, {required this.seconds});

  final StartupTask task;
  final int seconds;

  @override
  State<_Strip> createState() => _StripState();
}

class _StripState extends State<_Strip> {
  /// Driven rather than described: the strip reads a live model, and a demo
  /// that stood in for one with a static widget would be a picture of a
  /// different thing.
  late final _progress = StartupProgress(appearsAfter: Duration.zero);

  @override
  void initState() {
    super.initState();
    // Reported as though it had begun [_Strip.seconds] ago, so the picture
    // shows the readout in the state worth looking at rather than at zero. The
    // model reads its clock through `package:clock` precisely so that the thing
    // it is hardest to photograph — a number that only means something after it
    // has been climbing — can be photographed at all.
    // Off the *ambient* clock and not `DateTime.now()`: a preview renders
    // under a pinned one, so a shift measured against the wall clock lands
    // twenty million seconds from where the model then reads.
    var began = clock.now().subtract(Duration(seconds: widget.seconds));
    withClock(Clock.fixed(began), () => _progress.report('demo', widget.task));
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.bg,
    child: Column(
      children: [
        StartupStrip(progress: _progress),
        Expanded(
          child: Center(
            child: Text(
              'the page, filling in behind it',
              style: context.type.bodyMuted,
            ),
          ),
        ),
      ],
    ),
  );
}
