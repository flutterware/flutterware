import 'package:material_ui/material_ui.dart';

void main() => runApp(const _EmbedderScene());

class _EmbedderScene extends StatelessWidget {
  const _EmbedderScene();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const _SceneBody(),
    );
  }
}

class _SceneBody extends StatefulWidget {
  const _SceneBody();

  @override
  State<_SceneBody> createState() => _SceneBodyState();
}

class _SceneBodyState extends State<_SceneBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  int _taps = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1565C0),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            RotationTransition(
              turns: _controller,
              child: Container(width: 120, height: 120, color: Colors.white),
            ),
            const SizedBox(height: 32),
            Text(
              'Taps: $_taps',
              style: const TextStyle(color: Colors.white, fontSize: 32),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => setState(() => _taps++),
              child: const Text('Tap me'),
            ),
          ],
        ),
      ),
    );
  }
}
