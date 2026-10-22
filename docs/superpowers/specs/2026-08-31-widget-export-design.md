# Render — a widget as SVG, PNG or PDF, server-side

**Date:** 2026-08-31
**Status:** Drafted from a green spike. The capture pipeline — recording
canvas, render-tree text join, TTF *and* CFF glyph outlines, export policies,
raster fallback, `pw.SvgImage` re-integration — lives in `test/vector_export/`
(commits `f8ab2ae0`, `2ee452c6`) with two tests that regenerate every artifact
next to a raster ground truth. Everything else in this document is design.

**Amended by the de-risk experiments (same day, both green).** A hand-rolled
bundle — linux-arm64 `flutter_tester` + `icudtl.dat` + dill + fonts — rendered
SVG and PNG in a **bare `debian:stable-slim` container on the first try**: no
extra packages, no fontconfig, no display, 91ms. A 1000-render warm loop on
one tester process held **16.7ms per render, flat, RSS flat at ~200MB** — the
cadence is exactly 60Hz vsync, so a naive `endOfFrame` loop is frame-paced,
not capture-bound. Two guest facts for the driver: the tester exits when
`main`'s synchronous half returns, so **`--run-forever` is mandatory** for an
async guest, and `exit(0)` ends the run cleanly. The capture census (ten
everyday Material screens) is folded into the fidelity section below. The
guest program and census live in `test/vector_export/export_guest_main.dart`
and `census_test.dart`.

**Naming settled (2026-08-31): the feature is *render*, not *export*.** The
name appears most on the pure-Dart side — the server, the CLI, the
Dockerfile, the pool — exactly where "render" is unambiguous and
"server-side rendering" is the established register. Inside the studio,
"export" already means "take this plugin's data out" on four other panels,
and it says nothing about how; render says what happens. The Flutter side
barely speaks the name (the app binds implementations; the descriptors live
in the contract package), so the `Render*` prefix never sits beside
`RenderObject` code. Vocabulary: a **render point** is the declared entry;
**a render** is one result.

**Lineage:** the spike's findings (this file cites its measurements),
`2026-07-30-scenarios-design.md` (the guest harness and direct-spawn
flutter_tester lane this rides), the previews plugin (the entry/discovery
model this generalizes), the comparison plugin (the regression story),
the run knobs design (the typed-parameter precedent).

## The goal

A Flutter team that renders documents — invoices, reports, charts — should
write them **once, as widgets**, and get them anywhere: a PNG in a test, an
SVG in an email, a PDF from a Dart server that has no Flutter SDK, no GPU
and no display. Today that team either re-implements every visual in PDF
primitives, or rasterizes a headless screenshot and ships blurry text.

The one-sentence story this design must keep true:

> Declare a render point, `fw render bundle`, copy one directory into your
> Docker image, and call it from your server **fully typed**.

Flutterware is unusually close. The hard tenth of the problem — compiling a
kernel, spawning and driving `flutter_tester`, discovering entries, loading
real fonts, regression-diffing rendered output — already exists for the
scenarios and previews lanes. The spike settled the other hard tenth: a
widget's paint pass converts to real vectors in pure Dart, text included,
with no engine fork. What remains is one contract, one command, one
protocol and one panel.

## What the spike settled (facts, not plans)

- **No engine fork.** `dart:ui`'s `Canvas`, `Paragraph`, `ParagraphBuilder`
  are implementable interfaces; a recording canvas plus a render-tree-aware
  `PaintingContext` captures the full paint pass on stock `flutter_tester`.
- **Text is a join.** The string and styles come from `RenderParagraph`; the
  *same* laid-out `ui.Paragraph` answers for line breaks, per-run boxes and
  baselines. Wrap points in the rendered output match the app exactly.
- **Glyphs are extractable.** A TrueType `glyf` reader and a CFF Type2
  charstring interpreter turn any font Flutter renders (CID-keyed CFF
  excepted) into path outlines, placed at the paragraph's own per-character
  positions. Measured on the fixture screen: embed-fonts 2839KB,
  vectorize-all 106KB, system-fonts 27KB.
