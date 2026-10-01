/// The catalog page: a browsable index of your previews.
///
/// What this is for, stated plainly, because it changed. `UICatalog` is
/// what `fw run previews build-web` mounts — it is the page's shell, and that
/// is the supported way to reach it. Mounting it yourself still works and is
/// still tested, but nothing is designed around it any more: the generated
/// page is discovered from `@Preview` annotations, where the widget takes a
/// hand-written map, and the map is the older half of the same tool.
///
/// Not the Previews tool. That is `previews.dart` and the `Previews` plugin
/// — a panel, a CLI and an MCP surface driving a guest engine. Previews is
/// where you work; this is what you publish for people who are not going to
/// run the tool.
///
/// It hosts the same previews. `UICatalog` renders whatever the scan found,
/// knobs and all, which is why [Knobs] is re-exported here, with the
/// [PickerStyle] its pickers take — `context.knobs`
/// reads the same on a catalog page as in a preview, because it is the same
/// thing being read. A `PreviewShell`'s axes are drawn too, so a page published
/// to be read in a second language can actually be switched into one.
library;

export 'src/ui_catalog/form_factor.dart' show FormFactor;
export 'src/ui_catalog/figma.dart' show Figma;
export 'src/ui_catalog/knob.dart' show PickerStyle;
export 'src/ui_catalog/knobs.dart' show Knobs;
export 'src/ui_catalog/ui_catalog.dart'
    show UICatalog, KnobsProvider, KnobsExtension;
