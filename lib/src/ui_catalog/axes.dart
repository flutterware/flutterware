import 'dart:convert';
import 'dart:developer' as developer;

import '../guest_extensions.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'axis.dart';
import 'knob.dart';

/// The app-wide switches a project's shell offers — a theme, a locale, a
/// flavour — drawn in the catalog's top bar.
///
/// Axes, not knobs, and the word is the one the rest of the tool uses:
/// `--axes=theme=dark`, `describe --axes=true`, `axes:` on an artifact's
/// address. This was called `TopBarState`, which named where the control is
/// drawn rather than what it is, leaving nothing in the API to connect it to
/// any of those. What makes an axis a different thing from a knob is that it
/// belongs to the shell rather than to the entry: it persists as you move
/// between entries, its values are a named set, and a matrix can be taken over
/// it — the same sense in which a scenario run is crossed over devices and
/// languages.
///
/// Handed to [PreviewShell]'s builder rather than read off a [BuildContext],
/// and that confinement is the design rather than an accident of it. An axis
/// outlives the entry on screen because it belongs to the shell, so a stray
/// declaration from somewhere deep inside a demo would go on being offered
/// after the demo that made it was gone, and a subtree built lazily — below a
/// list, behind a tab — would make the top bar grow as you navigated. Knobs
/// can afford to be read from anywhere precisely because they reset with the
/// entry. These cannot.
///
/// Every method answers with `defaultValue` when nothing is driving it, so the
/// same shell behaves identically in the real app and in Flutter's own
/// previewer as it does here.
abstract class PreviewAxes {
  /// A choice between named options, label to value.
  ///
  /// Only the labels cross the wire — see [KnobDescriptor.options] — so the
  /// values behind them may be of any type at all, and the labels are whatever
  /// reads well rather than whatever an identifier happened to be called.
  ///
  /// [style] is how the top bar draws it. A segmented control suits a switch
  /// you flip back and forth while looking — Light and Dark — because both
  /// options stay on the bar and a flip is one click rather than two.
  T picker<T>(
    String name,
    Map<String, T> options,
    T defaultValue, {
    PickerStyle style = PickerStyle.dropdown,
  });

  /// A switch. A `bool` is a closed set of two, which is all an axis needs.
  bool flag(String name, bool defaultValue);
}

/// The guest's side of the top bar: what the shell on screen declared, and the
/// two extensions the host reads and writes them through.
///
/// Deliberately the mirror image of `CatalogKnobs`. Both learn what there
/// is by *running* the thing that declares it; what separates them is scope.
/// A knob is filed under the entry that asked for it and goes away with it, an
/// axis is filed under its shell and does not.
class CatalogAxes implements PreviewAxes {
  CatalogAxes._();

  static final instance = CatalogAxes._();

  /// Bumped when a selection changes, so the shell has something to rebuild on.
  final revision = ValueNotifier<int>(0);

  /// What the shell on screen declared, in the order it declared them.
  final _declared = <String, KnobDescriptor>{};

  /// Selections, by shell and then by axis name.
  ///
  /// Nested rather than flat because the host pushes the selections for *every*
  /// shell it knows about, at any time: it cannot know which shell an entry
  /// uses until that entry has built and said so, and waiting to find out would
  /// show a frame of defaults first. A flat map would make two shells that both
  /// call something `flavor` inherit each other's.
  final _selected = <String, Map<String, Object?>>{};

  String? _shellId;
  String? _entryId;

  /// Forgets what the previous entry's shell declared.
  ///
  /// Called from the guest when the entry changes, so that an entry whose
  /// wrapper is *not* a shell reports having no axes immediately, rather than
  /// leaving the last shell's on the bar until something replaces them.
  /// Selections are untouched — they belong to the shell, which is what makes
  /// them survive an entry change.
  void resetFor(String entryId) {
    if (_entryId == entryId) return;
    _entryId = entryId;
    _shellId = null;
    _declared.clear();
  }

  /// Opens a shell's declaration pass and answers the object it declares
  /// through. Called by [PreviewShell] and nothing else.
  ///
  /// Shells do not nest: the pass is singular, so a [PreviewShell] built inside
  /// another one replaces rather than extends what the outer one declared.
  PreviewAxes beginShell(String shellId) {
    _shellId = shellId;
    _declared.clear();
    return this;
  }

  @override
  T picker<T>(
    String name,
    Map<String, T> options,
    T defaultValue, {
    PickerStyle style = PickerStyle.dropdown,
  }) {
    assert(
      options.containsValue(defaultValue),
      'The default for axis "$name" is not one of its options, so the top bar '
      'would open with nothing selected.',
    );
    var chosen = _selected[_shellId]?[name];
    var value = chosen is String && options.containsKey(chosen)
        ? options[chosen] as T
        : defaultValue;
    _declared[name] = KnobDescriptor(
      name: name,
      kind: KnobKind.picker,
      options: options.keys.toList(),
      value: _labelOf(options, value),
      defaultValue: _labelOf(options, defaultValue),
      style: style,
    );
    return value;
  }

