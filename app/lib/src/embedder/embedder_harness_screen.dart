import 'package:material_ui/material_ui.dart';

import 'embedded_engine.dart';
import 'guest_texture.dart';
import 'input_region.dart';

/// A standalone dev harness that runs the embedder guest and shows its live
/// output in an external texture.
class EmbedderHarnessScreen extends StatefulWidget {
  const EmbedderHarnessScreen({
    super.key,
    required this.appPackageRoot,
    required this.flutterSdkRoot,
  });

  final String appPackageRoot;
  final String flutterSdkRoot;

  @override
  State<EmbedderHarnessScreen> createState() => _EmbedderHarnessScreenState();
}

class _EmbedderHarnessScreenState extends State<EmbedderHarnessScreen> {
  late final EmbeddedEngine _engine = EmbeddedEngine(
    appPackageRoot: widget.appPackageRoot,
    flutterSdkRoot: widget.flutterSdkRoot,
  );
  final FocusNode _focusNode = FocusNode();
  Size? _lastReportedSize;

  @override
  void initState() {
    super.initState();
    _engine.start();
  }

  @override
  void dispose() {
    _engine.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _maybeResize(Size size, double dpr) {
    if (size == _lastReportedSize) return;
    var width = (size.width * dpr).round();
    var height = (size.height * dpr).round();
    if (width < 1 || height < 1) return;
    _lastReportedSize = size;
    _engine.resize(width, height, dpr);
  }

  @override
  Widget build(BuildContext context) {
    var dpr = MediaQuery.of(context).devicePixelRatio;
    return Scaffold(
      appBar: AppBar(title: const Text('Embedder harness')),
      body: AnimatedBuilder(
        animation: _engine,
        builder: (context, _) {
          switch (_engine.phase) {
            case EmbeddedEnginePhase.building:
              return const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Building and starting the embedder guest…'),
                  ],
                ),
              );
            case EmbeddedEnginePhase.error:
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Embedder error:\n${_engine.errorMessage}',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              );
            case EmbeddedEnginePhase.running:
              return LayoutBuilder(
                builder: (context, constraints) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _maybeResize(constraints.biggest, dpr);
                  });
                  return EmbedderInputRegion(
                    engine: _engine,
                    focusNode: _focusNode,
                    child: SizedBox.expand(
                      child: _engine.textureId == null
                          ? const SizedBox()
                          : GuestTexture(textureId: _engine.textureId!),
                    ),
                  );
                },
              );
          }
        },
      ),
    );
  }
}
