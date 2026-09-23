import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../third_party/flutter_highlight/lib/flutter_highlight.dart';
import '../../third_party/flutter_highlight/lib/themes/darcula.dart';

final _jsonEncoder = JsonEncoder.withIndent('  ');

class JsonViewer extends StatelessWidget {
  final dynamic object;

  JsonViewer(this.object, {super.key});

  @override
  Widget build(BuildContext context) {
    //TODO(xha): use the widget InteractiveViewer: https://github.com/flutter/flutter/issues/20175
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: HighlightView(
        _jsonEncoder.convert(object),
        padding: EdgeInsets.all(10),
        language: 'json',
        theme: darculaTheme,
      ),
    );
  }
}