  @override
  bool flag(String name, bool defaultValue) {
    var chosen = _selected[_shellId]?[name];
    var value = chosen is bool ? chosen : defaultValue;
    _declared[name] = KnobDescriptor(
      name: name,
      kind: KnobKind.boolean,
      value: value,
      defaultValue: defaultValue,
    );
    return value;
  }

  static String? _labelOf<T>(Map<String, T> options, T value) {
    for (var option in options.entries) {
      if (option.value == value) return option.key;
    }
    return null;
  }

  /// What the shell on screen offers, and what each is currently set to.
  AxisReport describe() => AxisReport(
    entryId: _entryId,
    shellId: _shellId,
    axes: [..._declared.values],
  );

  /// Records selections and asks for a rebuild. Returns whether anything moved.
  ///
  /// A shell's map is replaced rather than merged. What arrives is the full
  /// state for that shell: the host holds selections in the address, and an axis on
  /// its default is written there as *nothing at all*, so an absent name is an
  /// instruction to forget rather than an absence of instruction. A null value
  /// says the same thing explicitly, and both put an axis back to the default
  /// the shell wrote.
  ///
  /// Merging was right when the host kept its own store and sent deltas, and it
  /// is what made a top bar look stuck: choosing the default removed the name
  /// from the payload, nothing here removed it from [_selected], and the shell
  /// went on rebuilding with the old choice.
  ///
  /// Shells not named at all are untouched, which is what lets the host push
  /// everything it knows up front and have the right values already in hand
  /// when a shell first builds.
  bool apply(Map<String, Map<String, Object?>> byShell) {
    var changed = false;
    for (var MapEntry(key: shellId, value: selections) in byShell.entries) {
      var next = {
        for (var MapEntry(key: name, value: selection) in selections.entries)
          name: ?selection,
      };
      if (mapEquals(_selected[shellId], next)) continue;
      _selected[shellId] = next;
      changed = true;
    }
    if (changed) revision.value++;
    return changed;
  }

  /// Registers the extensions. Call once, before `runApp`.
  void registerExtensions() {
    GuestExtensions.register('ext.flutterware.axes', (_, _) async {
      return developer.ServiceExtensionResponse.result(
        jsonEncode(describe().toJson()),
      );
    });
    GuestExtensions.register('ext.flutterware.setAxes', (_, args) async {
      // A service extension's arguments are strings, so the payload is JSON in
      // one of them rather than a map of typed values.
      var payload = jsonDecode(args['payload'] ?? '{}') as Map<String, dynamic>;
      var applied = apply({
        for (var shell in payload.entries)
          shell.key: (shell.value as Map).cast<String, Object?>(),
      });
      // Answered only once the shell has rebuilt on it, so a host that asks
      // what there is to show right afterwards is told about the build it
      // caused rather than the one it replaced. Bounded because a panel waits
      // on this: a guest that has stopped drawing should make it late, not
      // stuck.
      if (applied) {
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      }
      return developer.ServiceExtensionResponse.result(
        jsonEncode(describe().toJson()),
      );
    });
  }
}

/// A project's catalog shell: the chrome every demo is rendered inside, and the
/// one place its top-bar switches are declared.
///
/// ```dart
/// // demo/shell.dart
/// Widget wrapInApp(Widget child) => PreviewShell(
///   'app',
///   builder: (context, axes) => MyApp(
///     flavor: axes.picker('flavor', {
///       'Dev': Flavor.dev,
///       'Production': Flavor.prod,
///     }, Flavor.dev),
///     home: child,
///   ),
/// );
/// ```
///
/// A preview names it the way it always did, with `@Preview(wrapper: wrapInApp)`.
/// Nothing about the shell is discovered: it is an ordinary
/// `Widget Function(Widget)`, so Flutter's own previewer and the real app call
/// it unchanged and [PreviewAxes] answers them with the defaults.
///
/// [id] is what the host files selections under, so leaving a shell and coming
/// back finds the flavour you had chosen. Write it once and leave it alone: it
/// is a name rather than a path, so moving or renaming the file does not lose
/// what was set.
class PreviewShell extends StatelessWidget {
  const PreviewShell(this.id, {super.key, required this.builder});

  /// This shell's name, unique within the project.
  final String id;

  /// Where the axes are declared. Called on every selection change.
  final Widget Function(BuildContext context, PreviewAxes axes) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: CatalogAxes.instance.revision,
      builder: (context, _, _) {
        return builder(context, CatalogAxes.instance.beginShell(id));
      },
    );
  }
}
