import 'package:material_ui/material_ui.dart';

import '../../utils/value_stream.dart';
import '../devbar.dart';

class OverlayDialog extends StatelessWidget {
  const OverlayDialog({super.key});

  @override
  Widget build(BuildContext context) {
    var devbar = DevbarState.of(context);

    return ValueStreamBuilder<int>(
      stream: devbar.ui.overlayVisible,
      builder: (context, snapshot) {
        return Visibility(
          maintainState: true,
          visible: snapshot > 0,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(useMaterial3: true),
            navigatorKey: devbar.ui.overlayNavigatorKey,
            onGenerateRoute: (r) => MaterialPageRoute(
              builder: (context) => IgnorePointer(child: Container()),
            ),
          ),
        );
      },
    );
  }
}
