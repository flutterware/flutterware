import 'dart:typed_data';

import '../bytes.dart';

/// What a document step is compared by: its bytes, less what the format puts
/// in every file to tell it apart from every other.
///
/// That is a PDF's file identifier — the `/ID` pair in its trailer, which the
/// spec asks to be unique per file and `package:pdf` draws from
/// `Random.secure()`. Digested whole, two runs writing the same report never
/// wrote the same bytes, and drift called the step changed on every run. So
/// each `/ID` pair is left out and everything else in the file is still in.
///
/// Both of the forms a string can take in a PDF are recognised, hex `<…>` and
/// literal `(…)`. A literal holding unescaped parentheses is not, and that
/// file is digested whole — a step reported changed, never one reported the
/// same when it is not.
String documentDigest(Uint8List bytes) {
  if (!_isPdf(bytes)) return digestBytes(bytes);
  var text = String.fromCharCodes(bytes);
  var ids = _fileId.allMatches(text).toList();
  if (ids.isEmpty) return digestBytes(bytes);
  var kept = BytesBuilder(copy: false);
  var from = 0;
  for (var id in ids) {
    kept.add(Uint8List.sublistView(bytes, from, id.start));
    kept.add(_idMark);
    from = id.end;
  }
  kept.add(Uint8List.sublistView(bytes, from));
  return digestBytes(kept.takeBytes());
}

bool _isPdf(Uint8List bytes) =>
    bytes.length >= 5 && String.fromCharCodes(bytes, 0, 5) == '%PDF-';

final _idMark = Uint8List.fromList('/ID'.codeUnits);

/// `/ID [<hex> <hex>]`, either string literal instead, any spacing.
final _fileId = RegExp(
  r'/ID\s*\[\s*'
  r'(?:<[0-9A-Fa-f\s]*>|\((?:[^()\\]|\\.)*\))\s*'
  r'(?:<[0-9A-Fa-f\s]*>|\((?:[^()\\]|\\.)*\))\s*\]',
  // An escaped line break is legal inside a literal string.
  dotAll: true,
);
