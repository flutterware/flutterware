/// The checkout the changes screen is recorded over: the demo app as its
/// own repository, with a feature branch in progress on it.
///
/// `examples/brewline` is a directory of the flutterware repository, so a
/// delta of it is a delta of flutterware. This builds the repository it
/// would be on its own — the tracked tree committed as `main` — and then
/// grows a branch on it the way a branch grows: two commits, an edit not
/// committed yet, a file git has not been told about. Every state the screen
/// draws is in it once: an added file, a modified one, a rename, a deletion,
/// an image that changed, a markdown file, a pinned file, an uncommitted
/// hunk on a committed file, an untracked file and an untracked directory.
///
/// The branch is a script rather than a patch file, so that it reads as what
/// it is — a feature, written against the app's own code — and so that the
/// app moving under it fails loudly here rather than silently in the
/// recording: every edit names the text it replaces.
///
/// **Deterministic.** Author, committer, dates and every git setting that
/// shapes output are pinned, so the shas and the patch are the same on every
/// machine and CI can re-record and diff.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore: implementation_imports
import 'package:flutterware/src/clock.dart';
import 'package:flutterware_app/src/utils/run_git.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// The branch the recording is on.
const changesBranch = 'loyalty-stamps';

/// A repository built in a scratch directory, with git pinned.
class ScratchRepo {
  ScratchRepo(this.root);

  final String root;

  /// Nothing from the machine: no global config, no system config, one
  /// identity, one clock — and the settings that shape what git prints,
  /// through the environment rather than `-c`, so a call recorded through
  /// this carries exactly the arguments the app will ask with.
  Map<String, String> environment({DateTime? at}) => {
    ...environmentForGit(),
    'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_COUNT': '${_settings.length}',
    for (var (i, MapEntry(:key, :value)) in _settings.entries.indexed) ...{
      'GIT_CONFIG_KEY_$i': key,
      'GIT_CONFIG_VALUE_$i': value,
    },
    'GIT_AUTHOR_NAME': 'Brewline',
    'GIT_AUTHOR_EMAIL': 'hello@brewline.example',
    'GIT_COMMITTER_NAME': 'Brewline',
    'GIT_COMMITTER_EMAIL': 'hello@brewline.example',
    'GIT_AUTHOR_DATE': _stamp(at ?? pinnedClockOrigin),
    'GIT_COMMITTER_DATE': _stamp(at ?? pinnedClockOrigin),
    // git's own messages, in the one language a diff should be recorded in.
    'LC_ALL': 'C',
  };

  /// [at]'s wall clock, read as UTC.
  ///
  /// Not `at.toUtc()`: `pinnedClockOrigin` is a *local* `DateTime`, so that
  /// converted it by the offset of whichever machine ran the recorder. Every
  /// commit date moved with the timezone, and every sha with it — the
  /// recording CI made in UTC never matched the one committed from a laptop
  /// that was not.
  static String _stamp(DateTime at) =>
      '${DateTime.utc(at.year, at.month, at.day, at.hour, at.minute, at.second).millisecondsSinceEpoch ~/ 1000} +0000';

  /// The settings that shape what git prints, on every call.
  static const _settings = {
    'core.autocrlf': 'false',
    'core.filemode': 'false',
    'core.quotePath': 'false',
    'commit.gpgsign': 'false',
    'diff.renames': 'true',
  };

  Future<String> git(List<String> arguments, {DateTime? at}) async {
    var result = await run(arguments, at: at);
    if (result.exitCode != 0) {
      throw StateError(
        'git ${arguments.join(' ')} failed in $root:\n${result.stderr}',
      );
    }
    return '${result.stdout}';
  }

  /// One git call in this repository, with bytes back.
  ///
  /// `app/tool/` is outside the spawn guard on purpose — see
  /// `test/ambient_git_test.dart` — and this spawn keeps the guard's promise
  /// by hand: the environment is rebuilt, not inherited.
  Future<ProcessResult> run(
    List<String> arguments, {
    DateTime? at,
    Encoding? stdoutEncoding = systemEncoding,
  }) => Process.run(
    'git',
    arguments,
    workingDirectory: root,
    environment: environment(at: at),
    includeParentEnvironment: false,
    stdoutEncoding: stdoutEncoding,
  );

