import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/plugins/native/previews_core.dart';
import 'package:path/path.dart' as p;

/// What a picture is called when nobody said where to put it.
///
/// The name spells the address, and an address has no length limit where a
/// file name has one of 255 bytes. `steps` is the axis that found it: four of
/// them, two aimed at an `nth` target, made a name the file system refused,
/// and the capture threw after rendering a picture it could not write down.
void main() {
  Address address({
    String entry = 'tool/catalog/demos/buttons.dart#Buttons',
    Map<String, String> axes = const {},
  }) => Address(
    worktree: 'main',
    plugin: 'flutterware.previews',
    segments: ['app', entry],
    axes: axes,
  );

  /// The `steps` axis as the address carries it: the list as JSON.
  String steps(List<Map<String, String>> list) => jsonEncode(list);

  String target(Object value) => jsonEncode(value);

  var fourSteps = steps([
    {
      'target': target({
        'nth': {
          'target': {'tooltip': 'Edit'},
          'index': 1,
        },
      }),
      'verb': 'tap',
    },
    {'target': 'Twice a week or more', 'verb': 'tap'},
    {
      'target': target({
        'nth': {
          'target': {'tooltip': 'Edit'},
          'index': 2,
        },
      }),
      'verb': 'tap',
    },
    {'target': 'Save and continue', 'verb': 'tap'},
  ]);

  test('a name that fits spells the entry and every axis', () {
    expect(
      PreviewsCore.defaultFileName(address()),
      'app_tool_catalog_demos_buttons_dart_Buttons.png',
    );
    expect(
      PreviewsCore.defaultFileName(
        address(axes: {'width': '420', 'height': '320', 'device': 'iphone-16'}),
      ),
      'app_tool_catalog_demos_buttons_dart_Buttons'
      '__device-iphone_16_height-320_width-420.png',
    );
  });

  test('a short step list is still spelled out', () {
    var name = PreviewsCore.defaultFileName(
      address(
        axes: {
          'steps': steps([
            {'target': 'Save', 'verb': 'tap'},
          ]),
        },
      ),
    );
    expect(name, endsWith('__steps-_target_Save_verb_tap_.png'));
  });

  test('a long step list is cut to its head and a digest', () {
    var name = PreviewsCore.defaultFileName(
      address(
        axes: {
          'device': 'iphone-16',
          'height': '2556',
          'steps': fourSteps,
          'width': '1179',
        },
      ),
    );
    expect(
      name,
      matches(
        RegExp(
          r'^app_tool_catalog_demos_buttons_dart_Buttons'
          r'__device-iphone_16_height-2556'
          r'_steps-_target_nth_target_tooltip_Edit-[0-9a-f]{8}'
          r'_width-1179\.png$',
        ),
      ),
    );
  });

  test('two step lists that open alike are two names', () {
    String nameFor(String last) => PreviewsCore.defaultFileName(
      address(
        axes: {
          'steps': steps([
            {'target': 'Twice a week or more', 'verb': 'tap'},
            {'target': 'Save and continue', 'verb': 'tap'},
            {'target': last, 'verb': 'tap'},
          ]),
        },
      ),
    );

    expect(nameFor('Yes'), isNot(nameFor('No')));
    expect(nameFor('Yes'), nameFor('Yes'));
  });

  test('a name made of many long values still fits, pages included', () {
    var long = address(
      entry: 'tool/catalog/demos/${'nested/' * 20}buttons.dart#Buttons',
      axes: {
        'steps': fourSteps,
        for (var i = 0; i < 12; i++)
          'knob.label$i': 'A heading long enough to wrap onto a second line $i',
        'width': '1179',
      },
    );
    var name = PreviewsCore.defaultFileName(long);
    var page = '${p.withoutExtension(name)}.page-9999.png';
    expect(utf8.encode(page).length, lessThanOrEqualTo(255));

    // Asked of the file system rather than of a constant: it is the one that
    // refuses.
    var directory = Directory.systemTemp.createTempSync('default_file_name');
    addTearDown(() => directory.deleteSync(recursive: true));
    File(p.join(directory.path, name)).writeAsBytesSync(const []);
    File(p.join(directory.path, page)).writeAsBytesSync(const []);

    // What was cut still tells two addresses apart.
    var other = PreviewsCore.defaultFileName(
      long.copyWith(axes: {...long.axes, 'width': '1180'}),
    );
    expect(other, isNot(name));
    expect(other.length, name.length);
  });

  test('a long value outside ASCII is cut like any other', () {
    var name = PreviewsCore.defaultFileName(
      address(axes: {'knob.label': 'Commande passée, merci. ' * 8}),
    );
    expect(
      name,
      matches(
        RegExp(
          r'__knob_label-Commande_pass_e_merci_Commande_-[0-9a-f]{8}\.png$',
        ),
      ),
    );
    expect(utf8.encode(name).length, name.length);
  });
}
