/// The default store frame, on the two canvases that differ most.
///
/// Rendered rather than reasoned about: a composition is a picture, and the
/// only way to know whether a caption band and a bleeding device body read as
/// a store screenshot is to look at one. The capture inside is a stand-in
/// painted here, so this entry needs no run behind it.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/store.dart';

@Preview(name: 'Store frame · iPhone 6.9"')
Widget iphoneFrame() => _framed(
  AppStoreClass.iphone69.device,
  AppStoreClass.iphone69.canvas,
  'Every café on your way to work',
);

@Preview(name: 'Store frame · Play phone')
Widget playFrame() => _framed(
  PlayClass.phone.device,
  PlayClass.phone.canvas,
  'Order ahead, skip the queue',
);

@Preview(name: 'Store frame · no headline')
Widget bareFrame() =>
    _framed(AppStoreClass.iphone69.device, AppStoreClass.iphone69.canvas, null);

/// The one composition the default frame is actually *forced* into — Play's
/// phone, whose canvas is not its device — with the band a project that
/// declared no headline gets. The two halves of [DefaultStoreFrame]'s layout
/// meet here, and whether the body bleeds or floats is only answerable by
/// looking.
@Preview(name: 'Store frame · Play phone, no headline')
Widget playBareFrame() =>
    _framed(PlayClass.phone.device, PlayClass.phone.canvas, null);

Widget _framed(Device device, StoreCanvas canvas, String? headline) {
  var shot = StoreShot(
    image: _StandInApp(device: device),
    imageSize: Size(device.width, device.height),
    slug: 'menu',
    index: 1,
    total: 4,
    locale: const Locale('en'),
    device: device,
    canvas: canvas,
  );
  return FittedBox(
    child: StoreFrameStage(
      shot: shot,
      child: DefaultStoreFrame(shot, headline: headline),
    ),
  );
}

/// A painted stand-in for a captured screen — enough shape to judge the
/// composition around it, and obviously not a real app.
class _StandInApp extends ImageProvider<_StandInApp> {
  const _StandInApp({required this.device});

  final Device device;

  @override
  Future<_StandInApp> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _StandInApp key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_paint());

  Future<ImageInfo> _paint() async {
    var width = (device.width * device.pixelRatio).round();
    var height = (device.height * device.pixelRatio).round();
    var recorder = ui.PictureRecorder();
    var canvas = Canvas(recorder);
    var size = Size(width.toDouble(), height.toDouble());
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFBF5),
    );
    var unit = size.width / 12;
    for (var row = 0; row < 6; row++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(unit, unit * (4 + row * 2.2), unit * 10, unit * 1.7),
          Radius.circular(unit * 0.3),
        ),
        Paint()..color = const Color(0xFFEDE6DA),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(unit, unit * 1.6, unit * 6, unit * 1.1),
        Radius.circular(unit * 0.2),
      ),
      Paint()..color = const Color(0xFF1D9E75),
    );
    var picture = recorder.endRecording();
    return ImageInfo(image: await picture.toImage(width, height));
  }

  @override
  bool operator ==(Object other) =>
      other is _StandInApp && other.device.id == device.id;

  @override
  int get hashCode => device.id.hashCode;
}
