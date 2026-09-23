import 'package:material_ui/material_ui.dart';

import 'model/asset_scan.dart';

/// An asset kind at its smallest — one glyph, where there is no room to draw
/// the thing itself.
///
/// Shared because the list and the folder sheet both need it and a bundle that
/// says `.svg` is a polyline in one pane and a picture-frame in the other is a
/// bundle with two vocabularies.
IconData assetKindIcon(AssetKind kind) => switch (kind) {
  AssetKind.image => Icons.image_outlined,
  AssetKind.vector => Icons.polyline_outlined,
  AssetKind.font => Icons.text_fields,
  AssetKind.media => Icons.movie_outlined,
  AssetKind.data => Icons.data_object,
  AssetKind.other => Icons.insert_drive_file_outlined,
};
