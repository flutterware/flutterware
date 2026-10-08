/// Where an exported image lands, and what it is called.
///
/// Pure: a layout, a target and a locale in, a relative path out. No I/O, so
/// the one property that matters can be asserted over every layout at once —
/// see `app/test/store/tree_test.dart`.
///
/// That property is **no two images of one export share a path**, and it is not
/// obvious from the shapes. fastlane's iOS tree puts every display class in one
/// directory per locale, because `deliver` works the class out from the image's
/// own dimensions rather than from where it sits — so the directory cannot
/// separate an iPhone set from an iPad one and the file name has to. A
/// collision there is silent: the second write overwrites the first, and a
/// listing that reports thirty screenshots ships fifteen, all of them iPad.
library;

import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

/// The directory one set's images go in, relative to the package's output root.
///
/// `fastlane` is the default because it is the only shape another tool reads
/// without being told anything: `deliver` takes one directory per locale, while
/// `supply` wants a directory per class inside the locale's.
String storeDirectoryFor(
  StoreLayout layout,
  StoreTarget target,
  String storeLocale,
) => switch (layout) {
  StoreLayout.plain => p.join(target.store, target.id, storeLocale),
  StoreLayout.fastlane => switch (target.store) {
    'play' => p.join('android', storeLocale, 'images', switch (target.id) {
      'tablet-10' => 'tenInchScreenshots',
      'tablet-7' => 'sevenInchScreenshots',
      _ => 'phoneScreenshots',
    }),
    _ => p.join('ios', storeLocale),
  },
};

/// What one image is called.
///
/// Everywhere but fastlane's iOS tree the number and the shot's name are
/// enough, because the directory already says which set it is. There, the class
/// goes in the name — which also groups the two sets when an uploader sorts by
/// file name.
String storeFileNameFor(StoreLayout layout, StoreTarget target, String stem) =>
    layout == StoreLayout.fastlane && target.store != 'play'
    ? '${target.id}-$stem.png'
    : '$stem.png';

/// `order-placed` from `Order placed` — a name that sorts, survives every
/// filesystem, and still reads as what it shows.
///
/// **Letters and digits in any script**, not `[a-z0-9]`. It was the ASCII
/// class first, which meant a shot named `メニュー` — or in Cyrillic, Greek,
/// Hebrew or Arabic — slugged to the empty string: the export wrote `02-.png`,
/// the viewer's title read `02-`, and `--shot=メニュー` matched nothing. A
/// listing localized into those languages is exactly the listing this plugin
/// is for. Filenames are UTF-8 on every platform this runs on, and neither
/// store reads the name — `deliver` infers a class from the image's own
/// dimensions and `supply` from the directory.
///
/// [fallback] is what a name with no letters or digits at all becomes — an
/// emoji, or punctuation. Rare, and better than a file called `02-.png`.
String storeSlug(String name, {String fallback = 'shot'}) {
  var slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? fallback : slug;
}

/// Whether [fileName], sitting in this target's directory, is one of **this
/// set's** images.
///
/// Everywhere but fastlane's iOS tree the directory belongs to one set and the
/// answer is every PNG in it. There, two classes share `ios/<locale>/` and only
/// the file name separates them.
///
/// Asked in two places, which is why it is a function rather than a condition
/// written twice: the set-scoped sweep before a narrowed export, and the
/// question of what a set currently holds on disk. Those two disagreeing would
/// mean an export that deletes an image it then reports as present.
bool storeOwnsFile(StoreLayout layout, StoreTarget target, String fileName) {
  if (p.extension(fileName) != '.png') return false;
  if (layout != StoreLayout.fastlane || target.store == 'play') return true;
  return p.basenameWithoutExtension(fileName).startsWith('${target.id}-');
}

/// `02-order-placed` split back into the two things it is.
///
/// The number is the shot's position in its set and the slug is its name;
/// both are addressable, because a person narrowing an export says whichever
/// one they have in front of them.
(int?, String) storeShotParts(String stem) {
  var match = RegExp(r'^(\d+)-(.*)$').firstMatch(stem);
  return match == null
      ? (null, stem)
      : (int.parse(match.group(1)!), match.group(2)!);
}

/// The reverse of [storeFileNameFor]: a written file's name, back to the shot
/// it is of — `Order placed` from `iphone-6-9-02-order-placed.png`.
///
/// Here rather than wherever a title is drawn, because only this file knows
/// that the class prefix is a prefix. A reader that tries to work it out from
/// the string cannot: `iphone-6-9-02-menu` has three plausible numbers in it,
/// and guessing gave `9 02 menu` on the first screen it was asked about.
String storeTitleOf(StoreLayout layout, StoreTarget target, String fileName) {
  var stem = p.basenameWithoutExtension(fileName);
  var prefix = '${target.id}-';
  if (layout == StoreLayout.fastlane &&
      target.store != 'play' &&
      stem.startsWith(prefix)) {
    stem = stem.substring(prefix.length);
  }
  var (_, slug) = storeShotParts(stem);
  var words = slug.split('-').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return stem;
  return [
    words.first[0].toUpperCase() + words.first.substring(1),
    ...words.skip(1),
  ].join(' ');
}

/// Whether `--shot=<query>` picks out [stem].
///
/// A number matches the position — `2` and `02` are the same shot. Anything
/// else is slugged and matched against the name, so `--shot="Order placed"`
/// and `--shot=order-placed` both work.
///
/// **Exact, never a substring.** `--shot=cart` taking both `cart-empty` and
/// `cart-full` is the same shape of bug as the filename collision phase 2
/// shipped: a narrowing argument quietly doing more than it says. A query that
/// matches nothing is refused by the caller rather than writing an empty set.
bool storeShotMatches(String stem, String query) {
  var (number, slug) = storeShotParts(stem);
  var wanted = query.trim();
  var asNumber = int.tryParse(wanted);
  return asNumber != null ? asNumber == number : storeSlug(wanted) == slug;
}

/// Whether this set is *composed* — given a ground and a device body — rather
/// than handed over close to how the app drew it.
///
/// The rule, in one place because it is the difference between two quite
/// different outputs and reading it off two call sites would eventually make
/// them disagree.
///
/// A declared frame applies to **every** set: a project that has chosen a
/// composition has chosen it for its listing. With none declared, the app's own
/// pixels are the deliverable wherever a store accepts them — inventing a
/// background and a device body for an App Store set nobody asked to compose is
/// a marketing decision, and not ours. What is left is the set whose canvas is
/// not its device's, where there is no such option: Play's phone is 2:1 and no
/// Android phone is.
///
/// **This is no longer the same question as whether a set is framed.** Every
/// set goes through the frame pass, because every set wants the status bar a
/// `flutter_tester` could not draw — see `defaultStoreFrame`, which hands an
/// uncomposed set a pane of glass rather than a composition. What this still
/// decides is the deliverable's *kind*, and therefore whether `unframed/` has
/// anything to say: a composition is the case where the app's own pixels are
/// not the deliverable, so it is the only case where keeping them is more than
/// a second name for one file.
bool storeShouldCompose({
  required bool hasFrame,
  required StoreTarget target,
}) => hasFrame || target.needsComposition;
