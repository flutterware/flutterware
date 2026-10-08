# Asset fixtures

These exist for the asset inspector, not for the example app — nothing here
is referenced from its Dart code yet.

**Several are wrong on purpose.** This directory is the audit's test suite, so
every finding the audit is meant to produce has something here to find. Fixing
one of these "bugs" breaks the case it stands for.

## What resolves

| fixture | exercises |
|---|---|
| `images/logo.png` + `images/2.0x/`, `images/3.0x/` | a complete density set |
| `images/hero.png` | a 1024² raster, so the weight report has an offender |
| `icons/check.svg` | a declaration in string form |
| `icons/heart.svg` | a declaration in **map form** (`- path:`) |
| `animations/pulse.json` | 2 layers, 30fps, frames 0–60, 2 markers — the Lottie metadata the core reads without the `lottie` package |
| `fonts/Roboto-{Regular,Bold}.ttf` | a family with two weights |
| `packages/flutterware/assets/figma_logo.png` | **not here** — it comes from the `flutterware` dependency, and is the fixture for D3 (dependency assets belong to the bundle that pulls them in) |

## What is wrong on purpose

| fixture | the finding it stands for |
|---|---|
| `images/icons/star.png` | a directory declaration **does not recurse**. `assets/images/` is declared, this file is inside it, and it never reaches the bundle |
| `images/badge.png` + `images/3.0x/badge.png` | a `3.0x` with no `2.0x` beside it |
| `images/wordmark.png` | byte-identical to `logo.png` under a second key |

Every fixture above is a *file* that is wrong. There are deliberately no
**declared-but-absent** fixtures — `missingFile` and `missingFontFile` — even
though the audit reports both, and the reason is that this package has to stay
buildable: `flutter build` treats a declared asset with no file as fatal, so one
of those fixtures makes `fw run ui_catalog build-web` (and every other build of
this example) impossible. Both findings are covered instead by
`app/test/assets/asset_catalog_test.dart`, which can declare a missing file
without having to compile anything.

## Provenance

The PNGs are generated flat squares; colour encodes density (base blue, `2.0x`
green, `3.0x` orange) so a preview showing the wrong variant is *visible* rather
than merely wrong.

The fonts are the Roboto copies already vendored at
`app/lib/src/utils/fonts/Roboto/`, Apache-2.0, with `LICENSE.txt` alongside them
as that licence requires.
