/// Where Flutter's design libraries live, now that the SDK no longer holds
/// them.
///
/// Material and Cupertino used to be `package:flutter`, so "inside
/// `package:flutter`" was how a report told the framework's code from the
/// app's — and it is how the SDK's own inspector still tells them apart. They
/// are pub packages now, `material_ui` and `cupertino_ui`, and to someone
/// reading about their own app they are still the framework. Every place that
/// draws that line asks about these as well.
library;

/// The design libraries as a stack frame spells a location.
const designLibraryPackages = ['package:material_ui/', 'package:cupertino_ui/'];

/// A resolved file inside one of the design libraries, as the inspector
/// spells a creation location: from the pub cache
/// (`…/material_ui-1.4.0/lib/…`) or from a checkout of the packages
/// repository (`…/packages/material_ui/lib/…`).
final designLibraryFile = RegExp(r'/(material|cupertino)_ui(-[^/]+)?/lib/');
