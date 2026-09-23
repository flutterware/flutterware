import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'shell.dart';

/// Renders the asset fixtures for real: the images and both Roboto weights the
/// pubspec declares.
///
/// The one demo whose subject is the asset pipeline itself, and the fixture
/// `app/integration_test/asset_capture_test.dart` photographs: the images
/// decode *after* the layout that places them, so a capture taken too early
/// shows this demo perfectly minus its pictures. It is also the font specimen
/// `asset_inspector.dart`'s demos cannot carry — a font that renders needs
/// real bytes, and the app bundles none, so the working case lives here.
@Preview(name: 'Asset smoke', wrapper: wrapInApp)
Widget assetSmoke() => Scaffold(
  body: Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 12,
      children: [
        Image.asset('assets/images/logo.png', width: 48),
        Image.asset('assets/images/hero.png', width: 120),
        const Text(
          'Roboto regular',
          style: TextStyle(fontFamily: 'Roboto', fontSize: 24),
        ),
        const Text(
          'Roboto bold',
          style: TextStyle(
            fontFamily: 'Roboto',
            fontWeight: FontWeight.w700,
            fontSize: 24,
          ),
        ),
        const Icon(Icons.image_outlined, size: 32),
      ],
    ),
  ),
);