  String read(String relative) =>
      File(p.join(root, relative)).readAsStringSync();

  void write(String relative, String text) => File(p.join(root, relative))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  void writeBytes(String relative, List<int> bytes) =>
      File(p.join(root, relative))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);

  /// Replaces [from] with [to] in [relative], which must contain it exactly
  /// once: an edit that would land twice or nowhere is the app having moved
  /// under the script.
  void edit(String relative, String from, String to) {
    var text = read(relative);
    var count = from.allMatches(text).length;
    if (count != 1) {
      throw StateError(
        '$relative has $count occurrences of the text the branch script '
        'edits, not one — the demo app moved under tool/demo/changes_branch.dart:'
        '\n$from',
      );
    }
    write(relative, text.replaceFirst(from, to));
  }

  void delete(String relative) => File(p.join(root, relative)).deleteSync();

  void rename(String from, String to) =>
      File(p.join(root, from)).renameSync(p.join(root, to));

  Future<void> commit(String message, {required DateTime at}) async {
    await git(['add', '-A']);
    await git(['commit', '-q', '-m', message], at: at);
  }
}

/// Builds the repository at [root] from the tracked files of [project] and
/// grows the branch on it.
///
/// **Standalone**, the way `tool/publish_example.dart` projects it: the
/// workspace line is dropped from the pubspec, a `.gitignore` covers what a
/// resolution and a build leave behind, and a `pubspec_overrides.yaml` points
/// `flutterware` at [flutterwareCheckout] — **by a relative path**, so the
/// tree holds nothing from this machine and its shas are the same on every
/// one. The path is relative to [root]; the comparison's base checkout is
/// placed at the same depth so the same file resolves there too — see
/// `record.dart`, which chooses both.
Future<ScratchRepo> buildChangesRepo({
  required String project,
  required String root,
  required String flutterwareCheckout,
}) async {
  var dir = Directory(root);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  // The tracked tree, as it would be cloned: what `tool/publish_example.dart`
  // projects, minus the workspace line nothing here reads.
  var listed = await runGit(
    ['ls-files', '-z'],
    workingDirectory: project,
    stdoutEncoding: utf8,
  );
  if (listed.exitCode != 0) {
    throw StateError('git ls-files failed in $project:\n${listed.stderr}');
  }
  var tracked = '${listed.stdout}'
      .split('\u0000')
      .where((path) => path.isNotEmpty)
      .toList();
  if (tracked.isEmpty) {
    throw StateError('$project has no tracked files — commit the demo first.');
  }
  for (var path in tracked) {
    var target = File(p.join(root, path))..parent.createSync(recursive: true);
    if (path == 'pubspec.yaml') {
      target.writeAsStringSync(
        _standalonePubspec(File(p.join(project, path)).readAsStringSync()),
      );
    } else {
      File(p.join(project, path)).copySync(target.path);
    }
  }

  var repo = ScratchRepo(root);
  var origin = pinnedClockOrigin;
  repo.write('.gitignore', _gitignore);
  repo.write(
    'pubspec_overrides.yaml',
    '# The flutterware this checkout is compared with — the one that recorded\n'
        '# it, by a path relative to where the recorder builds this repository.\n'
        'dependency_overrides:\n'
        '  flutterware:\n'
        '    path: ${p.relative(flutterwareCheckout, from: root).replaceAll(r'\', '/')}\n',
  );
  await repo.git(['init', '-q', '-b', 'main']);
  await repo.commit('Brewline', at: origin.subtract(const Duration(days: 3)));
  await repo.git(['checkout', '-q', '-b', changesBranch]);
  await growLoyaltyBranch(repo, origin: origin);
  return repo;
}

