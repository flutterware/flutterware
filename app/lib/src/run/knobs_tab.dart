import 'package:material_ui/material_ui.dart';

import '../plugins/native/run_results.dart';
import '../ui/design/spacing.dart';
import '../ui/design/tokens.dart';
import 'handle.dart';
import 'knob_field.dart';

/// The knobs of the run being shown, editable, with **Restart to apply**.
///
/// This is what makes the measurement reachable. The launch form is a
/// different page — reaching it means leaving this run, and starting a second
/// one there is a fresh build. Editing here costs a wrapper rewrite and a hot
/// restart: 262ms on desktop, 3.07s on an Android emulator.
///
/// The bar is pinned rather than last in the list. A knob is a short
/// list today and an app with eight of them is ordinary; a button that scrolls
/// away is a button you have to go and find, and the sentence beside it is the
/// cost of pressing it. Both belong where the decision is made.
///
/// Two things it deliberately does not do:
///
/// - **It does not restart on its own.** Losing the app's state because a field
///   was typed in is a surprise a cockpit should not spring, so the button is
///   the consent.
/// - **It does not apply live.** A value reaches the app only through `main`,
///   so showing a new one while the process holds the old would look correct
///   and be wrong. Until the restart lands, the edit is marked *pending*.
class KnobsTab extends StatefulWidget {
  const KnobsTab({
    super.key,
    required this.handle,
    required this.knobs,
    this.unknown,
    required this.onApply,
    this.interfaceOf,
  });

  final RunHandle handle;

  /// What this entry point's `main` takes, read off the signature.
  final List<RunKnobEntry> knobs;

  /// Why the knobs cannot be known, when they cannot — another checkout's run,
  /// a package this worktree does not declare, an entry point that has since
  /// moved. Distinct from an empty list, which is the claim that this entry
  /// point takes none.
  final String? unknown;

  /// Rewrites the wrapper and restarts, and answers with what the app is
  /// **now running** — which is not always what was asked for, because a knob
  /// left out is re-asked of its source. Errors surface here rather than as a
  /// snackbar somewhere else.
  final Future<Map<String, String>> Function(Map<String, String> values)
  onApply;

  /// Passed to [KnobField] — which interface an offered address belongs to.
  final String? Function(String)? interfaceOf;

  @override
  State<KnobsTab> createState() => _KnobsTabState();
}

class _KnobsTabState extends State<KnobsTab> {
  /// The edits not yet applied, over what the run is actually holding.
  late Map<String, String> _edited = {...widget.handle.knobs};

  var _applying = false;
  String? _error;

  Map<String, String> get _running => widget.handle.knobs;

  bool get _dirty =>
      _edited.length != _running.length ||
      _edited.entries.any((e) => _running[e.key] != e.value);

  @override
  void didUpdateWidget(KnobsTab old) {
    super.didUpdateWidget(old);
    // A restart landed, or somebody else moved this run: adopt what is running
    // rather than keeping edits that have already happened.
    if (widget.handle.knobs.toString() != old.handle.knobs.toString()) {
      _edited = {...widget.handle.knobs};
    }
  }

  Future<void> _apply() async {
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      // Adopt what came back, not what was sent. `didUpdateWidget` cannot carry
      // this on its own: it only reacts when `handle.knobs` *changes*, and the
      // case that needs it most is the one where it does not — resetting a knob
      // whose source then recomputes the same value. The edit was applied, the
      // run is unchanged, and the tab was left claiming a pending change it
      // could never finish, with the button live and every press restarting the
      // app again.
      var running = await widget.onApply(_edited);
      if (mounted) setState(() => _edited = {...running});
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.unknown case var reason?) return _centred(context, reason);
    if (widget.knobs.isEmpty) {
      return _centred(
        context,
        // Said rather than left blank, because "no knobs" and "we did not
        // look" are different answers and only one of them is true here.
        '${widget.handle.entrypointLabel} takes no knobs.\n\n'
        'Give its main() optional named parameters — '
        "void main({String apiHost = 'localhost'}) — and they appear "
        'here, changeable with a hot restart instead of a rebuild.',
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.xl,
              vertical: FwSpacing.lg,
            ),
            children: [
              Text(
                'What main() was called with',
                style: context.type.caption.copyWith(
                  color: context.colors.mut3,
                ),
              ),
              const Gap(FwSpacing.md),
              for (var (index, knob) in widget.knobs.indexed) ...[
                if (index > 0)
                  Divider(height: FwSpacing.xxl, color: context.colors.line),
                KnobField(
                  // Keyed by name, so a field keeps its cursor when the run is
                  // read back and the list is rebuilt around it.
                  key: ValueKey(knob.name),
                  knob: knob,
                  value: _edited[knob.name],
                  interfaceOf: widget.interfaceOf,
                  onChanged: (value) => setState(() {
                    if (value == null) {
                      _edited.remove(knob.name);
                    } else {
                      _edited[knob.name] = value;
                    }
                  }),
                ),
              ],
            ],
          ),
        ),
        _ApplyBar(
          dirty: _dirty,
          applying: _applying,
          error: _error,
          onApply: _apply,
        ),
      ],
    );
  }

  Widget _centred(BuildContext context, String message) => Center(
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: context.type.caption,
        ),
      ),
    ),
  );
}

/// The consent, and what it costs, at the bottom of the pane.
class _ApplyBar extends StatelessWidget {
  const _ApplyBar({
    required this.dirty,
    required this.applying,
    required this.error,
    required this.onApply,
  });

  final bool dirty;
  final bool applying;
  final String? error;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: context.colors.panel,
        border: Border(top: BorderSide(color: context.colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton(
                onPressed: dirty && !applying ? onApply : null,
                child: Text(applying ? 'Restarting…' : 'Restart to apply'),
              ),
              const Gap(FwSpacing.md),
              if (dirty)
                Flexible(
                  child: Text(
                    // The cost, before the click rather than after it.
                    'A restart re-runs main, so the app starts from its first '
                    'screen.',
                    style: context.type.caption.copyWith(
                      color: context.colors.mut3,
                    ),
                  ),
                ),
            ],
          ),
          if (error case var failure?) ...[
            const Gap(FwSpacing.md),
            Text(
              failure,
              style: context.type.caption.copyWith(color: context.colors.red),
            ),
          ],
        ],
      ),
    );
  }
}
