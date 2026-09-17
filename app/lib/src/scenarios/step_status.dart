import 'package:flutter/material.dart';

import '../plugins/native/scenarios_results.dart';
import '../ui/theme.dart';

/// How a step names itself in the flow and on its page: what the `Shot` called
/// it, else what its verb did (`tap #pay`) — and `failed` for the frame a
/// scenario broke on, which nothing named because nobody asked for it.
///
/// The bare `step` is the last resort, for an artifact written before steps
/// carried their action.
String scenarioStepLabel(ScenarioRunStep step) =>
    step.failure != null ? 'failed' : step.name ?? step.action ?? 'step';

/// The transition *into* a step, as a sentence: `tap "Pay"`, `screen`,
/// `pumpWidget MyApp`. Null on a run captured before the verb was recorded,
/// and on the step a scenario broke at — a failure is not a verb that
/// finished.
///
/// What it is for: an arrow in the flow graph and a tab full of events both
/// need to name the thing that happened between two pictures, and "step 3"
/// does not.
String? scenarioStepTransition(ScenarioRunStep step) {
  if (step.verb == null) return null;
  return step.target == null ? step.verb : '${step.verb} ${step.target}';
}

/// The colour a step's label wears: the error tone for a failure, the warn
/// tone for a screen that never stopped animating, and nothing special
/// otherwise.
Color scenarioStepTone(BuildContext context, ScenarioRunStep step) {
  var colors = context.colors;
  if (step.failure != null) return colors.red;
  // A capture parked on purpose is not amber: `Settle.none` was asked for a
  // frame and gave one, so the animation still running is the subject of the
  // picture rather than a warning about it.
  if ((!step.settled && step.waited) || !step.landed || step.unchanged) {
    return colors.amber;
  }
  return colors.mut;
}

/// Where the names of what kept ticking point: the fix for motion that only
/// says "busy", which is most of it.
const ambientHint =
    'If it only says "busy" — a spinner, a shimmer, a pulsing dot — wrap it '
    'in `Ambient` (package:flutterware/ambient.dart): a scenario then draws it '
    'standing still and the step settles.';

/// What a step reports above its picture — the error it broke on, or the note
/// that the app was still animating when the capture was taken. Nothing at all
/// in the healthy case, which is almost every step.
class ScenarioStepNotice extends StatelessWidget {
  const ScenarioStepNotice(this.step, {super.key});

  final ScenarioRunStep step;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // Ordered by how much news each note carries. A capture parked on purpose
    // is the quietest — it says what the author already knows — so it comes
    // last and anything else the step has to say is shown instead.
    var (tone, icon, message) = switch (step) {
      ScenarioRunStep(failure: var failure?) => (
        colors.red,
        Icons.error_outline,
        failure,
      ),
      ScenarioRunStep(settled: false, waited: true, :var stillTicking) => (
        colors.amber,
        Icons.motion_photos_on_outlined,
        stillTicking.isEmpty
            ? 'Still animating when this was captured — the settle budget ran '
                  'out with frames still scheduled. A spinner or a looping '
                  'animation does that; the picture is of a moving screen.'
            : 'Still animating when this was captured — the settle budget ran '
                  'out with frames still scheduled, and the picture is of a '
                  'moving screen.\n\nStill ticking:\n'
                  '${stillTicking.map((line) => '• $line').join('\n')}\n\n'
                  '$ambientHint',
      ),
      ScenarioRunStep(landed: false) => (
        colors.amber,
        Icons.image_not_supported_outlined,
        'Still loading when this was captured — an image decode or an asset '
            'read had not finished after a second of real time. Whatever is '
            'missing from this picture turns up on the next step.',
      ),
      ScenarioRunStep(unchanged: true) => (
        colors.amber,
        Icons.copy_all_outlined,
        'Identical to the step before it — the verb ran and nothing on '
            'screen changed. In a walking scenario that usually means a '
            'stalled flow: a tap that landed on a control that ignored it, '
            "repeated until the loop's bound. It is harmless if you parked "
            'the capture mid-flight on purpose.',
      ),
      ScenarioRunStep(:var strayFrames) when strayFrames > 0 => (
        colors.mut2,
        Icons.timeline,
        '$strayFrames frame${strayFrames == 1 ? '' : 's'} were drawn before '
            'this step by something other than a scenario verb — the raw '
            '`tester`. Whatever the app showed in them is missing from this '
            'flow.',
      ),
      ScenarioRunStep(settled: false, waited: false) => (
        colors.mut2,
        Icons.motion_photos_paused_outlined,
        'Parked mid-flight: this step ran under a policy that draws its '
            'frames and stops rather than waiting for the app to go quiet, so '
            'the screen still moving is what the picture is of. Nothing gave '
            'up here.',
      ),
      _ => (null, null, null),
    };
    if (tone == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        FwSpacing.lg,
        0,
        FwSpacing.lg,
        FwSpacing.md,
      ),
      padding: const EdgeInsets.all(FwSpacing.md),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.radii.radius),
        border: Border.all(color: tone.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: FwIconSize.md, color: tone),
          const Gap(FwSpacing.sm),
          Expanded(
            child: SelectableText(
              message!,
              style: context.type.caption.copyWith(color: colors.ink),
            ),
          ),
        ],
      ),
    );
  }
}