- **Unsupported ops rasterize faithfully** because ops keep their original
  dart:ui objects (paint with live shader, path, paragraph) and replay onto
  a real canvas into a patch.
- **`package:pdf` closes the loop.** Its SVG renderer accepts the vectorized
  output (`pw.SvgImage`), so a captured widget drops into an existing pw
  layout as one more block. Two traps found and fixed: rgba() alpha is
  dropped (transparency must ride `fill-opacity`/`stroke-opacity`
  attributes), and a `TextPainter` laid out without maxWidth reports
  infinite paragraph width.
- **Painter-drawn labels are raster patches.** Chart libraries paint axis
  labels via `TextPainter` inside a `CustomPainter`; there is no
  `RenderParagraph` to join, so those paragraphs take the raster lane
  (crisp at 3×). This is a documented property, not a bug to fix silently.

## The shape: two entry kinds, one decision

**A widget render** builds a widget; the *caller* chooses the output —
SVG, PNG, or a single-page PDF — and the render options. One entry, three
formats.

**A document render** composes a `pw.Document` itself — multi-page, flowing
text, captured widget blocks dropped in as SVG — and returns PDF bytes.

The decision this split encodes, stated once so it never gets rebuilt:
**pagination is composition, not capture.** One canvas maps to one page or
one block. A "one tall widget, magically paginated" mode is rejected; the
pw widget library already owns flowing layout, and the chart-in-a-report
proof shows the seam is one `pw.SvgImage` call.

## Fully typed, across two processes

The server is pure Dart; the entry runs inside a Flutter guest. Types cross
that boundary through a **shared contract**: the render *point* is a value —
name plus codecs plus phantom types — declared in a pure-Dart package both
sides import. No code generation is required; the descriptor is the
contract.

The contract and the client ship **inside `flutterware`**, as two libraries
that import no Flutter: `package:flutterware/render_contract.dart` (the
descriptor types and the wire-safe options — no `dart:io` either, so a
package importing it still compiles for the web) and
`package:flutterware/render_client.dart` (the same, plus `RenderPool`).

**Amended 2026-09-09.** This shipped first as a separate pure-Dart workspace
member, `flutterware_render`, on the reasoning that a `dart` server cannot
resolve a package depending on the Flutter SDK. True, and folded anyway: the
repo had already taken that bargain for `package:flutterware/server.dart`,
which a shelf server imports directly and which is equally Flutter-free
inside. Paying a second published package, a third version to keep in
lockstep and a second entry in the release workflow to dodge a cost the tool
already charges elsewhere is not worth it — and the cost stops at
resolution: the deployed image still needs nothing but the bundle directory,
which carries its own `flutter_tester`. Nothing was published under the old
name.

