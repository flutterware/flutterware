import 'package:flutterware/plugins.dart';

/// What flutterware shows for this project.
///
/// One app, so one `Pkg('.')` and every tool pointed at it. A monorepo names a
/// `Pkg` per package and hands each tool the subset it applies to; this is the
/// other case, and it is most projects.
const app = Pkg('.');

void main() => Flutterware.configure((fw) {
  // Brewline is a phone app, so its previews open on a phone rather than on
  // the 900 × 700 rectangle an undeclared package gets. The head of the list
  // is the default and the whole list is what the panel offers.
  fw.use(
    Previews(
      packages: [
        .new(
          app,
          directory: 'demo',
          canvases: [
            PreviewCanvas('', devices: [Devices.iphone16, Devices.androidTall]),
          ],
        ),
      ],
    ),
  );

  // The languages every scenario replays in. Each folder's
  // `flutter_test_config.dart` says the same thing to `flutter test`; this
  // says it to the studio.
  fw.use(
    Scenarios(
      packages: [
        .new(app, languages: ['en', 'fr']),
      ],
    ),
  );

  // The store listing: which stores, which locales, and the widget that frames
  // each shot. It takes no arguments — the declaration *is* the configuration,
  // and `fw run store export` writes the tree `fastlane deliver` reads.
  fw.use(
    StoreShots(
      apps: [
        StoreShotsApp(
          app,
          file: 'test/scenarios/mobile/shop_test.dart',
          // The five shots `A morning order` tags for the listing, not every
          // named shot in the file.
          tag: 'store',
          frame: 'lib/store_frame.dart',
          // Two stores, one phone each. An iPad listing would be this phone
          // layout blown up, and Play's phone is the case that needs a frame
          // at all: its canvas is 2:1 and no Android phone is.
          listings: [
            Listing.appStore(
              locales: {'en': 'en-US', 'fr': 'fr-FR'},
              classes: [AppStoreClass.iphone69],
            ),
            Listing.play(
              locales: {'en': 'en-US', 'fr': 'fr-FR'},
              classes: [PlayClass.phone],
            ),
          ],
        ),
      ],
    ),
  );

  // Where the words are — the one thing a run cannot work out for itself.
  fw.use(
    Translations(
      packages: [
        TranslationsPackage(
          app,
          catalogs: [
            TranslationCatalog(name: 'shop', files: 'assets/i18n/*.json'),
            // The listing's headlines. A second catalog rather than more keys
            // in the first: marketing copy is not UI, and a translator sent
            // the shop's strings should not find `Tap. Pay. Collect.` among
            // them.
            TranslationCatalog(name: 'store', files: 'assets/store/*.json'),
          ],
        ),
      ],
    ),
  );

  fw.use(Dependencies(packages: [.new(app)]));
  fw.use(Assets(packages: [.new(app)]));
  fw.use(NativeSplash(packages: [.new(app)]));
  fw.use(LauncherIcon(packages: [.new(app)]));

  // What to read first when this project's changes are reviewed: the words
  // — a string that moved is a screen that moved, in two languages — then the
  // package and the app's shell. The rest of a delta is ordinary until it
  // proves otherwise.
  fw.changes(
    ChangesConfig(
      attention: [
        'assets/i18n/*.json',
        'pubspec.yaml',
        'lib/shop/shop_app.dart',
      ],
    ),
  );

  fw.use(
    Run(
      packages: [
        .new(
          app,
          entrypoints: [
            Entrypoint(
              'lib/main.dart',
              name: 'Brewline',
              description: 'The coffee shop',
            ),
            Entrypoint(
              'lib/shop_devbar.dart',
              name: 'Brewline (devbar)',
              description:
                  'The shop, with a plugin that pushes a notification into '
                  'it — the sample for driving an app from the cockpit, '
                  '`fw` or an agent',
            ),
          ],
        ),
      ],
    ),
  );
});
