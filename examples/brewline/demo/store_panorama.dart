/// The shop's store frame, drawn as a listing rather than as one picture.
///
/// Five canvases side by side, which is the only way to see whether a panorama
/// actually joins. A frame that looks right on its own can still restart its
/// scene at every boundary, and one preview would never show it — the join is
/// the thing being built, so the join has to be what is on screen.
///
/// The screens inside are painted here, so this needs no export behind it and
/// iterates at the speed of `previews screenshot` rather than of a listing.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/store.dart';
import 'package:brewline/store_frame.dart';

const _slugs = ['welcome', 'menu', 'drink', 'cart', 'order-placed'];

@Preview(name: 'Coffee frame · the whole listing', group: 'Store')
Widget coffeeListing() =>
    _listing(PlayClass.phone.canvas, PlayClass.phone.device);

@Preview(name: 'Coffee frame · one shot', group: 'Store')
Widget coffeeOne() =>
    _listing(PlayClass.phone.canvas, PlayClass.phone.device, only: 3);

@Preview(name: 'Coffee frame · App Store canvas', group: 'Store')
Widget coffeeAppStore() =>
    _listing(AppStoreClass.iphone69.canvas, AppStoreClass.iphone69.device);

Widget _listing(StoreCanvas canvas, Device device, {int? only}) {
  var images = [
    for (var i = 0; i < _slugs.length; i++) _StandIn(index: i, device: device),
  ];
  var shots = [
    for (var i = 0; i < _slugs.length; i++)
      StoreShot(
        image: images[i],
        set: images,
        imageSize: Size(device.width, device.height),
        slug: _slugs[i],
        index: i + 1,
        total: _slugs.length,
        locale: const Locale('en'),
        device: device,
        canvas: canvas,
      ),
  ];
  // **The `Row` needs its own `Directionality`.** `StoreFrameStage` supplies
  // one *inside* each canvas — that is how a frame gets RTL from its locale —
  // but the row laying the canvases side by side is above them, and these
  // entries declare no wrapper of their own. Without it the flex asserts
  // "Horizontal RenderFlex with multiple children has a null textDirection"
  // and everything under it fails to lay out. `previews screenshot` drew a
  // picture anyway; `previews audit` is what reported it.
  return Directionality(
    textDirection: TextDirection.ltr,
    child: FittedBox(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var shot in shots)
            if (only == null || only == shot.index)
              StoreFrameStage(shot: shot, child: CoffeeStoreFrame(shot)),
        ],
      ),
    ),
  );
}

/// A painted stand-in for a captured screen — enough shape to judge the
/// composition around it, and obviously not the real app.
class _StandIn extends ImageProvider<_StandIn> {
  const _StandIn({required this.index, required this.device});

  final int index;
  final Device device;

  static const _grounds = [
    Color(0xFFFDF3EC),
    Color(0xFFFFF6F0),
    Color(0xFFFBF1E8),
  ];

  @override
  Future<_StandIn> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_StandIn key, ImageDecoderCallback _) =>
      OneFrameImageStreamCompleter(_paint());

  Future<ImageInfo> _paint() async {
    var width = device.width;
    var height = device.height;
    var recorder = ui.PictureRecorder();
    var canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = _grounds[index % _grounds.length],
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(width * 0.08, height * 0.07, width * 0.5, height * 0.035),
        const Radius.circular(8),
      ),
      Paint()..color = const Color(0x555C2E1A),
    );
    var ink = Paint()..color = const Color(0x1A5C2E1A);
    for (var row = 0; row < 5; row++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            width * 0.08,
            height * (0.17 + row * 0.1),
            width * 0.84,
            height * 0.075,
          ),
          const Radius.circular(12),
        ),
        ink,
      );
    }
    var image = await recorder.endRecording().toImage(
      width.round(),
      height.round(),
    );
    return ImageInfo(image: image);
  }

  @override
  bool operator ==(Object other) =>
      other is _StandIn && other.index == index && other.device == device;

  @override
  int get hashCode => Object.hash(index, device);
}