**Amended 2026-10-21: the name came back, for the other half.** Folding put
the *capture* pipeline in `flutterware` too, and with it `package:pdf` (and
`vector_math`, used only by the PDF writer) became dependencies of the
runtime package. flutterware 0.6.0 shipped that way: every app adding it for
the devbar or the scenarios resolved `pdf`, `archive`, `barcode`, `bidi`,
`image`, `path_parsing` and `xml`, and took their version ranges into its own
solve. That is the cost the repo works to keep out of the runtime package,
and it is a bigger one than a second published package. So `render/` is
`flutterware_render` again, holding what the 09-09 package did *not*: the
library that was `render.dart` (now `flutterware_render.dart`, the name pub
asks a package's one library to have), the capture, the writers,
`RenderHost` and the driver. The contract and the client stay in
`flutterware`, because the CLI needs them. `render/` cannot be pubignored from
flutterware's archive: pub applies the root `.pubignore` when publishing the
member too, and the package came out empty. So it rides along, invisible to
consumers, and stays a member of the hosted copy. It pins `flutterware` to
one release, since it imports the offscreen mount and the wire protocol from
flutterware's `src/`; an exact pin is refused by the publish validator as a
warning, which fails the release's dry run, hence `>=X <X+1 patch`. The
release publishes it from the same tag, after flutterware.

### 1. The app team's contract package (pure Dart, shared)

```dart
// package:acme_contract/renders.dart
import 'package:flutterware/render_contract.dart';

class ChartRequest {
  ChartRequest({required this.title, required this.series});
  final String title;
  final List<Series> series;

  Map<String, Object?> toJson() => {...};
  static ChartRequest fromJson(Map<String, Object?> json) => ChartRequest(...);
}

/// The render point IS the contract: a name the guest registers under,
/// codecs for the args, and the args type pinned in the type argument.
final monthlyChart = WidgetRender<ChartRequest>(
  'charts/monthly',
  encodeArgs: (args) => args.toJson(),
  decodeArgs: ChartRequest.fromJson,
);

final invoicePdf = DocumentRender<InvoiceRequest>(
  'invoices/invoice',
  encodeArgs: (args) => args.toJson(),
  decodeArgs: InvoiceRequest.fromJson,
);
```

### 2. The app binds implementations (Flutter package)

```dart
// lib/renders.dart in the Flutter app
import 'package:acme_contract/renders.dart';
import 'package:flutterware/render.dart';

@RenderRegistry()
void registerRenders(RenderHost host) {
  host.widget(monthlyChart, (context, args) {
    return MonthlyChart(title: args.title, series: args.series);
  });

  host.document(invoicePdf, (context, args) async {
    // Capture runs in-process: the chart becomes an SVG block inside the
    // pw layout, exactly the seam the spike proved.
    var chart = await context.captureSvg(
      MonthlyChart.forInvoice(args),
      size: const Size(412, 230),
    );
    return buildInvoiceDocument(args, chartSvg: chart.text);
  });
}
```

Discovery reuses the previews mechanism: the registrar is annotated, the
scanner finds it, `fw render bundle -t lib/renders.dart` compiles it as the
guest program. Fonts and assets are declared where the app already declares
them (pubspec fonts + assets ride the bundle the way they ride the tester
lane today).

### 3. Packaging

```sh
fw render bundle --target lib/renders.dart --platform linux-x64 --out build/render-bundle
```

One directory: `flutter_tester`, `icudtl.dat`, the app dill, the asset
bundle, the fonts, a driver executable, and a manifest binding engine hash
to dill. The 2GB SDK stays on the build machine.

```dockerfile
FROM debian:stable-slim
COPY build/render-bundle /opt/acme/render
# the server binary is the team's own; the bundle is data to it
```

The driver refuses a mismatched tester/dill pair at startup. Version drift
is impossible, not documented.

### 4. The server (pure Dart — the code the question asked for)

```dart
import 'package:acme_contract/renders.dart';
import 'package:flutterware/render_client.dart';
import 'package:shelf/shelf.dart';

late final RenderPool renders;

Future<void> main() async {
  renders = await RenderPool.start(
    bundle: '/opt/acme/render',
    warm: 2, // two resident guests; cold spawn ~2.5s, warm render ~0.3s
  );
  // ... serve ...
}

Future<Response> chartHandler(Request request) async {
  // Fully typed: `monthlyChart` is WidgetRender<ChartRequest>, so `args`
  // must be a ChartRequest and the compiler holds the line. The result is
  // an SvgResult because .svg() was asked for.
  var svg = await renders.svg(
    monthlyChart,
    ChartRequest(title: 'Monthly active devices', series: fetchSeries()),
    size: const RenderSize(412, 230),
    options: const RenderOptions(
      text: TextPolicy.vectorize,
      textByFamily: {'MaterialIcons': TextPolicy.vectorize},
      unsupported: UnsupportedPolicy.rasterize,
    ),
  );

  // The capture's honesty surfaces instead of vanishing:
  for (var warning in svg.warnings) {
    log.info('render warning: $warning'); // dropped runs, raster patches…
  }

  return Response.ok(svg.text, headers: {'content-type': 'image/svg+xml'});
}

Future<Response> invoiceHandler(Request request) async {
  var pdf = await renders.pdf(invoicePdf, InvoiceRequest.fromJson(...));
  return Response.ok(pdf.bytes, headers: {'content-type': 'application/pdf'});
}

// The same widget entry, other formats:
//   renders.png(monthlyChart, args, size: ..., pixelRatio: 2)  → PngResult
//   renders.pdfPage(monthlyChart, args, size: ...)             → PdfResult
```

Typing rules, precisely: `svg`/`png`/`pdfPage` accept a
`WidgetRender<A>` and an `A`; `pdf` accepts a `DocumentRender<A>` and an
`A`. Results are distinct types (`SvgResult.text`, `PngResult.bytes`,
`PdfResult.bytes`), each carrying `warnings` and `timings`. Handing the
wrong args type, or asking `.pdf()` of a widget entry, is a compile error
on the server — the process boundary costs no type safety.

### Wire-safe render options

The spike's `VgExportOptions.textMode` is a per-run *callback* — expressive
in-process, unserializable on a wire. The wire options are **data**:

```dart
class RenderOptions {
  const RenderOptions({
    this.text = TextPolicy.embedFont,      // vectorize | embedFont | systemFont
    this.textByFamily = const {},          // per-family override — the real
                                           // per-run need was icons vs body
    this.unsupported = UnsupportedPolicy.rasterize, // | flatten | skip
    this.rasterScale = 3,
  });
}
```

The guest compiles these to the callback form. Document entries, running
in-process, may use the full callback API directly.

## The pieces, mapped

| Piece | State |
| --- | --- |
| Capture pipeline (canvas, text join, TTF+CFF outlines, policies, raster lane) | **Built** — `lib/src/render/`, public as `captureSvg`/`capturePdf` in `package:flutterware/render.dart`; effect layers route through the policy, warnings are typed |
| Kernel compile, seed-kernel warm start, build isolation | **Exists** (`TesterHost`, scenarios/previews lanes) |
| Spawn/drive `flutter_tester`, guest harness, real fonts | **Exists** (embedder + previews harness) |
| Entry discovery, typed parameters | **Exists as precedent** (previews discovery, run knobs) — needs the render flavor |
| `WidgetRender`/`DocumentRender` contract | **Built** — `package:flutterware/render_contract.dart`; registrar (`@RenderRegistry` on a function receiving `RenderHost`) settled over per-entry annotations; `RenderContext.captureSvg` mounts widgets offscreen, so both entry kinds execute in-process |
| `fw render bundle` | **Built** — registrar scan, generated driver main, kernel via the embedder compiler, asset bundle with symlinks materialized, engine artifacts local or fetched per `--platform`, versions bound in `manifest.json` |
| `RenderPool` + driver protocol | **Built** — `package:flutterware/render_client.dart` over marker-prefixed line JSON on the guest's stdio; guest mounts offscreen per request (no frame pacing), covered end to end by `app/integration_test/render_bundle_test.dart` |
| Studio panel: render entries live, knobs for args, document viewer | **Built (v1)** — `flutterware.render` plugin: point list from the warm guest, JSON args + size + policies, instant PNG preview, Save SVG/PNG/PDF, warnings shown. Typed knobs for args and an in-studio PDF page viewer are the follow-ups |
| `fw render <entry>` one-shot CLI | **Built** — plus the same render as a plugin action for `fw run`/MCP, returning an `Artifact` |
| Regression diffs of rendered documents | **Deferred, deliberately** — `ComparisonSide` is a real seam (a `RendersSide` is a genuine third implementation, ~250 lines), but its currency is raw RGBA frames and its skip rule keys on source files: all points share one registrar file, so per-point attribution needs a decision before the hookup is honest |
| Reproducibility: pinned clock, locale, seeded random | **Exists as precedent** (scenario clock slot) |
| Structured errors with stacks over the wire | **Exists as precedent** (scenario step events) |

## The dev loop is the differentiator

The same entry the server invokes headless renders live in the studio:
knobs tab for its typed args, hot reload, a document viewer for PDF pages.
A team develops the invoice *looking at it*, and production runs the
identical function on the identical runtime. `fw render` gives CI and
scripts the one-shot form; the comparison plugin answers "did this commit
change the invoice" with a diff of rendered output.

This panel is what makes the feature flutterware-shaped. Without it, the
bundle and pool are a good Docker recipe; with it, the whole document
pipeline lives where the app lives.

## Render is not screenshot

A `@Preview` entry is a degenerate render point — named, discoverable,
argumentless — so `fw render <entry> --as=svg|pdf|png` accepts preview
entries as targets alongside render points: everything previewable is
renderable. But the verbs never merge, because they make different
promises:

- **`previews screenshot` is a camera.** It returns what the engine
  actually rasterized — evidence. The agent loop and the human trust it to
  answer "does this border survive its corner", so it must never need a
  warnings channel.
- **`fw render` is an illustrator.** It returns a document reconstructed
  under stated policies — a deliverable — and its contract *includes*
  warnings: dropped runs, raster patches, effects it could not express.

`fw render --as=png` is fine (the camera at a deliverable's doorstep). The
reverse — screenshot growing vector formats — stays off the table
permanently. The rule to teach: *screenshot tells you the truth about
pixels; render gives you a document and tells you the truth about what it
couldn't express.*

## Constraints and the fidelity backlog

- `flutter_tester` is per-OS/arch; the bundle targets linux-x64 first and
  tracks what the SDK ships (arm64 when its artifacts do).
- Pure Dart only in the guest: plugins with native code do not exist in the
  tester. Charts, capture and `package:pdf` all satisfy this;
  `path_provider`-style plugins do not.
- **Census over ten everyday Material screens** (buttons, text fields,
  dialogs, selection controls, cards/lists, navigation, backdrop blur,
  shader mask, data table, tab bar): geometry and text coverage is nearly
  total — one unhandled op in the lot (`drawArc`, from
  `CircularProgressIndicator`; trivial to add), and two unrecovered
  paragraphs per text field (`RenderEditable` — joinable exactly like
  `RenderParagraph`, a known follow-up). The important negative finding:
  **layer-level effects drop silently.** `BackdropFilter` and `ShaderMask`
  ride `pushLayer`, which the capture inlines — the child paints, the
  effect vanishes, and *nothing is flagged*. **Fixed at promotion time:**
  `pushLayer` (and `pushColorFilter`, which previously lost its whole
  subtree to `noSuchMethod`) now routes these layers through the
  unsupported-op policy as effect spans — shader mask, image filter and
  color filter replay their span into a raster patch with the effect
  applied; a backdrop filter, whose input is everything painted before it,
  keeps its child and warns.
- Path curves are polyline-sampled (dart:ui hides path verbs) — visually
  fine, documented. PDF gradients want `PdfShading`; blend modes,
  `saveLayer` bounds and `drawVertices` land in the raster lane.
- Painter-drawn text (TextPainter in a CustomPainter) is raster patches
  unless the app renders labels as widgets or provides a
  paragraph-to-string hook. Complex scripts and bidi need per-box splitting
  before the text lanes are trustworthy beyond Latin.
- `systemFont` mode: run positions are Flutter's, glyph widths are the
  viewer's — inter-run spacing drifts at style boundaries. It trades
  fidelity for size, and the docs must say so.

## Open questions

- **Intrinsic sizing** — `size:` is explicit in v1; "measure the widget
  under constraints" is a wanted follow-up with real layout questions.
- ~~**Driver protocol spelling**~~ — settled (2026-08-31): line-delimited
  JSON over stdio, one guest per pool slot supervised by the pool. Guest →
  server lines carry an `@fw-render ` marker so the app's own logging can
  never corrupt a reply; the guest additionally redirects `print` to
  stderr. One more finding: the driver mounts each request offscreen
  (`OffscreenWidget`), so nothing waits on vsync — the 16.7ms warm-loop
  figure was frame pacing, not a floor.
- ~~**Discovery spelling**~~ — settled (2026-08-31): one annotated
  registrar, as shown above. It keeps the contract package free of magic,
  and the point names being runtime values means listing them was always
  going to run the registrar anyway.
- **Result streaming** — bytes ride the protocol base64-encoded for now;
  file-path handoff inside the container is the follow-up if a real
  deployment's PDFs get big enough to care.
- **Where the capture library lands** — the guest half is published API
  the moment consumers' bundles compile against it; the same publish
  discipline as `lib/src/scenarios/` applies.
