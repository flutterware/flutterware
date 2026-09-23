/// The store stage — a shot where it will be seen, beside its neighbours.
///
/// Stacked rather than behind a picker, so a variant that breaks breaks in
/// front of you: the tablet's 3:4 shots in a row sized for a phone's 1:2, an
/// app name with no natural bound, a set of one where nothing runs off the
/// edge and the whole "there are more" reading collapses.
///
/// The shots are painted here, so none of this needs an export behind it.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/store/stage.dart';

import 'app_theme.dart';

@Preview(name: 'Store stage · product page', wrapper: wrapInAppTheme)
Widget stageProductPage() => _stage(AppStoreClass.iphone69);

@Preview(name: 'Store stage · search result', wrapper: wrapInAppTheme)
Widget stageSearchResult() =>
    _stage(AppStoreClass.iphone69, placement: StorePlacement.searchResult);

@Preview(name: 'Store stage · tablet', wrapper: wrapInAppTheme)
Widget stageTablet() => _stage(AppStoreClass.ipad13);

@Preview(name: 'Store stage · 2:1 canvas', wrapper: wrapInAppTheme)
Widget stagePlayPhone() => _padded(
  StoreStage(
    shots: _shots(
      3,
      PlayClass.phone.canvas.width / PlayClass.phone.canvas.height,
    ),
    aspect: PlayClass.phone.canvas.width / PlayClass.phone.canvas.height,
    appName: 'Brewline',
    subtitle: 'Order ahead from the café on your corner',
  ),
);

/// The two shapes that break a row: nothing to run off the edge, and a name
/// with no natural bound.
@Preview(name: 'Store stage · awkward', wrapper: wrapInAppTheme)
Widget stageAwkward() => ListView(
  padding: const EdgeInsets.all(24),
  children: [
    _bare(_stageFor(AppStoreClass.iphone69, count: 1)),
    const SizedBox(height: 24),
    _bare(
      StoreStage(
        shots: _shots(4, _aspectOf(AppStoreClass.iphone69)),
        aspect: _aspectOf(AppStoreClass.iphone69),
        appName: 'Brewline Coffee Company International',
        subtitle:
            'Order ahead from the café on your corner, pay in the app, and '
            'skip the queue entirely — every morning, in every city',
      ),
    ),
  ],
);

double _aspectOf(AppStoreClass c) => c.canvas.width / c.canvas.height;

Widget _stage(
  AppStoreClass display, {
  StorePlacement placement = StorePlacement.productPage,
}) => _padded(_stageFor(display, placement: placement));

StoreStage _stageFor(
  AppStoreClass display, {
  int count = 6,
  StorePlacement placement = StorePlacement.productPage,
}) => StoreStage(
  shots: _shots(count, _aspectOf(display)),
  aspect: _aspectOf(display),
  appName: 'Brewline',
  subtitle: 'Order ahead from the café on your corner',
  placement: placement,
);

Widget _padded(Widget child) =>
    Padding(padding: const EdgeInsets.all(24), child: _bare(child));

Widget _bare(Widget child) => Align(alignment: Alignment.topLeft, child: child);

List<ImageProvider> _shots(int count, double aspect) => [
  for (var i = 0; i < count; i++) StandInShot(index: i, aspect: aspect),
];

/// A painted stand-in for an exported screenshot.
///
/// Obviously not a real app, and different enough per index that a row of them
/// reads as several screenshots rather than one repeated — which is what the
/// carousel is being judged on.
class StandInShot extends ImageProvider<StandInShot> {
  const StandInShot({required this.index, required this.aspect});

  final int index;
  final double aspect;

  static const _grounds = [
    Color(0xFFFDF3EC),
    Color(0xFFEFF4FA),
    Color(0xFFF3F0F8),
    Color(0xFFEDF6F0),
  ];

  @override
  Future<StandInShot> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(StandInShot key, ImageDecoderCallback _) =>
      OneFrameImageStreamCompleter(_paint());

  Future<ImageInfo> _paint() async {
    var width = 600.0;
    var height = width / aspect;
    var recorder = ui.PictureRecorder();
    var canvas = Canvas(recorder);
    var ground = _grounds[index % _grounds.length];
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = ground,
    );
    var ink = Paint()..color = const Color(0x22000000);
    // A header band and a stack of rows — enough shape to tell one shot from
    // the next at carousel size, and nothing that pretends to be an app.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(width * 0.08, height * 0.06, width * 0.55, height * 0.05),
        const Radius.circular(8),
      ),
      Paint()..color = const Color(0x55000000),
    );
    for (var row = 0; row < 4 + index % 3; row++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            width * 0.08,
            height * (0.18 + row * 0.11),
            width * 0.84,
            height * 0.08,
          ),
          const Radius.circular(10),
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
      other is StandInShot && other.index == index && other.aspect == aspect;

  @override
  int get hashCode => Object.hash(index, aspect);
}
