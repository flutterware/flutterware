import 'semantics_node.dart';

/// The captured semantics tree read as a script: the nodes a screen reader
/// stops on, in traversal order, each reduced to what it announces — plus
/// what the label audits found wrong with it.
///
/// A pure function of a [SemanticsSnapshotNode] tree, so it serves every
/// host the capture reaches — a scenario step, the catalog's live read, a
/// web export — and every run that ever wrote a `.semantics.json`,
/// retroactively. It deliberately speaks the *tree's* words, not a
/// particular reader's: VoiceOver and TalkBack phrase roles and states each
/// their own way, and impersonating either would promise more than a
/// snapshot knows.
class SemanticsTranscript {
  SemanticsTranscript(this.utterances);

  /// Reduces [root] to the rows a reader would speak, flagging as it goes.
  factory SemanticsTranscript.of(SemanticsSnapshotNode root) {
    var utterances = <TranscriptUtterance>[];
    void walk(SemanticsSnapshotNode node) {
      // What assistive tech skips, the script skips.
      if (!node.flags.contains('isHidden')) {
        var words = _spokenWords(node);
        if (words.isNotEmpty || node.hint.isNotEmpty || _isInteractive(node)) {
          utterances.add(
            TranscriptUtterance._(
              index: utterances.length + 1,
              node: node,
              words: words,
            ),
          );
        }
      }
      node.children.forEach(walk);
    }

    walk(root);
    _audit(utterances);
    return SemanticsTranscript(utterances);
  }

  final List<TranscriptUtterance> utterances;

  int get findingCount =>
      utterances.fold(0, (sum, u) => sum + u.findings.length);
}

/// One stop of the reading: a node reduced to its announcement.
class TranscriptUtterance {
  TranscriptUtterance._({
    required this.index,
    required this.node,
    required this.words,
  });

  /// 1-based position in the reading — what a duplicate finding points back
  /// to.
  final int index;

  final SemanticsSnapshotNode node;

  /// The words themselves: label, value and tooltip, in the order the
  /// framework hands them to the platform. Empty when the node reaches the
  /// reader with nothing to say — which for an interactive node is finding
  /// number one.
  final String words;

  String? get role => node.role;
  String get hint => node.hint;

  final findings = <TranscriptFinding>[];

  bool get isInteractive => _isInteractive(node);
}

enum TranscriptSeverity { warning, error }

class TranscriptFinding {
  TranscriptFinding({
    required this.severity,
    required this.badge,
    required this.message,
  });

  final TranscriptSeverity severity;

  /// Two or three words for the row's pill; [message] carries the why.
  final String badge;
  final String message;
}

String _spokenWords(SemanticsSnapshotNode node) => [
  node.label,
  node.value,
  node.tooltip,
].where((part) => part.isNotEmpty).join(', ');

bool _isInteractive(SemanticsSnapshotNode node) =>
    node.actions.contains('tap') ||
    node.actions.contains('longPress') ||
    node.flags.contains('isButton') ||
    node.flags.contains('isTextField') ||
    node.flags.contains('isSlider') ||
    node.flags.contains('isLink');

/// Letters or digits, any script — what makes a label *words* rather than a
/// symbol the platform names on its own (☕ becomes "hot beverage", ♡ becomes
/// "white heart suit").
final _readableCharacter = RegExp(r'[\p{L}\p{N}]', unicode: true);

void _audit(List<TranscriptUtterance> utterances) {
  // First interactive utterance per announcement, for the duplicate check —
  // two buttons saying the same thing are indistinguishable to a listener,
  // two static texts are merely repetitive.
  var seen = <String, TranscriptUtterance>{};

  for (var utterance in utterances) {
    var words = utterance.words;

    if (utterance.isInteractive && words.isEmpty && utterance.hint.isEmpty) {
      utterance.findings.add(
        TranscriptFinding(
          severity: TranscriptSeverity.error,
          badge: 'nothing to read',
          message:
              'This ${utterance.role ?? 'control'} reaches a screen reader '
              'with no label, value, tooltip or hint, so it is announced only '
              'as "${utterance.role ?? 'unknown'}".',
        ),
      );
      continue;
    }

    if (words.isNotEmpty && !_readableCharacter.hasMatch(words)) {
      utterance.findings.add(
        TranscriptFinding(
          severity: TranscriptSeverity.warning,
          badge: 'symbol label',
          message:
              'The label has no words, so a screen reader falls back to the '
              'symbol\'s own name: "☕" is read as "hot beverage". Give the '
              'control a spoken label.',
        ),
      );
    }

    if (utterance.role case var role?
        when RegExp('\\b$role\\b', caseSensitive: false).hasMatch(words)) {
      utterance.findings.add(
        TranscriptFinding(
          severity: TranscriptSeverity.warning,
          badge: 'role in label',
          message:
              'The label already says "$role", and the reader adds the role '
              'again, so it is announced as "$words, $role".',
        ),
      );
    }

    if (utterance.isInteractive && words.isNotEmpty) {
      var key = words.trim().toLowerCase();
      if (seen[key] case var first?) {
        utterance.findings.add(
          TranscriptFinding(
            severity: TranscriptSeverity.warning,
            badge: 'duplicate of ${first.index}',
            message:
                'Announced exactly like utterance ${first.index}, so a '
                'listener cannot tell the two controls apart. Give them '
                'distinct labels ("$words" twice says which kind of control, '
                'not which one).',
          ),
        );
      } else {
        seen[key] = utterance;
      }
    }
  }
}
