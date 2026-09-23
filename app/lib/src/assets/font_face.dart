import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'model/asset_catalog.dart';

/// A font asset, registered with the engine once and remembered.
///
/// **The registry only grows.** `FontLoader` publishes a family process-wide
/// and there is no unregister, so the one policy that stays bounded is to load
/// each font file at most once and hand the same family name back for ever
/// after. That is what makes it safe to draw a specimen on *hover*: the
/// ceiling is the number of font files the project has, which is a handful,
/// rather than the number of times a hand crossed the fonts directory.
///
/// Keyed by asset key, which is also what the family is named after, so a
/// second load of the same file would have overwritten itself anyway — the
/// cache is what stops it costing a parse each time, and stops the specimen
/// flashing empty on a font already on screen a moment ago.
class AssetFontCache {
  AssetFontCache._();

  static final _loading = <String, Future<String?>>{};

  /// Whether [key] is already registered, so a caller can draw it in its final
  /// face on the first frame rather than after one.
  static bool isLoaded(String key) => _families.containsKey(key);
  static final _families = <String, String>{};

  /// The family name for [asset], or null when the bytes are not a font.
  ///
  /// [bytes] is the demo seam: supplied, nothing is read from disk.
  static Future<String?> load(ResolvedAsset asset, {Uint8List? bytes}) {
    var key = asset.key;
    if (_families[key] case var family?) return Future.value(family);
    return _loading[key] ??= _load(key, asset.main.path, bytes);
  }

  static Future<String?> _load(
    String key,
    String path,
    Uint8List? supplied,
  ) async {
    try {
      var bytes = supplied ?? await File(path).readAsBytes();
      // Checked before loading, because `FontLoader` does not reliably refuse:
      // hand it a PNG and the engine may register a family with no glyphs,
      // which draws as a blank panel that looks like a working preview of an
      // empty font.
      if (!looksLikeFont(bytes)) return null;
      var family = 'fw-specimen-$key';
      await (FontLoader(
        family,
      )..addFont(Future.value(bytes.buffer.asByteData()))).load();
      return _families[key] = family;
    } catch (_) {
      return null;
    } finally {
      unawaited(_loading.remove(key));
    }
  }
}

/// Whether [bytes] open with a signature the engine could plausibly read.
bool looksLikeFont(Uint8List bytes) {
  if (bytes.length < 4) return false;
  var tag = bytes.buffer.asByteData().getUint32(0);
  return const {
    0x00010000, // TrueType
    0x74727565, // 'true'
    0x4F54544F, // 'OTTO'
    0x74746366, // 'ttcf'
    0x774F4646, // 'wOFF'
    0x774F4632, // 'wOF2'
  }.contains(tag);
}

/// Draws [builder] in [asset]'s own face, once it has one.
///
/// Until then — and for a file that turns out not to be a font — it draws
/// [fallback], which is what keeps a tile the same size before and after the
/// glyphs arrive.
class AssetFontFace extends StatefulWidget {
  const AssetFontFace({
    super.key,
    required this.asset,
    required this.builder,
    required this.fallback,
    this.bytes,
  });

  final ResolvedAsset asset;

  /// Supplied by a demo; null in the app, where the file is read from disk.
  final Uint8List? bytes;

  final Widget Function(BuildContext context, String family) builder;
  final Widget fallback;

  @override
  State<AssetFontFace> createState() => _AssetFontFaceState();
}

class _AssetFontFaceState extends State<AssetFontFace> {
  String? _family;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AssetFontFace old) {
    super.didUpdateWidget(old);
    if (old.asset.key != widget.asset.key) _load();
  }

  void _load() {
    // Synchronously for a font already registered, so a row you come back to
    // draws in its face on the first frame instead of blinking through the
    // fallback.
    if (AssetFontCache.isLoaded(widget.asset.key)) {
      _family = 'fw-specimen-${widget.asset.key}';
      return;
    }
    _family = null;
    unawaited(
      AssetFontCache.load(widget.asset, bytes: widget.bytes).then((family) {
        if (mounted) setState(() => _family = family);
      }),
    );
  }

  @override
  Widget build(BuildContext context) =>
      _family == null ? widget.fallback : widget.builder(context, _family!);
}
