import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_probes/main.dart';

import 'shell.dart';

/// The unframed half of the `Home page` group. Its phone counterpart is
/// `home_page_mobile.dart`, a separate file so that this one can opt out: the
/// package opens everything on a phone, and `tool/flutterware.dart` declares
/// an empty canvas for this file alone. The group is derived from the shared
/// `group:`, not from the file.

@Preview(name: 'Default', group: 'Home page', wrapper: wrapInApp)
Widget homePageDefault() => const MyHomePage(title: 'Flutter Demo Home Page');
