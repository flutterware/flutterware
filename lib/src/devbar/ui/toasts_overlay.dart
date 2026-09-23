import 'package:material_ui/material_ui.dart';

import '../../utils/value_stream.dart';
import '../devbar.dart';
import 'service.dart';

class ToastsOverlay extends StatelessWidget {
  const ToastsOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    var service = DevbarState.of(context).ui;
    return SafeArea(
      child: ValueStreamBuilder<List<ToastHolder>>(
        stream: service.toasts,
        builder: (context, snapshot) {
          return Stack(
            children: [
              for (var toast in snapshot)
                Align(alignment: toast.alignment, child: toast.content),
            ],
          );
        },
      ),
    );
  }
}

class Toast extends StatelessWidget {
  final Widget child;
  final Color backgroundColor, textColor;

  Toast({
    super.key,
    required this.child,
    Color? backgroundColor,
    Color? textColor,
  }) : backgroundColor = backgroundColor ?? Colors.grey,
       textColor = textColor ?? Colors.white;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(25),
      ),
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: DefaultTextStyle.merge(
        child: child,
        style: TextStyle(color: textColor),
      ),
    );
  }
}
