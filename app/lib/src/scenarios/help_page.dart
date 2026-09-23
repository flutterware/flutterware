import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../ui/design/design.dart';
import '../ui/syntax.dart';
import 'authoring.dart';

/// How to write a scenario, as a page.
///
/// The same words `list` hands an agent ([scenarioAuthoringHint]), but rendered
/// for eyes: a wide column, the example highlighted as the Dart it is, the API
/// as rows. It used to be a single 40-line string squeezed into the 240px list
/// pane, where the example wrapped mid-expression.
///
/// Reachable with scenarios present, not only without them. Writing the
/// second one is the same question as writing the first, and the empty state
/// that used to be the only door closes exactly when the first file lands.
class ScenarioHelpPage extends StatelessWidget {
  const ScenarioHelpPage({
    super.key,
    required this.directory,
    required this.onNew,
  });

  /// The package's scenario directory — the per-project half of the answer.
  final String directory;

  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      child: Center(
        child: ConstrainedBox(
          // A measure, not the pane: prose set to 900px of window is prose
          // nobody finishes a line of.
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('How to write a scenario', style: context.type.pageTitle),
              const Gap(FwSpacing.lg),
              _Prose(scenarioAuthoringIntro(directory)),
              const Gap(FwSpacing.xl),
              _CodeBlock(scenarioAuthoringExample(directory)),
              const Gap(FwSpacing.xl),
              _Prose(scenarioAuthoringImportNote),
              const Gap(FwSpacing.xl),
              Text('The surface', style: context.type.sectionLabel),
              const Gap(FwSpacing.md),
              for (var (term, what) in scenarioAuthoringPoints) ...[
                _Point(term: term, what: what),
                const Gap(FwSpacing.md),
              ],
              const Gap(FwSpacing.md),
              Divider(color: colors.line, height: 1),
              const Gap(FwSpacing.xl),
              _Prose(
                'Both of these write a runnable scenario to edit — the button '
                'then opens it, which runs it.',
              ),
              const Gap(FwSpacing.md),
              _CommandLine(scenarioAuthoringCommand(directory)),
              const Gap(FwSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: onNew,
                  icon: const Icon(Icons.add, size: FwIconSize.md),
                  label: const Text('New scenario'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A paragraph whose `backticked` runs are set as code.
class _Prose extends StatelessWidget {
  const _Prose(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SelectableText.rich(
    TextSpan(children: inlineCodeSpans(context, text)),
    style: context.type.body.copyWith(height: 1.5),
  );
}

/// One API row: what it is, then what it does.
class _Point extends StatelessWidget {
  const _Point({required this.term, required this.what});

  final String term;
  final String what;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: FwSpacing.md),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(text: term, style: _codeStyle(context)),
            const TextSpan(text: '  '),
            ...inlineCodeSpans(context, what),
          ],
        ),
        style: context.type.bodySmall.copyWith(
          color: context.colors.mut,
          height: 1.5,
        ),
      ),
    );
  }
}

/// [text] split on backticks, the odd runs set as code.
///
/// Shared by the prose and the rows because the source strings are the same
/// ones the terminal prints, backticks and all — this is what those backticks
/// become when the text is rendered rather than printed.
List<InlineSpan> inlineCodeSpans(BuildContext context, String text) => [
  for (var (index, run) in text.split('`').indexed)
    if (run.isNotEmpty)
      TextSpan(text: run, style: index.isOdd ? _codeStyle(context) : null),
];

TextStyle _codeStyle(BuildContext context) =>
    context.type.mono.copyWith(color: context.colors.ink2);

/// The example, highlighted.
///
/// Scrolls horizontally rather than wrapping: a wrapped line of Dart reads as a
/// syntax error, and this snippet is written narrow enough that the scrollbar
/// is a safety net and not the normal case.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.source);

  final String source;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radii.radius),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(FwSpacing.lg),
          child: SelectableText.rich(
            TextSpan(children: codeSpans(context, source)),
            // A code block breathes wider than a data column.
            style: context.type.mono.copyWith(height: 1.5),
          ),
        ),
      ),
    );
  }
}

/// The command, with a way to take it. The shape `web_build_dialog` uses, for
/// the reason it gives: this is the real invocation, not a decorative hint.
class _CommandLine extends StatefulWidget {
  const _CommandLine(this.command);

  final String command;

  @override
  State<_CommandLine> createState() => _CommandLineState();
}

class _CommandLineState extends State<_CommandLine> {
  Timer? _copied;

  @override
  void dispose() {
    _copied?.cancel();
    super.dispose();
  }

  void _copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.command)));
    _copied?.cancel();
    setState(() {});
    _copied = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var justCopied = _copied?.isActive ?? false;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.md,
        FwSpacing.sm,
        FwSpacing.xs,
        FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radii.radius),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              widget.command,
              style: context.type.micro.copyWith(
                fontFamily: 'monospace',
                color: colors.mut,
              ),
            ),
          ),
          const Gap(FwSpacing.sm),
          IconButton(
            icon: Icon(
              justCopied ? Icons.check : Icons.content_copy,
              size: FwIconSize.sm,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 22, height: 22),
            tooltip: 'Copy the command',
            onPressed: _copy,
          ),
        ],
      ),
    );
  }
}
