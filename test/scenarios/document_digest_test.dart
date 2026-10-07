import 'dart:convert';
import 'dart:typed_data';

import 'package:flutterware/src/bytes.dart';
import 'package:flutterware/src/scenarios/document_digest.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:test/test.dart';

/// What a document step is compared by across two runs.
///
/// Reported by a consumer: the PDF a flow exported was flagged as changed by
/// drift on every run, and the two files differed only in the trailer's
/// `/ID`, which `package:pdf` draws from `Random.secure()`.
void main() {
  Future<Uint8List> report(String text) async {
    var document = pw.Document()..addPage(pw.Page(build: (_) => pw.Text(text)));
    return document.save();
  }

  test('two PDFs of the same report digest the same', () async {
    var first = await report('Total: 12.40');
    var second = await report('Total: 12.40');
    // The premise: the files themselves are not the same.
    expect(first, isNot(second));

    expect(documentDigest(first), documentDigest(second));
  });

  test('a PDF whose content moved digests differently', () async {
    expect(
      documentDigest(await report('Total: 12.40')),
      isNot(documentDigest(await report('Total: 12.41'))),
    );
  });

  test('a literal-string identifier is left out too', () {
    Uint8List pdf(String id) => Uint8List.fromList(
      latin1.encode(
        '%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n'
        '<</Root 1 0 R /ID [($id) ($id)]>>\n%%EOF\n',
      ),
    );
    expect(documentDigest(pdf(r'a\)b')), documentDigest(pdf('xyz')));
  });

  test('anything that is not a PDF is digested whole', () {
    var json = Uint8List.fromList(utf8.encode('{"/ID": [<00> <00>]}'));
    expect(documentDigest(json), digestBytes(json));
  });
}
