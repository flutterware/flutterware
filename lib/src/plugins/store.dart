/// The store listing a project ships: which stores, which device classes,
/// which locales — and the screenshots that go in it.
///
/// Design: `docs/superpowers/specs/2026-08-26-store-screenshots-design.md`.
///
/// The whole of this file exists to make a rejected set **unwritable** rather
/// than reported. There is no validator anywhere in this plugin and there must
/// not be: a listing declares which store it is, the store's sizes arrive with
/// it, and the type system refuses to let an App Store listing name a Play
/// device class. A project cannot ask for a size a store would refuse, so
/// nothing has to check afterwards whether it did.
///
/// Pure Dart, like every other file under `plugins/` — a project's
/// `tool/flutterware.dart` runs under a plain `dart run`, and the frame that
/// composes these (which does import Flutter) lives in `lib/store.dart`
/// instead.
library;

import '../devices.dart';
import 'package.dart';
import 'plugin.dart';

/// The image a store receives, in **physical pixels**.
///
/// Kept apart from the [Device] a shot is rendered on, and that separation is
/// the spine of this design rather than a tidiness. For Apple the two agree:
/// its two required sizes fall out of the device table exactly, so a 6.9"
/// iPhone screenshot *is* what an iPhone 16 Pro Max renders. For Google Play
/// they cannot: Play refuses any image whose longer side is more than twice its
/// shorter one, and every shipping Android phone is 20:9 — 2.222 — so a
/// truthful full-screen screenshot of a modern Android phone is not a legal
/// Play screenshot. On Play the picture is therefore a *composition* whose
/// canvas is legal, with a real phone rendered inside it.
///
/// Which is why a class carries both numbers and they are allowed to differ.
class StoreCanvas {
  const StoreCanvas({
    required this.width,
    required this.height,
    this.pixelRatio = 1,
  });

  /// The image a device produces at its own ratio, which is the canvas
  /// wherever a store's size and a real device's happen to coincide.
  factory StoreCanvas.of(Device device) => StoreCanvas(
    width: (device.width * device.pixelRatio).round(),
    height: (device.height * device.pixelRatio).round(),
    pixelRatio: device.pixelRatio,
  );

  final int width;
  final int height;

  /// What a frame is laid out at — physical pixels per logical one.
  ///
  /// A canvas is an image, but a composition is a *design*, and a design has
  /// to be written in the units a designer thinks in. Rendering 1320×2868 at
  /// ratio 1 would put a 16-point caption in a space 2868 units tall, where it
  /// is a speck.
  ///
  /// The rule is that a canvas is laid out in **the same logical units the app
  /// inside it was**, which is the device's own ratio. So a frame's padding
  /// and the phone's own margins are the same kind of number, and a
  /// composition designed against one device does not silently change scale on
  /// another.
  final double pixelRatio;

  /// The canvas in logical pixels — what a frame's layout is written against.
  double get logicalWidth => width / pixelRatio;
  double get logicalHeight => height / pixelRatio;

  /// `1320×2868`, for anywhere a size is shown.
  String get label => '$width×$height';

  @override
  bool operator ==(Object other) =>
      other is StoreCanvas &&
      other.width == width &&
      other.height == height &&
      other.pixelRatio == pixelRatio;

  @override
  int get hashCode => Object.hash(width, height, pixelRatio);

  @override
  String toString() => 'StoreCanvas($label)';
}

/// A display class of Apple's, and the device that renders it.
///
/// Apple scales a family's screenshots down from the largest set it is given,
/// so one iPhone class and one iPad class cover every device. iPhone has two
/// sizes that can be that set: 6.5" is required of a listing that has no 6.9",
/// and App Store Connect does not always offer the 6.9" slot to drop one in.
/// A listing exports both unless it narrows [AppStoreListing.classes].
///
/// Every class comes out of the device table to the pixel, which is why no App
/// Store class declares a canvas of its own.
///
/// An enum of Apple's rather than one shared with [PlayClass]: a shared one
/// would let an App Store listing name a phone class Apple has never heard of,
/// and then something downstream would have to refuse it. Two enums make that
/// sentence unwritable.
enum AppStoreClass {
  /// 1320×2868.
  iphone69('iphone-6-9', 'iPhone 6.9"', Devices.iphone16ProMax),