/// The feature: a stamp card. Ten drinks and the next one is on the house.
///
/// Three hours of work, told in the tree: a tidy-up commit, the feature, its
/// French copy, and then the change of mind that is still on the desk.
Future<void> growLoyaltyBranch(
  ScratchRepo repo, {
  required DateTime origin,
}) async {
  // --- 1. Tidy the demo folder ------------------------------------------
  // A rename with no edit inside it — git sees it whole — and a preview
  // nobody opened dropped.
  repo.rename('lib/shop/mini_markdown.dart', 'lib/shop/markdown_text.dart');
  repo.edit(
    'lib/shop/shop_screens.dart',
    "import 'mini_markdown.dart';",
    "import 'markdown_text.dart';",
  );
  for (var test in const [
    'test/shop/translations_test.dart',
    'test/scenarios/desktop/flutter_test_config.dart',
    'test/scenarios/mobile/flutter_test_config.dart',
  ]) {
    repo.edit(
      test,
      "import 'package:brewline/shop/mini_markdown.dart';",
      "import 'package:brewline/shop/markdown_text.dart';",
    );
  }
  repo.delete('demo/store_panorama.dart');
  await repo.commit(
    'Tidy the demo folder: the markdown helper renamed, the panorama '
    'preview dropped',
    at: origin.subtract(const Duration(hours: 3)),
  );

  // --- 2. The stamp card ---------------------------------------------
  repo.write('lib/shop/loyalty.dart', _loyaltyDart);
  // A preview of the new screen, beside the others: the comparison's one
  // *added* entry.
  repo.write('demo/loyalty.dart', _loyaltyPreviewDart);

  repo.edit(
    'lib/shop/shop_app.dart',
    "import 'shop_screens.dart';\nimport 'shop_strings.dart';\n\n"
        "export 'shop_screens.dart';\nexport 'shop_strings.dart';\n",
    "import 'loyalty.dart';\nimport 'shop_screens.dart';\n"
        "import 'shop_strings.dart';\n\n"
        "export 'loyalty.dart';\nexport 'shop_screens.dart';\n"
        "export 'shop_strings.dart';\n",
  );
  repo.edit(
    'lib/shop/shop_app.dart',
    '  late final _cart = widget.cart ?? Cart();\n',
    '  late final _cart = widget.cart ?? Cart();\n\n'
        '  /// Kept beside the cart rather than in it: an order clears the '
        'cart and\n'
        '  /// leaves the stamps, which is the whole point of them.\n'
        '  late final _loyalty = Loyalty();\n',
  );
  repo.edit(
    'lib/shop/shop_app.dart',
    '''
      // Above the navigator, so every pushed route sees the cart.
      builder: (context, child) => CartScope(
        cart: _cart,
        child: widget.overlay == null
            ? child!
            : Stack(
                children: [
                  child!,
                  // Positioned rather than a plain child: an overlay sized to
                  // the whole stack would swallow every tap meant for the app
                  // underneath it.
                  Positioned(top: 0, left: 0, right: 0, child: widget.overlay!),
                ],
              ),
      ),
''',
    '''
      // Above the navigator, so every pushed route sees the cart — and the
      // stamps, which outlive any one order.
      builder: (context, child) => LoyaltyScope(
        loyalty: _loyalty,
        child: CartScope(
          cart: _cart,
          child: widget.overlay == null
              ? child!
              : Stack(
                  children: [
                    child!,
                    // Positioned rather than a plain child: an overlay sized
                    // to the whole stack would swallow every tap meant for
                    // the app underneath it.
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: widget.overlay!,
                    ),
                  ],
                ),
        ),
      ),
''',
  );
  repo.edit(
    'lib/shop/shop_app.dart',
    "  static const openCart = Key('shop.openCart');\n",
    "  static const openCart = Key('shop.openCart');\n"
        "  static const loyalty = Key('shop.loyalty');\n",
  );

  repo.edit(
    'lib/shop/shop_screens.dart',
    "import 'markdown_text.dart';\nimport 'shop_app.dart';\n",
    "import 'loyalty.dart';\nimport 'markdown_text.dart';\n"
        "import 'shop_app.dart';\n",
  );
  repo.edit(
    'lib/shop/shop_screens.dart',
    '''
        title: Text(strings.menuTitle),
        actions: [
          Padding(
''',
    '''
        title: Text(strings.menuTitle),
        actions: [
          IconButton(
            key: ShopKeys.loyalty,
            icon: const Icon(Icons.loyalty_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LoyaltyScreen()),
            ),
          ),
          Padding(
''',
  );
  repo.edit(
    'lib/shop/shop_screens.dart',
    '''
                      var name = _name.text.isEmpty ? '—' : _name.text;
                      cart.clear();
''',
    '''
                      var name = _name.text.isEmpty ? '—' : _name.text;
                      // One stamp per drink, before the cart forgets them.
                      Loyalty.of(context).stamp(cart.items.length);
                      cart.clear();
''',
  );

  repo.edit(
    'lib/shop/shop_strings.dart',
    "  String get backToMenu => read('backToMenu');\n",
    "  String get backToMenu => read('backToMenu');\n"
        "  String get loyaltyTitle => read('loyaltyTitle');\n"
        "  String get freeDrink => read('freeDrink');\n\n"
        '  /// The count goes through a placeholder — see [thanks] for why the '
        'key\n'
        '  /// is routed rather than read back.\n'
        '  String stampsOf(int count) => _expand(\n'
        "    'stampsOf',\n"
        "    read('stampsOf').replaceAll('{count}', '\$count'),\n"
        '  );\n',
  );
  repo.edit(
    'assets/i18n/en.json',
    '  "backToMenu": "Back to menu",\n',
    '  "backToMenu": "Back to menu",\n'
        '  "loyaltyTitle": "Your stamps",\n'
        '  "stampsOf": "{count} of 10 — keep going.",\n'
        '  "freeDrink": "Ten stamps, and the next one is on us.",\n',
  );

  repo.edit(
    'README.md',
    '## What to look at\n',
    '## The stamp card\n\n'
        'Every drink ordered is a stamp on the card behind the loyalty icon '
        'on the\nmenu; ten stamps and the next one is on the house. The card '
        'lives beside the\ncart rather than in it — an order clears the cart '
        'and keeps the stamps — so\n`lib/shop/loyalty.dart` is a scope of its '
        'own above the navigator, the same\nshape as the cart.\n\n'
        '## What to look at\n',
  );

  // The branding strip, in the shop's own brown rather than the placeholder
  // teal: a binary change, so the screen has an image to show both sides of.
  repo.writeBytes(
    'assets/splash/branding.png',
    _recolored(
      File(p.join(repo.root, 'assets/splash/branding.png')).readAsBytesSync(),
    ),
  );

  await repo.commit(
    'Loyalty: a stamp card on the menu, and the branding strip in the '
    "shop's brown",
    at: origin.subtract(const Duration(hours: 2)),
  );

  // --- 3. The French copy ---------------------------------------------
  // Two of the three keys: the third is the demo's standing example of a
  // string a locale is missing, and this branch adds to it.
  repo.edit(
    'assets/i18n/fr.json',
    '  "backToMenu": "Retour à la carte",\n',
    '  "backToMenu": "Retour à la carte",\n'
        '  "loyaltyTitle": "Vos tampons",\n'
        '  "stampsOf": "{count} sur 10 — encore un effort.",\n',
  );
  await repo.commit(
    'Loyalty: French copy',
    at: origin.subtract(const Duration(hours: 1)),
  );

  // --- 4. On the desk ------------------------------------------------
  // A change of mind, not committed: eight stamps, not ten. The English
  // copy follows; the French does not yet — which is exactly what an
  // uncommitted delta looks like ten minutes in.
  repo.edit(
    'lib/shop/loyalty.dart',
    '  static const perReward = 10;\n',
    '  static const perReward = 8;\n',
  );
  repo.edit(
    'assets/i18n/en.json',
    '  "stampsOf": "{count} of 10 — keep going.",\n',
    '  "stampsOf": "{count} of 8 — keep going.",\n',
  );
  // And two things git has not been told about: a test, and a folder of
  // notes — a whole directory, which the screen lists as one row.
  repo.write('test/shop/loyalty_test.dart', _loyaltyTestDart);
  repo.write('docs/loyalty.md', _loyaltyNotes);
}

