import 'package:material_ui/material_ui.dart';

import 'figma/provider.dart';
import 'figma/service.dart';

class Figma extends StatefulWidget {
  final List<String> links;
  final Widget child;

  const Figma({super.key, required this.links, required this.child});

  @override
  State<Figma> createState() => FigmaState();
}

class FigmaState extends State<Figma> {
  late FigmaService _service;

  @override
  void initState() {
    super.initState();
    _service = FigmaProvider.of(context).service;
    _service.addLinksFromCode(this, widget.links);
  }

  @override
  void didUpdateWidget(covariant Figma oldWidget) {
    super.didUpdateWidget(oldWidget);
    _service.addLinksFromCode(this, widget.links);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void dispose() {
    _service.removeLinksFromCode(this);
    super.dispose();
  }
}
