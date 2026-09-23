import 'package:material_ui/material_ui.dart';

import 'service.dart';

class FigmaServiceInitializer extends StatefulWidget {
  final FigmaUserConfig config;
  final Widget Function(FigmaService) builder;

  const FigmaServiceInitializer({
    super.key,
    required this.config,
    required this.builder,
  });

  @override
  State<FigmaServiceInitializer> createState() =>
      _FigmaServiceInitializerState();
}

class _FigmaServiceInitializerState extends State<FigmaServiceInitializer> {
  late Future<FigmaService> _future;

  @override
  void initState() {
    super.initState();

    _future = FigmaService.load(widget.config);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FigmaService>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SizedBox(height: 300, child: ErrorWidget(snapshot.error!));
        } else if (snapshot.connectionState != ConnectionState.done) {
          return Center(child: CircularProgressIndicator());
        } else {
          var data = snapshot.requireData;
          return widget.builder(data);
        }
      },
    );
  }
}
