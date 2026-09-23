import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'tappable.dart';
import 'theme.dart';

/// A bordered button that runs something async and says what happened.
///
/// The problem it solves is that fast work is invisible. The splash panel's
/// Reload re-reads the config in about 40ms. Pressing it did exactly what it
/// promised and looked like it had done nothing at all — no press state that
/// outlasted the pointer, no result, no error if the read threw. The instinct is
/// to call that a missing spinner, but a spinner shown for 40ms is not a
/// spinner; it is one dropped frame. What was missing is an *acknowledgement*,
/// and an acknowledgement has to last long enough to be seen whether the work
/// took 40ms or four seconds.
///
/// So this holds each state for a minimum time rather than for its natural one:
///
/// - **running** — for at least [_minRunning], even if [onPressed] returns
///   sooner. Below about a quarter second a state change reads as a flicker.
/// - **done** — a tick for [_settle], then back to idle.
/// - **failed** — the error's own message, held until the next press. A failure
///   that timed out would go unread.
///
/// Re-entrant presses are dropped while running, so a double click cannot start
/// two of anything.
///
/// [onPressed] returning a `Future` is the entire contract: this catches what it
/// throws and shows it. A caller that swallows its own errors and hands back a
/// completed future gets a green tick for a failure, which is worse than the
/// button this replaces.
///
/// A button that *opens* something has no outcome to acknowledge, and
/// [acknowledges] is how it says so — see the field.
class FwActionButton extends StatefulWidget {
  const FwActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.primary = false,
    this.acknowledges = true,
  });

  final String label;

  /// The tooltip while idle. The running, done and failed states describe
  /// themselves.
  final String? tooltip;

  /// Tinted with the accent. For the primary action on a bar.
  final bool primary;

  /// Awaited, and its error caught and shown. Null disables the button.
  final Future<void> Function()? onPressed;

  /// Whether finishing is worth saying. False for a button that opens rather
  /// than does — a popover anchor, a dialog, a file picker.
  ///
  /// The acknowledgement above is for work whose result you cannot otherwise
  /// see. Opening a form is its own result: the form is on the screen. Worse,
  /// `controller.open()` completes in the same frame, so the tick lands the
  /// instant you press — three buttons on the scene index announced "Done"
  /// before you had typed anything into the form they had just opened, which
  /// is not a slow acknowledgement but a false one.
  ///
  /// A failure is still reported: an open that throws is worth knowing about.
  final bool acknowledges;

  @override
  State<FwActionButton> createState() => _FwActionButtonState();
}

/// Long enough that a state change reads as a state change.
const _minRunning = Duration(milliseconds: 320);

/// How long the tick stays up. Long enough to notice on the way past, short
/// enough not to look like a mode.
const _settle = Duration(milliseconds: 1400);

enum _Phase { idle, running, done, failed }

class _FwActionButtonState extends State<FwActionButton> {
  var _phase = _Phase.idle;
  String? _error;
  Timer? _revert;

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    var onPressed = widget.onPressed;
    if (onPressed == null || _phase == _Phase.running) return;

    _revert?.cancel();
    setState(() {
      _phase = widget.acknowledges ? _Phase.running : _Phase.idle;
      _error = null;
    });

    // Started together and both awaited, so the floor is a floor and not an
    // addition — work that takes longer than it is not delayed at all.
    var floor = widget.acknowledges
        ? Future<void>.delayed(_minRunning)
        : Future<void>.value();
    String? failure;
    try {
      await onPressed();
    } catch (e) {
      failure = '$e';
    }
    await floor;

    if (!mounted) return;
    setState(() {
      _phase = switch (failure) {
        null when widget.acknowledges => _Phase.done,
        null => _Phase.idle,
        _ => _Phase.failed,
      };
      _error = failure;
    });

    // A failure stays until the next press; only success times out.
    if (failure == null) {
      _revert = Timer(_settle, () {
        if (mounted) setState(() => _phase = _Phase.idle);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var enabled = widget.onPressed != null && _phase != _Phase.running;

    var (label, fg) = switch (_phase) {
      _Phase.idle => (
        widget.label,
        widget.primary ? colors.accent : colors.ink,
      ),
      _Phase.running => ('${widget.label}…', colors.mut),
      _Phase.done => ('Done', colors.accent),
      _Phase.failed => ('Failed', colors.red),
    };

    var border = switch (_phase) {
      _Phase.done => colors.accent,
      _Phase.failed => colors.red,
      _ => widget.primary ? colors.accent : colors.line,
    };

    var button = Tappable(
      onTap: enabled ? () => unawaited(_run()) : null,
      borderRadius: BorderRadius.circular(context.radii.radius),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        // [FwControlSize.height], not content-sized: at its natural ~26px this
        // was the one control in a form row that sat below the field, the
        // picker and the themed Material buttons.
        height: FwControlSize.height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
        decoration: BoxDecoration(
          color: switch (_phase) {
            _Phase.done => colors.accentSoft,
            _Phase.failed => colors.red.withValues(alpha: 0.10),
            _ => widget.primary ? colors.accentSoft : null,
          },
          borderRadius: BorderRadius.circular(context.radii.radius),
          border: Border.all(color: border),
        ),
        child: Text(label, style: context.type.caption.copyWith(color: fg)),
      ),
    );

    // The failure's own text, not a paraphrase — it names what could not be
    // read. The tooltip is the only place with room for it.
    var message = switch (_phase) {
      _Phase.failed => _error,
      _Phase.idle => widget.tooltip,
      _ => null,
    };
    return message == null ? button : Tooltip(message: message, child: button);
  }
}
