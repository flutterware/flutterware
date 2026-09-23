import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_probes/main.dart';

import 'shell.dart';

/// The home screen on a phone, framed the way the whole package is.
///
/// `PreviewCanvas` takes a path prefix and a file is a legal one, which is how
/// a single preview differs from the entries beside it: its sibling in
/// `home_page.dart` is the one file declared back onto the plain rectangle.
/// The pair is the contrast.
@Preview(name: 'On a phone', group: 'Home page', wrapper: wrapInApp)
Widget homePageMobile() => const MyHomePage(title: 'Home');
