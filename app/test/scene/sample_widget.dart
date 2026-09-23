// The app widget `sample.scene.dart` places — on this side of the file,
// where a widget belongs, rather than in a map of strings to lambdas.
import 'package:material_ui/material_ui.dart';

class SampleChip extends StatelessWidget {
  const SampleChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(color: Color(0xFF4A64D0)),
    child: Text(label),
  );
}
