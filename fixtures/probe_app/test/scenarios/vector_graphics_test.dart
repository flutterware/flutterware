import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:vector_graphics/vector_graphics.dart';

/// The instance the general bug was found through: a `VectorGraphic` mounted
/// one step after `pumpWidget`, photographed by the step that mounts it.
///
/// It renders through an asset transformer, so this is the real path — the
/// binary format a build ships, read from the engine — rather than a
/// simulation of it. In the runner's lane that read completes on the **real**
/// event loop, which no settle policy can reach; see
/// `test/scenarios/real_async_paint_test.dart` in flutterware itself for the
/// same shape with no SVG in it.
void main() {
  scenario('Artwork on the step that mounts it', (s) async {
    await s.pumpWidget(const _App());

    await s.tap('Show', shot: Shot('Mounted'));
    // The placeholder is the assertable half of the picture: while it is on
    // screen the decode has not landed, and the frame this step photographed
    // is one the tree was about to replace.
    expect(find.text('decoding'), findsNothing);

    await s.screen('One step later');
  });
}

Widget _decoding(BuildContext context) => const Text('decoding');

class _App extends StatefulWidget {
  const _App();

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  var _shown = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: () => setState(() => _shown = true),
            child: const Text('Show'),
          ),
          if (_shown)
            const SizedBox(
              width: 140,
              height: 168,
              child: VectorGraphic(
                loader: AssetBytesLoader('assets/icons/illustration.svg'),
                placeholderBuilder: _decoding,
              ),
            ),
        ],
      ),
    ),
  );
}
