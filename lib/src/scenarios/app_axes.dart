/// A project's own axes — `ScenarioProfile.axes` — as the text a command line,
/// an environment variable and a directory name carry them.
///
/// A device, a language and an orientation are words this package knows. An
/// app's brand, its contrast mode or a feature flag's variant are not: the
/// folder that runs them declares the values, and the only thing either side
/// of the wire can do with one is carry it, compare it and write it down. So
/// this is all strings, and all of it is here.
///
/// Its own file, with nothing above it, for the reason `selector.dart` is: the
/// harness reads `FW_AXES` with it inside the user's test process, the plugin
/// reads `--axes=` with it without reaching Flutter, and the two spelling a
/// point differently is two directories for one picture.
library;

import 'dart:convert';

/// What a name or a value may be made of: it becomes part of a directory name
/// in every lane, and a `,` or an `=` would end it early on a command line.
final _token = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

/// What is wrong with a declaration of app axes, one sentence each — empty
/// when nothing is.
///
/// Asked of a folder's profile before anything runs, by both lanes, so a
/// value that cannot be written as a directory is refused where it was
/// written rather than discovered as a path that went somewhere else.
List<String> appAxisProblems(Map<String, List<String>> axes) {
  const carried =
      'letters, digits, `.`, `_` and `-`, starting with a letter or a digit';
  const noValues =
      'declares no values; an axis is the values it runs in, and its first '
      'is the default';
  return [
    for (var MapEntry(key: name, value: values) in axes.entries) ...[
      if (!_token.hasMatch(name))
        'axis `$name` has a name a directory cannot carry — $carried',
      if (values.isEmpty) 'axis `$name` $noValues',
      for (var value in values)
        if (!_token.hasMatch(value))
          'axis `$name` has a value a directory cannot carry, `$value` — $carried',
      if (values.toSet().length != values.length)
        'axis `$name` names a value twice: ${values.join(', ')}',
    ],
  ];
}

/// `brand=coffee,tea,contrast=high` → `{brand: [coffee, tea], contrast:
/// [high]}`.
///
/// A part with an `=` starts an axis; a part without one is another value of
/// the axis before it — so one value per axis reads exactly as `--axes=` does
/// for a preview, and a list is the comma that `--languages=en,fr` already
/// uses. An axis named twice gathers both, which is what a repeated
/// `--axes` flag joined with commas comes to. A JSON object is accepted too,
/// each value a string or a list of them.
///
/// Throws [FormatException] naming the part it could not read.
Map<String, List<String>> parseAppAxes(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return const {};
  var axes = <String, List<String>>{};
  void add(String name, String value) {
    var values = axes.putIfAbsent(name, () => []);
    if (!values.contains(value)) values.add(value);
  }

  if (text.startsWith('{')) {
    var decoded = jsonDecode(text);
    if (decoded is! Map) throw FormatException('expected a JSON object', raw);
    for (var MapEntry(:key, :value) in decoded.entries) {
      for (var one in value is List ? value : [value]) {
        add('$key', '$one');
      }
    }
    return axes;
  }
  String? current;
  for (var part in text.split(',')) {
    var item = part.trim();
    if (item.isEmpty) continue;
    var equals = item.indexOf('=');
    if (equals < 0) {
      if (current == null) {
        throw FormatException(
          'expected name=value, got `$item` — an axis is named before its '
          'values: `brand=coffee,tea`',
        );
      }
      add(current, item);
      continue;
    }
    var name = item.substring(0, equals).trim();
    var value = item.substring(equals + 1).trim();
    if (name.isEmpty || value.isEmpty) {
      throw FormatException('expected name=value, got `$item`');
    }
    current = name;
    add(name, value);
  }
  return axes;
}

/// [values] the way a command line takes them back: `brand=tea,contrast=high`,
/// by axis name, so two runs of the same point spell it the same way.
String formatAppAxes(Map<String, String> values) =>
    [for (var name in values.keys.toList()..sort()) '$name=${values[name]}']
        .join(',');

/// The values of [values] in the order a directory name writes them — by
/// axis name, so a folder that declares its axes in another order still lands
/// in the same directory.
///
/// The value alone, as `-dark` and `-landscape` are: the name is the folder's
/// to know and the directory is for reading.
List<String> appAxisSlugParts(Map<String, String> values) => [
  for (var name in values.keys.toList()..sort()) values[name]!,
];

/// Every combination of [lists], one value per axis, in declaration order with
/// the last axis turning fastest — or a single empty point when there are no
/// axes, so a caller can always loop over the answer.
List<Map<String, String>> appAxisPoints(Map<String, List<String>> lists) {
  var points = [<String, String>{}];
  for (var MapEntry(key: name, value: values) in lists.entries) {
    points = [
      for (var point in points)
        for (var value in values) {...point, name: value},
    ];
  }
  return points;
}
