import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:vector_graphics/vector_graphics.dart';

import 'shell.dart';

/// The asset-transformer half of the pipeline: an SVG compiled to the binary
/// `vector_graphics` format at build time and read back through the bundle.
///
/// Its paint depends on work that finishes on the **real** event loop, which is
/// the shape a widget-test binding cannot wait for by pumping — see
/// `landRealWork` in `lib/src/scenarios/real_work.dart`. So this is also the
/// entry that says whether a catalog render is looking at a finished picture.
@Preview(name: 'Vector smoke', wrapper: wrapInApp)
Widget vectorSmoke() => const Scaffold(
  body: Center(
    child: SizedBox(
      width: 140,
      height: 168,
      child: VectorGraphic(
        loader: AssetBytesLoader('assets/icons/illustration.svg'),
      ),
    ),
  ),
);
