import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// A flow whose point is the documents it produces, rather than the screen
/// that announces them.
///
/// Not every beat of a story is a screen. `s.document` is a step whose picture
/// is the thing the flow made — a receipt, a payload, an email body — and
/// `s.notification` is a step whose picture is the push the backend sent,
/// drawn the way the recipient's phone would draw it.
void main() {
  scenario('Exports a receipt', (s) async {
    await s.pumpWidget(const _ReceiptApp());
    // What the flow sent. A real one gets these from the app —
    // `tester.runAsync(() => report.generatePdf())` and its like.
    await s.document(
      'request',
      utf8.encode('{"receipt": 1042}'),
      fileName: 'request.json',
      mimeType: 'application/json',
    );
    await s.tap('Export');
    await s.screen('Exported');
    // What came back. A step of its own, in the place it happened — there is
    // no screen showing it, which is exactly why it is not one.
    await s.document(
      'receipt',
      utf8.encode('{"total": 12.5, "currency": "EUR"}'),
      fileName: 'receipt.json',
      mimeType: 'application/json',
    );
    // The push the backend would have sent when the export landed. Three
    // strings, typed — a viewer draws a banner over the screen before it.
    await s.notification(
      'Receipt #1042 is ready to download',
      title: 'Receipts',
    );
    await s.document(
      'summary',
      utf8.encode('Receipt #1042\nTotal 12.50 EUR\nPaid by card'),
      fileName: 'summary.txt',
      mimeType: 'text/plain',
    );
  });
}

class _ReceiptApp extends StatefulWidget {
  const _ReceiptApp();

  @override
  State<_ReceiptApp> createState() => _ReceiptAppState();
}

class _ReceiptAppState extends State<_ReceiptApp> {
  var _exported = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: _exported
              ? const Text('Receipt exported')
              : TextButton(
                  onPressed: () => setState(() => _exported = true),
                  child: const Text('Export'),
                ),
        ),
      ),
    );
  }
}