/// [png] with every teal pixel in the shop's brown, alpha kept.
List<int> _recolored(Uint8List png) {
  var image = img.decodePng(png)!;
  const brown = (0x6F, 0x4E, 0x37);
  for (var pixel in image) {
    // The strip's own colour only: green over red is the teal, and a
    // background pixel — transparent or white — is neither.
    if (pixel.a == 0 || pixel.g <= pixel.r) continue;
    pixel
      ..r = brown.$1
      ..g = brown.$2
      ..b = brown.$3;
  }
  return img.encodePng(image);
}

const _loyaltyDart = '''
import 'package:material_ui/material_ui.dart';

import 'shop_app.dart';

/// Ten stamps and the eleventh coffee is on the house.
///
/// Kept beside the cart rather than in it: an order clears the cart and
/// leaves the stamps, which is the whole point of them.
class Loyalty extends ChangeNotifier {
  static const perReward = 10;

  int _stamps = 0;
  int get stamps => _stamps;

  /// One stamp per drink ordered, never per order — a round of five is five.
  void stamp(int drinks) {
    if (drinks <= 0) return;
    _stamps = (_stamps + drinks) % perReward;
    notifyListeners();
  }

  static Loyalty of(BuildContext context) => LoyaltyScope.of(context);
}

/// The stamps, above the navigator, so every screen sees the same card.
class LoyaltyScope extends InheritedNotifier<Loyalty> {
  const LoyaltyScope({
    super.key,
    required Loyalty loyalty,
    required super.child,
  }) : super(notifier: loyalty);

  static Loyalty of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LoyaltyScope>()!
      .notifier!;
}

/// The card: a row of circles, filled up to the count.
class StampCard extends StatelessWidget {
  const StampCard({super.key, required this.stamps});

  final int stamps;

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < Loyalty.perReward; i++)
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < stamps ? scheme.primary : scheme.surfaceContainerLow,
              border: Border.all(color: scheme.primary, width: 2),
            ),
            child: i < stamps
                ? Icon(Icons.local_cafe, size: 18, color: scheme.onPrimary)
                : null,
          ),
      ],
    );
  }
}

class LoyaltyScreen extends StatelessWidget {
  const LoyaltyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    var loyalty = Loyalty.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.loyaltyTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            StampCard(stamps: loyalty.stamps),
            const SizedBox(height: 24),
            Text(
              strings.stampsOf(loyalty.stamps),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              strings.freeDrink,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
''';