  /// 1284×2778. Required where there is no 6.9" set.
  iphone65('iphone-6-5', 'iPhone 6.5"', Devices.iphone12ProMax),

  /// 2048×2732 — required of an app that runs on iPad.
  ipad13('ipad-13', 'iPad 13"', Devices.iPadPro13);

  const AppStoreClass(this.id, this.label, this.device);

  final String id;
  final String label;

  /// What the app renders as. The canvas follows from it.
  final Device device;

  StoreCanvas get canvas => StoreCanvas.of(device);
}

/// A device class of Google Play's, the device that renders it, and the canvas
/// it has to land on.
///
/// The phone is the case [StoreCanvas] is written about: rendered on a real
/// 20:9 Pixel, delivered on a 2:1 canvas, because 2:1 is the tallest Play
/// allows and 1080 is the short side that clears its bar for prominent
/// placement. The tablet needs no composition to be legal — 800×1280 at ratio 2
/// is 1600×2560, which is Play's own recommended 10" size — so its canvas is
/// its device's, and a frame around it is a style choice rather than a
/// requirement.
///
/// No 7" tablet: Play does not require one and no device in the table is one.
enum PlayClass {
  phone(
    'phone',
    'Phone',
    Devices.androidTall,
    // Laid out at the Pixel's own ratio, per [StoreCanvas.pixelRatio] — 411×823
    // logical, which is a phone-shaped space a caption and a device body can
    // be composed in.
    StoreCanvas(width: 1080, height: 2160, pixelRatio: 2.625),
  ),
  tablet10('tablet-10', '10" tablet', Devices.androidSmallTablet, null);

  const PlayClass(this.id, this.label, this.device, this._canvas);

  final String id;
  final String label;
  final Device device;

  /// Null where the device's own output is already what Play wants, which is
  /// how a class says *nothing to compose for size here*.
  final StoreCanvas? _canvas;

  StoreCanvas get canvas => _canvas ?? StoreCanvas.of(device);
}

/// One point of a listing, with both stores' vocabularies already resolved —
/// what everything downstream of the declaration consumes.
///
/// The two class enums exist so a declaration cannot be wrong; this exists so
/// the runner does not have to know which of them it is looking at.
class StoreTarget {
  const StoreTarget({
    required this.store,
    required this.id,
    required this.label,
    required this.device,
    required this.canvas,
  });

  /// `app-store` or `play`.
  final String store;

  /// The class id, unique within [store] — `iphone-6-9`, `phone`.
  final String id;
  final String label;

  /// What the app renders as.
  final Device device;

  /// What the store receives.
  final StoreCanvas canvas;

  /// Whether the app's own frame has to be composed onto a larger or
  /// differently-shaped canvas to produce this.
  ///
  /// True for exactly one class today — Play's phone — and the reason is
  /// geometric rather than aesthetic: see [StoreCanvas]. A target that answers
  /// true cannot be exported unframed, and until a frame exists the export says
  /// so rather than writing an image the store will bounce.
  bool get needsComposition => canvas != StoreCanvas.of(device);

  Map<String, Object?> toJson() => {
    'store': store,
    'class': id,
    'device': device.id,
    'width': canvas.width,
    'height': canvas.height,
  };
}

/// One store's listing: its device classes and its locales.
///
/// Sealed with a constructor per store, following [TranslationCatalog] and for
/// its reason — the two stores ask different questions, and one class with a
/// `store:` field would carry the union of both, most of which would not apply
/// to any given declaration.
sealed class Listing {
  const Listing._({required this.locales});

  /// Apple's. Both classes by default, because an app that does not run on
  /// iPad simply does not ship an iPad build and the extra set costs a run.
  const factory Listing.appStore({
    required Map<String, String> locales,
    List<AppStoreClass> classes,
  }) = AppStoreListing;

  /// Google's.
  const factory Listing.play({
    required Map<String, String> locales,
    List<PlayClass> classes,
  }) = PlayListing;

