/// Which translation key is on which screen, and a picture of it.
///
/// Two halves that meet at a catalog name:
///
/// * [indexTranslations] is the seam. Hand it to whatever the project's
///   catalog already funnels its reads through, in a test, and every string
///   it renders can be traced back to the key it came from — by object
///   identity, so nothing is inserted into the text and no pixel moves.
/// * [TranslationExport] reads what the export wrote, typed, so pushing
///   screenshots to a translation service is a few lines rather than a map
///   walk.
///
/// Plain Dart on purpose — nothing here may import `package:flutter`. The
/// script that talks to a translation service runs under a bare `dart run`,
/// exactly like `tool/flutterware.dart` does.
///
/// The seam is also re-exported from `package:flutterware/flutter_test.dart`,
/// which is where a test already imports from.
library;

export 'src/translations/export.dart';
export 'src/translations/index.dart'
    show
        TranslationIndex,
        TranslationKey,
        indexExpansions,
        indexTranslations,
        indexTranslationsIn;
