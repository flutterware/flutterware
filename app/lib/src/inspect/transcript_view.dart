import 'package:material_ui/material_ui.dart';

import '../ui/theme.dart';
import 'semantics_node.dart';
import 'transcript.dart';

/// The script lens of the Semantics tab: the tree read as what a screen
/// reader would speak, one utterance per row, with the label audits' findings
/// pinned to the rows they are about. The tree lens is the same capture's
/// structural half; this is the *ear's* projection — flat, in reading order,
/// nothing but what gets said.
///
/// Hover lights the utterance's rect on the picture through the same notifier
/// the tree lens writes — the two lenses cannot be hovered at once.
class TranscriptScript extends StatelessWidget {
  const TranscriptScript({
    super.key,
    required this.transcript,
    required this.highlight,
  });

  final SemanticsTranscript transcript;

  /// The hovered utterance's node, drawn on the screenshot by the host.
  final ValueNotifier<SemanticsSnapshotNode?> highlight;

  @override
  Widget build(BuildContext context) {
    var utterances = transcript.utterances;
    if (utterances.isEmpty) {
      return Container(
        color: context.colors.panel,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Text(
          'Nothing is announced on this screen — the reading is silent.',
          textAlign: TextAlign.center,
          style: context.type.caption.copyWith(color: context.colors.mut),
        ),
      );
    }

    return Container(
      color: context.colors.panel,
      width: double.infinity,
      child: MouseRegion(
        onExit: (_) => highlight.value = null,
        child: ListView.builder(
          primary: false,
          padding: const EdgeInsets.symmetric(vertical: FwSpacing.xs),
          itemCount: utterances.length,
          itemBuilder: (context, index) =>
              _UtteranceRow(utterance: utterances[index], highlight: highlight),
        ),
      ),
    );
  }
}

class _UtteranceRow extends StatelessWidget {
  const _UtteranceRow({required this.utterance, required this.highlight});

  final TranscriptUtterance utterance;
  final ValueNotifier<SemanticsSnapshotNode?> highlight;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var worst = utterance.findings.fold<TranscriptSeverity?>(
      null,
      (acc, finding) =>
          acc == TranscriptSeverity.error ? acc : finding.severity,
    );
    var silent = utterance.words.isEmpty;

    return InkWell(
      onHover: (over) {
        if (over) {
          highlight.value = utterance.node;
        } else if (identical(highlight.value, utterance.node)) {
          highlight.value = null;
        }
      },
      // Hover is the interaction; the tap is only here so InkWell hovers.
      onTap: () {},
      child: ValueListenableBuilder(
        valueListenable: highlight,
        builder: (context, lit, child) => Container(
          color: identical(lit, utterance.node)
              ? colors.panel2
              : switch (worst) {
                  TranscriptSeverity.error => colors.red.withValues(
                    alpha: 0.08,
                  ),
                  TranscriptSeverity.warning => colors.amber.withValues(
                    alpha: 0.10,
                  ),
                  null => null,
                },
          child: child,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.md,
            vertical: 3,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      '${utterance.index}',
                      textAlign: TextAlign.right,
                      style: context.type.micro.copyWith(color: colors.mut3),
                    ),
                  ),
                  const Gap(FwSpacing.sm),
                  Flexible(
                    child: Text(
                      // A merged node's label carries the newlines its parts
                      // were laid out with; spoken, they are just pauses —
                      // and the row is a line, not a paragraph.
                      silent
                          ? '(nothing to read)'
                          : '“${utterance.words.replaceAll(RegExp(r'\s+'), ' ')}”',
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: context.type.caption.copyWith(
                        color: silent ? colors.red : colors.ink,
                        fontStyle: silent ? FontStyle.italic : null,
                      ),
                    ),
                  ),
                  if (utterance.role case var role?) ...[
                    const Gap(FwSpacing.sm),
                    Text(
                      role,
                      style: context.type.micro.copyWith(color: colors.mut),
                    ),
                  ],
                  if (utterance.hint.isNotEmpty) ...[
                    const Gap(FwSpacing.sm),
                    Flexible(
                      child: Text(
                        utterance.hint,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: context.type.micro.copyWith(color: colors.mut2),
                      ),
                    ),
                  ],
                  const Spacer(),
                  for (var finding in utterance.findings) ...[
                    const Gap(FwSpacing.sm),
                    TranscriptFindingPill(finding),
                  ],
                ],
              ),
              for (var finding in utterance.findings)
                Padding(
                  padding: const EdgeInsets.only(
                    left: 22 + FwSpacing.sm,
                    top: 2,
                    bottom: 2,
                  ),
                  child: Text(
                    finding.message,
                    style: context.type.micro.copyWith(color: colors.mut),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A finding's short badge, toned by severity — on script rows, and on the
/// tree lens's rows for the same nodes, so the two lenses never disagree
/// about what is wrong.
class TranscriptFindingPill extends StatelessWidget {
  const TranscriptFindingPill(this.finding, {super.key});

  final TranscriptFinding finding;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var (tone, ground) = switch (finding.severity) {
      TranscriptSeverity.error => (
        colors.red,
        colors.red.withValues(alpha: 0.14),
      ),
      TranscriptSeverity.warning => (
        colors.warningText,
        colors.amber.withValues(alpha: 0.16),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: ground,
        borderRadius: BorderRadius.circular(context.radii.micro),
      ),
      child: Text(
        finding.badge,
        style: context.type.micro.copyWith(color: tone),
      ),
    );
  }
}
