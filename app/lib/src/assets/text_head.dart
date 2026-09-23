import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../ui/theme.dart';
import 'model/asset_catalog.dart';

/// The first few thousand bytes of a text asset, for showing what it is.
///
/// **A range read, not a file read.** A bundle's translations file can be a
/// megabyte, and the question a hover asks — *is this the English one* — is
/// answered by its first fifteen lines. `openRead(0, n)` takes those and stops,
/// so resting on a row costs the same whatever the file weighs.
///
/// Not pretty-printed, deliberately. The detail pane re-indents a minified
/// document because you went there to read it; here the point is recognition,
/// and re-encoding the head of a document that has no end would fail anyway.
class AssetTextHead extends StatefulWidget {
  const AssetTextHead({
    super.key,
    required this.asset,
    required this.lines,
    this.bytes,
  });

  final ResolvedAsset asset;

  /// How many lines to keep. The rest is dropped after the read, which has
  /// already stopped at [_headBytes].
  final int lines;

  /// Supplied by a demo; null in the app, where the file is read from disk.
  final Uint8List? bytes;

  /// Enough for the first screenful of any document, at the cost of one page
  /// of disk.
  static const _headBytes = 8192;

  @override
  State<AssetTextHead> createState() => _AssetTextHeadState();
}

class _AssetTextHeadState extends State<AssetTextHead> {
  String? _head;
  var _unreadable = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(AssetTextHead old) {
    super.didUpdateWidget(old);
    if (old.asset.key != widget.asset.key) _read();
  }

  Future<void> _read() async {
    _head = null;
    _unreadable = false;
    try {
      var bytes =
          widget.bytes ??
          await File(widget.asset.main.path)
              .openRead(0, AssetTextHead._headBytes)
              .fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      // `allowMalformed`, because a range read almost always cuts a multi-byte
      // character in half at the far end and a replacement glyph there is
      // better than no preview at all.
      var text = utf8.decode(bytes, allowMalformed: true);
      var head = const LineSplitter().convert(text).take(widget.lines);
      if (mounted) setState(() => _head = head.join('\n'));
    } catch (_) {
      if (mounted) setState(() => _unreadable = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unreadable) {
      return Text(
        'Not readable as text.',
        style: context.type.micro.copyWith(color: context.colors.mut),
      );
    }
    var head = _head;
    if (head == null) return const SizedBox.shrink();
    return Text(
      head,
      maxLines: widget.lines,
      overflow: TextOverflow.ellipsis,
      style: context.type.micro.copyWith(fontFamily: 'monospace'),
    );
  }
}
