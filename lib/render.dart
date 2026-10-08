/// Render a widget's painted output as a real vector document.
///
/// [captureSvg] and [capturePdf] replay a laid-out [RenderObject]'s paint
/// pass — no engine change, no compositing — into SVG or a single-page PDF;
/// [captureWidgetSvg]/[captureWidgetPdf]/[captureWidgetPng] mount a widget
/// offscreen first. Text stays text (or becomes glyph outlines read from
/// the font file, per [CaptureOptions.text]); what no vector format can
/// express follows [CaptureOptions.unsupported]: a raster patch, a flat
/// stand-in, or nothing. The result's warnings list everything the output
/// does not carry exactly as the engine would have drawn it.
///
/// The server-side story starts here too: render points are declared as
/// typed values in a contract the app and the server share (re-exported
/// below, and by `package:flutterware/render_client.dart` for the server),
/// and the app binds implementations to them in a function marked
/// [RenderRegistry], receiving a [RenderHost].
library;

export 'render_contract.dart'
    show
        DocumentRender,
        PdfResult,
        PngResult,
        RenderOptions,
        RenderPoint,
        RenderSize,
        RenderWarning,
        RenderWarningKind,
        SvgResult,
        TextPolicy,
        UnsupportedPolicy,
        WidgetRender;

export 'src/render/driver.dart' show runRenderDriver;
export 'src/render/host.dart'
    show
        BoundDocumentRender,
        BoundRender,
        BoundWidgetRender,
        RenderBindings,
        RenderContext,
        RenderHost,
        RenderOptionsToCapture,
        RenderRegistry;
export 'src/render/model.dart'
    show CaptureOptions, RenderFont, TextCluster, TextRun;
export 'src/render/offscreen.dart' show OffscreenWidget;
export 'src/render/render_capture.dart'
    show
        capturePdf,
        captureSvg,
        captureWidgetPdf,
        captureWidgetPng,
        captureWidgetSvg;
