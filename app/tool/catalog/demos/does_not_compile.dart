// A fixture, not a demo. `integration_test/compiler_daemon_test.dart` asserts
// that this entry is quarantined rather than fatal, and that the quarantine
// carries the compiler's error. Repair is asserted against a fixture that test
// writes itself, so this file can stay permanently broken.
//
// It is excluded from analysis in the root `analysis_options.yaml`, because the
// whole point of it is that it does not compile.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/ui_catalog.dart';

@Preview(name: 'Does not compile')
Widget doesNotCompile() => ThisTypeDoesNotExist(missing: 1);
