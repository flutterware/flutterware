// GENERATED — do not edit.
// Imports carried from the demo file: the annotation is written in *its* scope,
// so anything the annotation names has to resolve here too.
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/previews.dart';
import 'package:brewline/shop/shop_app.dart';
// Unconditional: the getters below are typed, and a demo file is not obliged
// to import widgets itself. `widget_previews.dart` is here for the same reason
// and for one more — a demo annotated with Flutter's own `@Preview` never
// imports `ui_catalog.dart` at all.
import 'package:flutter/widgets.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/ui_catalog.dart';

// The demo file twice, and both are load-bearing. Prefixed, because fwBuilder
// has to name the entry unambiguously. Unprefixed, because the annotation may
// name something the demo file *declares* rather than imports — a wrapper
// written beside the demo it wraps is the ordinary case — and a file does not
// import itself, so nothing else would put that in scope.
//
// Together these reproduce the demo's own scope, which is the one the
// annotation was written in. The gap that remains is privacy: a `_kName` in the
// annotation is visible where it was written and not here.
import '../../../examples/brewline/demo/shop.dart';
import '../../../examples/brewline/demo/shop.dart' as fw5;

// The annotation, evaluated as Dart rather than interpreted statically.
// Kept whole rather than reduced: the entrypoint calls Flutter's own
// `transform()` on it, which is where a subclass folds its extra state into a
// plain `Preview` — so what a subclass carries has to still be here to fold.
//
// Typed as `Preview`, the annotation's own type, so a project's registered
// subclass of it lands here too. Declaring the subtype instead is what once
// turned a plain `@Preview` — which the scan has always accepted — into a
// compile error naming generated code.
//
// Getters, not consts. A const holding a function tear-off — every `wrapper:`
// is one — is inlined into whichever library reads it, so the entrypoint's
// constant pool ends up referring to a procedure in the demo's own file. A
// reload that carries only the entrypoint then has to re-resolve that
// reference against a library it does not contain, and the guest renders
// `Lookup failed: <wrapper> in @methods in file:...` instead of the demo.
// Behind a getter there is nothing to inline and nothing to re-resolve.
Preview get fwPreview =>
    Preview(name: 'Cart', group: 'Brewline', wrapper: wrapWithFullCart);

Widget Function() get fwBuilder => fw5.shopCart;