  /// The app's locale tag to the store's — `{'en': 'en-US', 'fr': 'fr-FR'}`.
  ///
  /// Two vocabularies, and mapping them explicitly is the point. `fr` is what
  /// the app is run as; `fr-FR` is a localization slot in a store console, and
  /// the stores do not agree with each other on the spelling either. Deriving
  /// one from the other works until the first project that ships `fr-CA` to a
  /// listing that only has `fr`, and then it is wrong silently.
  ///
  /// Required rather than defaulted: a default would be a claim about which
  /// language a project is written in.
  final Map<String, String> locales;

  /// `app-store` or `play`.
  String get store;

  /// A human name for the store, for a panel heading.
  String get storeLabel;

  /// The most screenshots this store accepts in one set.
  ///
  /// A fact about the set, not a warning about it — see §6. Ten for Apple, per
  /// display family; eight for Play, per image type. Not enforced anywhere and
  /// deliberately so: an over-full set is a thing to see in the panel, and the
  /// count comes from the scenarios rather than from anything a declaration
  /// could refuse.
  int get maxShots;

  /// This listing's classes, resolved.
  List<StoreTarget> get targets;

  Map<String, Object?> toJson();

  /// Where a serialised listing says which store it is.
  static const storeKey = 'store';

  /// Reads back what [toJson] wrote, or **null for a store this build does not
  /// know** — a project pinning a newer flutterware than the studio opening it,
  /// which is worth reporting rather than guessing at.
  static Listing? fromJson(Map<String, Object?> json) {
    var locales = <String, String>{
      for (var e in (json['locales'] as Map? ?? {}).entries)
        '${e.key}': '${e.value}',
    };
    var ids = [for (var id in json['classes'] as List? ?? []) '$id'];
    switch (json[storeKey]) {
      case AppStoreListing._store:
        return AppStoreListing(
          locales: locales,
          classes: ids.isEmpty
              ? AppStoreClass.values
              : [
                  for (var c in AppStoreClass.values)
                    if (ids.contains(c.id)) c,
                ],
        );
      case PlayListing._store:
        return PlayListing(
          locales: locales,
          classes: ids.isEmpty
              ? PlayClass.values
              : [
                  for (var c in PlayClass.values)
                    if (ids.contains(c.id)) c,
                ],
        );
    }
    return null;
  }
}

/// See [Listing.appStore].
final class AppStoreListing extends Listing {
  const AppStoreListing({
    required super.locales,
    this.classes = AppStoreClass.values,
  }) : super._();

  static const _store = 'app-store';

  final List<AppStoreClass> classes;

  @override
  String get store => _store;

  @override
  String get storeLabel => 'App Store';

  @override
  int get maxShots => 10;

  @override
  List<StoreTarget> get targets => [
    for (var c in classes)
      StoreTarget(
        store: _store,
        id: c.id,
        label: c.label,
        device: c.device,
        canvas: c.canvas,
      ),
  ];

  @override
  Map<String, Object?> toJson() => {
    Listing.storeKey: _store,
    'locales': locales,
    'classes': [for (var c in classes) c.id],
  };
}

/// See [Listing.play].
final class PlayListing extends Listing {
  const PlayListing({required super.locales, this.classes = PlayClass.values})
    : super._();

  static const _store = 'play';

  final List<PlayClass> classes;

  @override
  String get store => _store;

  @override
  String get storeLabel => 'Google Play';

  @override
  int get maxShots => 8;

  @override
  List<StoreTarget> get targets => [
    for (var c in classes)
      StoreTarget(
        store: _store,
        id: c.id,
        label: c.label,
        device: c.device,
        canvas: c.canvas,
      ),
  ];

  @override
  Map<String, Object?> toJson() => {
    Listing.storeKey: _store,
    'locales': locales,
    'classes': [for (var c in classes) c.id],
  };
}

/// How the exported tree is laid out.
enum StoreLayout {
  /// What `fastlane deliver` and `fastlane supply` read — `ios/<locale>/` and
  /// `android/<locale>/images/phoneScreenshots/`. The default, because it is
  /// the only shape another tool consumes without being told anything.
  fastlane,

  /// `<store>/<class>/<locale>/`, for a human dragging files into a console.
  plain,
}

