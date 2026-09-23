import 'package:material_ui/material_ui.dart';

import '../../utils/value_stream.dart';
import '../devbar.dart';
import 'service.dart';

class ButtonsOverlay extends StatelessWidget {
  const ButtonsOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    var api = DevbarState.of(context);

    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (context) => ValueStreamBuilder<List<DevbarButtonHandle>>(
            stream: api.ui.buttons,
            builder: (context, snapshot) {
              var buttons = snapshot;
              var tops = buttons.where(
                (b) => b.position == DevbarButtonPosition.topRight,
              );
              var bottoms = buttons.where(
                (b) => b.position == DevbarButtonPosition.bottomRight,
              );

              return SafeArea(
                child: Stack(
                  children: [
                    Positioned(top: 0, right: -10, child: _Buttons(tops)),
                    Positioned(bottom: 0, right: -10, child: _Buttons(bottoms)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Buttons extends StatefulWidget {
  final Iterable<DevbarButtonHandle> buttons;

  const _Buttons(this.buttons);

  @override
  __ButtonsState createState() => __ButtonsState();
}

class __ButtonsState extends State<_Buttons> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var button in widget.buttons)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: StreamBuilder(
              stream: button.refreshStream,
              builder: (context, snapshot) {
                return button.widget;
              },
            ),
          ),
      ],
    );
  }
}
