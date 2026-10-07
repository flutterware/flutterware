import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/shell/about_screen.dart';

import 'app_theme.dart';

/// The shell's about screen, which is the one screen of the studio with
/// nothing to feed it: no session, no recording, no fixture. Here so it can
/// be looked at in both builds without opening a worktree.
@Preview(name: 'Light', group: 'About screen', wrapper: wrapInAppTheme)
Widget aboutScreen() => const AboutScreen();

@Preview(name: 'Dark', group: 'About screen', wrapper: wrapInDarkTheme)
Widget aboutScreenDark() => const AboutScreen();
