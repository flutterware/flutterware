import 'package:material_ui/material_ui.dart';

class MyScreenToAnimate extends StatefulWidget {
  const MyScreenToAnimate({super.key});

  @override
  State<MyScreenToAnimate> createState() => _MyScreenToAnimateState();
}

class _MyScreenToAnimateState extends State<MyScreenToAnimate>
    with TickerProviderStateMixin {
  late final timeline = TimelineGenerated(this);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        timeline.textField1(TextField()),
        timeline.textField2(TextField()),
        timeline.button(
          ElevatedButton(onPressed: () {}, child: Text('The button')),
        ),
      ],
    );
  }
}

class TimelineGenerated {
  final TickerProvider vsync;
  late final controller = AnimationController(vsync: vsync);

  TimelineGenerated(this.vsync);

  // Wrap with a widget that we will animate
  Widget textField1(Widget inner) => inner;
  Widget textField2(Widget inner) => inner;
  Widget button(Widget inner) => inner;
}
