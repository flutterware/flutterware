import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware_app/src/previews/catalog_picture.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

/// The stage after a frame exists, tested without one being drawn.
///
/// These used to live in `frame_capture_test.dart` and reached the crop
/// through a fake socket, because the crop lived behind one. It does not any
/// more: framing a picture is the same work whichever engine drew it, so the
/// test is now what it always meant to be — pixels in, pixels out.
void main() {
  img.Image frame(int width, int height) =>
      img.Image(width: width, height: height);

  test('a crop cuts to a node box, in physical pixels', () {
    // Logical coordinates at ratio 2 — the space `InspectLayout` reports, so a
    // node rect from the panel crops its own picture untransformed.
    var image = framePicture(
      frame(20, 20),
      framing: const PictureFraming(
        crop: InspectLayout(x: 1, y: 1, width: 3, height: 2),
      ),
      pixelRatio: 2,
    );

    expect(image.width, 6);
    expect(image.height, 4);
  });

  test('a crop reaching past the frame is clamped, not refused', () {
    // What an overflow *is*, and the one case most worth being able to see.
    var image = framePicture(
      frame(10, 10),
      framing: const PictureFraming(
        crop: InspectLayout(x: 8, y: 8, width: 40, height: 40),
      ),
    );

    expect(image.width, 2);
    expect(image.height, 2);
  });

  test('nothing asked for leaves the frame alone', () {
    var original = frame(10, 10);

    expect(identical(framePicture(original), original), isTrue);
  });

  group('a tall picture, a screen at a time', () {
    /// A list of [count] rows of [height], each with its words inset, as a
    /// tree reports it.
    InspectTree rows(int count, double height, {double top = 0}) => InspectTree(
      entryId: 'demo/list.dart#list',
      root: InspectNode(
        id: '',
        type: 'ListView',
        layout: InspectLayout(x: 0, y: top, width: 400, height: count * height),
        children: [
          for (var i = 0; i < count; i++)
            InspectNode(
              id: '$i',
              type: 'ListTile',
              layout: InspectLayout(
                x: 0,
                y: top + i * height,
                width: 400,
                height: height,
              ),
              children: [
                InspectNode(
                  id: '$i/0',
                  type: 'Text',
                  description: 'Text("Row $i")',
                  layout: InspectLayout(
                    x: 16,
                    y: top + i * height + 18,
                    width: 60,
                    height: 20,
                  ),
                ),
              ],
            ),
        ],
      ),
    );

    test('is cut between rows, never through one', () {
      // 2800pt in three pages of about 933: each cut goes to the edge of a
      // row nearest its share — after the seventeenth row, not five points
      // into the eighteenth.
      var cuts = pageCuts(rows(50, 56), page: 956, top: 0, bottom: 50 * 56);

      expect(cuts, [952, 1848]);
    });

    test('is shared evenly, so no page is a sliver', () {
      // A screen and a strip is two half screens.
      expect(pageCuts(rows(20, 56), page: 956, top: 0, bottom: 20 * 56), [560]);
    });

    test('takes as few pages as keep the rows whole, and evens them', () {
      // 72pt rows in 852pt screens: a page holds eleven rows at most, so a
      // hundred and two rows are ten pages — and ten pages of ten or eleven
      // rows, not nine full ones and a strip.
      var cuts = pageCuts(rows(102, 72), page: 852, top: 0, bottom: 102 * 72);

      expect(cuts, hasLength(9));
      var edges = [0.0, ...cuts, 102 * 72.0];
      for (var i = 1; i < edges.length; i++) {
        expect(edges[i] % 72, 0);
        expect(edges[i] - edges[i - 1], inInclusiveRange(10 * 72, 11 * 72));
      }
    });

    test('a page where every line crosses something is cut at full height', () {
      // Two columns of boxes half a box out of step: wherever a line falls,
      // it goes through one of them.
      var bricks = InspectTree(
        entryId: 'demo/wall.dart#wall',
        root: InspectNode(
          id: '',
          type: 'Row',
          children: [
            for (var i = 0; i < 40; i++)
              InspectNode(
                id: '$i',
                type: 'Text',
                description: 'Text("Brick $i")',
                layout: InspectLayout(
                  x: i.isEven ? 0 : 200,
                  y: (i ~/ 2) * 100 + (i.isEven ? 0 : 50),
                  width: 200,
                  height: 100,
                ),
              ),
          ],
        ),
      );

      expect(pageCuts(bricks, page: 500, top: 0, bottom: 2000), [
        500,
        1000,
        1500,
      ]);
    });

    test('is measured from the top of a crop', () {
      // A list further down the screen, cropped to: the first page starts
      // where the crop does.
      var cuts = pageCuts(
        rows(40, 56, top: 300),
        page: 956,
        top: 300,
        bottom: 300 + 40 * 56,
      );

      expect(cuts, [728, 1512]);
    });

    test('is written beside the picture, numbered, with no stale pages', () {
      var directory = Directory.systemTemp.createTempSync('fw_pages');
      addTearDown(() => directory.deleteSync(recursive: true));
      var output = p.join(directory.path, 'list.png');
      // A picture that used to be four pages long.
      File(p.join(directory.path, 'list.page-4.png')).writeAsBytesSync([0]);

      var pages = writePages(frame(4, 60), output, [10, 40], pixelRatio: 0.5);

      expect(
        [for (var page in pages) p.basename(page.path)],
        ['list.page-1.png', 'list.page-2.png', 'list.page-3.png'],
      );
      expect(
        [for (var page in pages) img.decodePng(page.readAsBytesSync())!.height],
        [5, 15, 40],
      );
      expect(
        File(p.join(directory.path, 'list.page-4.png')).existsSync(),
        isFalse,
      );
    });
  });

  group('a tester frame', () {
    test('decodes packed rgba, rows in order', () {
      // Two pixels, red then blue. No header and no stride, which is the whole
      // difference from the embedder's `.rawframe`.
      var image = decodeTesterFrame(
        Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]),
        width: 2,
        height: 1,
      );

      expect(image.getPixel(0, 0).r, 255);
      expect(image.getPixel(1, 0).b, 255);
    });

    test('refuses a length the dimensions do not explain', () {
      // The one failure worth catching by hand: a truncated write decodes into
      // a picture that is simply wrong further down, where nothing says why.
      expect(
        () => decodeTesterFrame(Uint8List(7), width: 2, height: 1),
        throwsFormatException,
      );
    });
  });
}
