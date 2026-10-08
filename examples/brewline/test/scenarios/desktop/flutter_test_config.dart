import 'dart:async';

import 'package:flutterware/flutter_test.dart';
import 'package:brewline/shop/mini_markdown.dart';
import 'package:brewline/shop/shop_strings.dart';

import '../profiles.dart';

/// The same hook as `../mobile/`, naming the other profile — which is the
/// whole per-folder story: opening a scenario from this folder frames a
/// window, opening one from that folder frames a phone, and no scenario says
/// a word about devices.
Future<void> testExecutable(FutureOr<void> Function() testMain) {
  // **The translation seam, wired in three lines.**
  //
  // Every value the shop's catalog hands out now arrives as a distinct
  // string object per key, so the capture can say which key put which words on
  // which screen — with nothing inserted into the text and no pixel moved.
  // Test-only: these hooks are null in production and cost nothing there.
  ShopStrings.wrapValue = indexTranslations('shop');
  // Two things identity alone cannot follow, each closed by routing the key
  // rather than guessing it back out of the words. A substitution builds a new
  // string, so the catalog names the key at the one place that still knows
  // it; and `MiniMarkdown` reparses its source into spans of its own, so the
  // walk reads the original off the widget instead of below it.
  ShopStrings.wrapExpanded = indexExpansions('shop');
  indexTranslationsIn<MiniMarkdown>((widget) => widget.data);
  return runScenarios(testMain, profile: desktop);
}
