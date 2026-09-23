import 'package:material_ui/material_ui.dart';

// Tool:
//  - generate the widget in a file to show the user how it looks
//  - generate a main() file. ie: main() => runAnimationPreview(MyScreenToAnimate());
//  - Tool, start the file ("flutter run -d xxx")
//        => allow to run it on phone or desktop
//  - runPreview, connect back to the editor and get updates
//  - Tool show the editor and send animation info (with current position)
//     in real time to the device.
//    Animation type: opacity, translation, scale, rotation, anchor, text
//     Translation should be expressable related to screensize

// User:
class MyScreenToAnimate extends StatelessWidget {
  const MyScreenToAnimate({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AnimatableWidget('TextField1', TextField()),
        AnimatableWidget('TextField2', TextField()),
        AnimatableWidget(
          'Button',
          ElevatedButton(onPressed: () {}, child: Text('The button')),
        ),
      ],
    );
  }
}

// lib
class AnimatableWidget extends StatelessWidget {
  const AnimatableWidget(String name, Widget child, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container();
  }
}

// Generated
class TimelineGenerated extends StatelessWidget {
  final AnimationController controller;
  final MyScreenToAnimate child;

  const TimelineGenerated({
    super.key,
    required this.child,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
