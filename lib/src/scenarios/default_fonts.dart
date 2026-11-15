/// Plain Dart, so `fw` can read it as well as the test process.
library;

/// Every family the SDK's own themes fall back to when a style names none —
/// material and cupertino typography across the platforms a device profile
/// can put a scenario on.
const scenarioDefaultFontFamilies = [
  'Roboto',
  '.AppleSystemUIFont',
  'CupertinoSystemDisplay',
  'CupertinoSystemText',
  'Segoe UI',
];

/// The Roboto faces Flutter ships in `bin/cache/artifacts/material_fonts`,
/// by weight, which a `flutter test` run draws [scenarioDefaultFontFamilies]
/// in.
const robotoFaceFiles = {
  100: 'Roboto-Thin',
  300: 'Roboto-Light',
  400: 'Roboto-Regular',
  500: 'Roboto-Medium',
  700: 'Roboto-Bold',
  900: 'Roboto-Black',
};
