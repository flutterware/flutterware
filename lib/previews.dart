/// What a project writes beside its `@Preview`s: a shell, and knobs.
///
/// The annotation itself is **not here** — it is Flutter's, from
/// `package:flutter/widget_previews.dart`, and a preview that wants nothing
/// from this library does not import it. That is why the library is kept
/// being small: the dependency is incremental, paid when you want a shell or a
/// knob rather than to declare a preview at all.
///
/// Deliberately small for the other reason too — this is published surface, and
/// every name here is a semver commitment. The machinery the flutterware GUI
/// drives inside the guest lives in `previews_guest.dart`, imported only by
/// generated code.
///
/// See also `ui_catalog.dart`, which is the *other* thing: a browsable page you
/// ship inside your own app, hosting these same previews.
library;

// A shell declares the top bar's axes by asking [PreviewAxes] for them while it
// builds, and is named by a preview's `wrapper:`.
export 'src/ui_catalog/axes.dart' show PreviewShell, PreviewAxes;
// Knobs: `context.knobs.string('label', 'Hello')`, answered by the panel, the
// CLI and an agent — and by the defaults written at the call site when nothing
// is hosting. One word, all the way down: it is what `--knobs=` sets and what
// `KnobDescriptor` carries.
export 'src/ui_catalog/knobs.dart' show Knobs;
export 'src/ui_catalog/ui_catalog.dart' show KnobsExtension;
// How a picker is drawn, knob or axis: `style: PickerStyle.segmented`.
export 'src/ui_catalog/knob.dart' show PickerStyle;
