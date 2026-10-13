/// What to draw around a [Device] — the Flutter half of the device table.
///
/// `devices.dart` is pure Dart so a project can name a device without
/// importing Flutter; this is where those numbers meet a picture, and the only
/// place they do. The previews canvas, a scenario's framed step, a world's
/// people, the devbar's frame and the previews web page all ask here, so an
/// iPhone cannot look like one thing in the studio and another in the export.
library;

import 'package:flutter/widgets.dart';

import 'device_platform.dart';
import 'devices.dart';
import 'island_phone_frame.dart';
import 'third_party/device_frame/lib/device_frame.dart' hide Devices;
// Prefixed: theirs is a hundred hand-drawn bodies, ours is the offered table,
// and [namedFrameFor] is the only thing here that says theirs.
import 'third_party/device_frame/lib/device_frame.dart' as artwork show Devices;

export 'island_phone_frame.dart';
export 'third_party/device_frame/lib/device_frame.dart' hide Devices;

/// The silhouette to draw around [device], or null for a desktop, which gets
/// none: the panel is already a desktop-shaped canvas, and a monitor body
/// scaled down to fit inside it costs more room than it explains.
///
/// Three sources, in this order. Every phone and tablet the table offers
/// borrows a **hand-drawn body** from `device_frame` ([namedFrameFor]) — an SE
/// with its home button, a 16 with its island, a Pixel with its punch hole —
/// because the outline is half of what says *iPhone* or *Android*. An iOS
/// phone with no body gets [islandPhoneFrame], drawn from its own numbers.
/// Anything else gets `device_frame`'s generic silhouette of its
/// [DeviceKind].
///
/// **The drawing is theirs, the safe areas are ours.** A body's safe areas
/// are a snapshot of whichever OS its author measured — landscape insets from
/// iOS 18, an iPad's bottom from before iPadOS 26 — and the table's are
/// measured on what ships now. The body keeps its artwork and its screen,
/// which have to agree with ours or every picture is stretched inside it, and
/// is handed the table's insets, so the layout and the glass it is drawn on
/// cannot disagree about where the status bar is.
///
/// Takes the device **as it stands upright**, and a caller drawing a turned one
/// has to say so: `DeviceFrame` rotates a body it is given an orientation for,
/// so the landscape numbers belong in [DeviceInfo.rotatedSafeAreas] here rather
/// than in a second, sideways `DeviceInfo`.
DeviceInfo? deviceFrameFor(Device device) =>
    _bodyFor(device) ?? _islandFrameFor(device) ?? _genericFrameFor(device);

/// `device_frame`'s hand-drawn body for [id], with its own numbers, or null
/// when it has none.
///
/// By id rather than by size: two phones can share a screen and look nothing
/// alike, and the id is what says which one the table means.
DeviceInfo? namedFrameFor(String id) => switch (id) {
  'iphone-se' => artwork.Devices.ios.iPhoneSE,
  'iphone-13' => artwork.Devices.ios.iPhone13,
  'iphone-16' => artwork.Devices.ios.iPhone16,
  'iphone-16-pro' => artwork.Devices.ios.iPhone16Pro,
  'iphone-16-plus' => artwork.Devices.ios.iPhone16Plus,
  'iphone-12-pro-max' => artwork.Devices.ios.iPhone12ProMax,
  'iphone-16-pro-max' => artwork.Devices.ios.iPhone16ProMax,
  'ipad' => artwork.Devices.ios.iPad,
  'ipad-pro-13' => artwork.Devices.ios.iPadPro13InchesM4,
  'android-small' => artwork.Devices.android.samsungGalaxyS25,
  'android-tall' => artwork.Devices.android.googlePixel9,
  'android-big' => artwork.Devices.android.googlePixel9ProXL,
  _ => null,
};

/// Whether [device] is drawn inside a body at all.
///
/// [deviceFrameFor] answering null is what "no" means. Separate because the
/// frame toggle in the top bar asks it on every build, to know whether it has
/// anything to switch — and building a whole [DeviceInfo], path and all, to
/// throw it away is a strange way to ask a question about a [DeviceKind].
bool canBeFramed(Device device) => device.kind != DeviceKind.desktop;

/// [device]'s named body, wearing the table's safe areas — or null when it has
/// none, or when [device] is a screen the body does not fit.
///
/// The fit check is for a [Device] a project declares under a table id with a
/// size of its own: a body whose glass is the wrong shape would stretch the
/// picture, so that screen is drawn rather than squeezed.
DeviceInfo? _bodyFor(Device device) {
  var body = namedFrameFor(device.id);
  if (body == null || body.screenSize != Size(device.width, device.height)) {
    return null;
  }
  return body.copyWith(
    name: device.label,
    safeAreas: _insetsOf(device),
    rotatedSafeAreas: _insetsOf(device.rotated()),
  );
}

/// Our own iPhone body, for an iOS phone with no artwork.
///
/// A rule about the platform rather than a second list of ids, so a custom
/// iPhone looks like an iPhone without anyone remembering to come back here.
DeviceInfo? _islandFrameFor(Device device) =>
    device.kind == DeviceKind.phone && device.platform == DevicePlatform.ios
    ? islandPhoneFrame(device)
    : null;

DeviceInfo? _genericFrameFor(Device device) {
  var screen = Size(device.width, device.height);
  // **Passed explicitly, because the default is a trap.** `rotatedSafeAreas`
  // defaults to `EdgeInsets.zero` rather than to null, and `canRotate` is
  // `rotatedSafeAreas != null` — so a generic body left to the default claims
  // it rotates and then renders landscape with no notch and no gesture bar at
  // all. Wrong without looking wrong, and only in the rotated case.
  var rotatedSafeAreas = _insetsOf(device.rotated());

  return switch (device.kind) {
    DeviceKind.phone => DeviceInfo.genericPhone(
      platform: device.platform.targetPlatform,
      id: device.id,
      name: device.label,
      screenSize: screen,
      safeAreas: _insetsOf(device),
      rotatedSafeAreas: rotatedSafeAreas,
      pixelRatio: device.pixelRatio,
    ),
    DeviceKind.tablet => DeviceInfo.genericTablet(
      platform: device.platform.targetPlatform,
      id: device.id,
      name: device.label,
      screenSize: screen,
      safeAreas: _insetsOf(device),
      rotatedSafeAreas: rotatedSafeAreas,
      pixelRatio: device.pixelRatio,
    ),
    DeviceKind.desktop => null,
  };
}

EdgeInsets _insetsOf(Device device) => EdgeInsets.fromLTRB(
  device.insetLeft,
  device.insetTop,
  device.insetRight,
  device.insetBottom,
);
