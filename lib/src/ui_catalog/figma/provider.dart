import 'package:material_ui/material_ui.dart';

import 'initializer.dart';
import 'service.dart';

class FigmaProvider extends StatefulWidget {
  final FigmaUserConfig userConfig;
  final Widget child;

  const FigmaProvider({
    super.key,
    required this.userConfig,
    required this.child,
  });

  @override
  State<FigmaProvider> createState() => FigmaProviderState();

  static FigmaProviderState of(BuildContext context) =>
      context.findAncestorStateOfType<FigmaProviderState>()!;
}

class FigmaProviderState extends State<FigmaProvider> {
  late FigmaService service;
  bool _isInitialized = false;

  @override
  Widget build(BuildContext context) {
    return FigmaServiceInitializer(
      config: widget.userConfig,
      builder: (service) {
        this.service = service;
        _isInitialized = true;
        return widget.child;
      },
    );
  }

  @override
  void dispose() {
    if (_isInitialized) {
      service.dispose();
    }
    super.dispose();
  }
}