/// Store screenshots — the named shots of a package's scenarios, at the sizes
/// two stores publish, in a tree an upload tool reads.
///
/// Named `StoreShots` rather than `Store`, which is the state-management word
/// and would collide in half the projects that import this library. It also
/// continues the vocabulary a scenario already uses: `Shot`, `Shots`.
class StoreShots extends Plugin {
  StoreShots({this.apps = const [], String? label})
    : super('flutterware.store', label: label ?? 'Store');

  /// **Apps, not packages.** A package is where the code is; an app is what
  /// ships, and one package can ship several — a white-label product, or two
  /// flavors with two store records. Each carries its own scenarios, its own
  /// frame and its own listings, which is exactly the set of things that was
  /// already per-package here: the unit was always an app, it merely happened
  /// to be named after the package it was built from.
  final List<StoreShotsApp> apps;

  @override
  Map<String, Object?> get config => {
    'apps': [for (var a in apps) a.toJson()],
  };
}

/// One app: where its code is, what it is called, and where it ships to.
class StoreShotsApp extends PluginPackage {
  const StoreShotsApp(
    super.pkg, {
    this.name,
    required this.listings,
    this.frame,
    this.file,
    this.tag,
    this.output,
    this.layout = StoreLayout.fastlane,
  });

  /// What this app is called — in the rail, in the output tree, and in
  /// `--app`.
  ///
  /// Null takes the package's own name from its pubspec, which is right for
  /// the ordinary project that ships one app. Two apps on one package have to
  /// say, and a name that collides with another is the project's own
  /// arithmetic, exactly as two packages writing to one `output:` always was.
  final String? name;

  /// Which stores this app ships to.
  final List<Listing> listings;

  /// The composition, as a package-relative file exporting `storeFrame`.
  ///
  /// ```dart
  /// // tool/store/coffee_frame.dart
  /// final storeFrame = CoffeeFrame.new;
  /// ```
  ///
  /// Null is not "no composition" — it is *no composition anybody chose*, and
  /// the two differ. A set whose canvas is its device's own output is exported
  /// as the app's own pixels, because that is what the app looks like and
  /// inventing a background for it is a marketing decision nobody asked us to
  /// make. A set whose canvas is *not* its device's has no such option — Play's
  /// phone is 2:1 and no Android phone is — and that one gets
  /// `DefaultStoreFrame`, which composes legally and says nothing.
  ///
  /// Declared, the frame applies to **every** set: a project that has chosen a
  /// composition has chosen it for its listing, not for the one set geometry
  /// forced.
  final String? frame;

  /// The scenario file — or directory — the shots come from, relative to the
  /// package.
  ///
  /// Null runs everything the package has, which is rarely what a listing
  /// wants: a store set is a story somebody chose, and the debugging suite is
  /// not it. Declaring a file is how the listing's *order* gets stated, since
  /// the order shots are captured in is the order they are numbered in.
  final String? file;

  /// Keep only shots carrying this tag — `Shot('Home', tags: ['store'])`.
  ///
  /// The escape hatch for a screen that is only reachable through a long
  /// product scenario, so it can be pulled into the listing without being
  /// rewritten. Null keeps every named shot.
  final String? tag;

  /// Where the tree goes, package-relative. `build/flutterware/store` when
  /// null.
  final String? output;

  final StoreLayout layout;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'listings': [for (var l in listings) l.toJson()],
    if (frame != null) 'frame': frame,
    if (file != null) 'file': file,
    if (tag != null) 'tag': tag,
    if (output != null) 'output': output,
    if (layout != StoreLayout.fastlane) 'layout': layout.name,
    if (name != null) 'name': name,
  };

  static StoreShotsApp fromJson(Map<String, Object?> json) => StoreShotsApp(
    Pkg(json['path']! as String),
    name: json['name'] as String?,
    listings: [
      for (var l in json['listings'] as List? ?? [])
        ?Listing.fromJson((l as Map).cast<String, Object?>()),
    ],
    frame: json['frame'] as String?,
    file: json['file'] as String?,
    tag: json['tag'] as String?,
    output: json['output'] as String?,
    layout: json['layout'] == StoreLayout.plain.name
        ? StoreLayout.plain
        : StoreLayout.fastlane,
  );
}
