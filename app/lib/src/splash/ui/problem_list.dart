import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import '../../ui/theme.dart';
import '../model/validation.dart';

/// One thing wrong: a toned dot, the sentence, and what it is about.
///
/// Shared because it was written twice — once under the matrix for the
/// config-wide problems, once in the inspector for a cell's — and the two copies
/// were identical down to the 5px the dot is nudged to sit on the first line of
/// text. Two copies of a row agree only until one of them is edited.
class SplashProblemRow extends StatelessWidget {
  const SplashProblemRow(this.problem, {super.key});

  final SplashProblem problem;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var tone = switch (problem.tone) {
      Tone.error => colors.red,
      Tone.warn => colors.amber,
      _ => colors.mut2,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: FwSpacing.md),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(shape: BoxShape.circle, color: tone),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(problem.message, style: context.type.body),
                if (problem.key != null || problem.blocksGeneration)
                  Padding(
                    padding: const EdgeInsets.only(top: FwSpacing.xxs),
                    child: Text(
                      [
                        if (problem.key != null) problem.key!,
                        if (problem.blocksGeneration)
                          'stops `create` from running',
                      ].join('  ·  '),
                      style: context.type.micro.copyWith(color: colors.mut3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