const _loyaltyTestDart = '''
import 'package:flutter_test/flutter_test.dart';
import 'package:brewline/shop/shop_app.dart';

/// The card counts drinks, not orders, and wraps at the reward.
void main() {
  test('a round of three is three stamps', () {
    var loyalty = Loyalty()..stamp(3);
    expect(loyalty.stamps, 3);
  });

  test('the reward drink resets the card', () {
    var loyalty = Loyalty()..stamp(Loyalty.perReward + 2);
    expect(loyalty.stamps, 2);
  });

  test('an empty order stamps nothing', () {
    var loyalty = Loyalty()..stamp(0);
    expect(loyalty.stamps, 0);
  });
}
''';

const _loyaltyNotes = '''
# Loyalty stamps — open questions

- Eight or ten? Ten is what every card in town says. Eight is what makes a
  weekly regular hit the free drink inside a fortnight, which is when a
  habit is still being decided.
- The reward drink: any size, or the size of the smallest on the card?
- Where does the card persist? Nowhere yet — it is memory, like the cart.
  A real one is a token on the server, keyed by the name on the cup.
''';

/// What a resolution and a build leave in a checkout, kept out of the delta.
const _gitignore = '''
.dart_tool/
build/
pubspec.lock
.flutter-plugins-dependencies
.fvm/
''';

/// [pubspec] without its `resolution: workspace` line and the comment above
/// it — the same cut `tool/publish_example.dart` makes.
String _standalonePubspec(String pubspec) {
  var lines = pubspec.split('\n');
  var at = lines.indexWhere(
    (line) => RegExp(r'^resolution:\s*workspace').hasMatch(line),
  );
  if (at < 0) {
    throw StateError(
      "the demo app's pubspec.yaml declares no `resolution: workspace`; "
      'is it still a workspace member?',
    );
  }
  var from = at;
  while (from > 0 && lines[from - 1].startsWith('#')) {
    from--;
  }
  return [...lines.take(from), ...lines.skip(at + 1)].join('\n');
}

const _loyaltyPreviewDart = '''
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:brewline/shop/shop_app.dart';

import 'shop.dart';

@Preview(name: 'Stamp card', group: 'Brewline', wrapper: wrapInShop)
Widget shopLoyalty() => const LoyaltyScreen();
''';
