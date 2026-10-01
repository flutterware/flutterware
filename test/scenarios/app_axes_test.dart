import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/scenarios/app_axes.dart';

/// The app's own axes as text: the one grammar `--axes=`, `FW_AXES` and
/// `fw.axes` share, and the one order every directory name writes them in.
void main() {
  group('parseAppAxes', () {
    test('one value per axis reads as a preview axis does', () {
      expect(parseAppAxes('brand=tea,contrast=high'), {
        'brand': ['tea'],
        'contrast': ['high'],
      });
    });

    test('a part without `=` is another value of the axis before it', () {
      expect(parseAppAxes('brand=coffee,tea,contrast=high'), {
        'brand': ['coffee', 'tea'],
        'contrast': ['high'],
      });
    });

    test('an axis named twice gathers both — a repeated flag joined', () {
      expect(parseAppAxes('brand=coffee,brand=tea,brand=coffee'), {
        'brand': ['coffee', 'tea'],
      });
    });

    test('a JSON object, with a value or a list', () {
      expect(parseAppAxes('{"brand": ["coffee", "tea"], "contrast": "high"}'), {
        'brand': ['coffee', 'tea'],
        'contrast': ['high'],
      });
    });

    test('blank is nothing, and spaces are not part of a word', () {
      expect(parseAppAxes('  '), isEmpty);
      expect(parseAppAxes(' brand = tea , coffee '), {
        'brand': ['tea', 'coffee'],
      });
    });

    test('a value with no axis before it is refused, saying how', () {
      expect(
        () => parseAppAxes('tea'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('brand=coffee,tea'),
          ),
        ),
      );
      expect(() => parseAppAxes('brand='), throwsFormatException);
      expect(() => parseAppAxes('=tea'), throwsFormatException);
    });
  });

  group('appAxisProblems', () {
    test('a declaration a directory can carry has none', () {
      expect(
        appAxisProblems({
          'brand': ['coffee', 'tea'],
          'contrast': ['normal', 'high-1.5'],
        }),
        isEmpty,
      );
    });

    test('an axis with no values, or a value written twice', () {
      expect(appAxisProblems({'brand': []}), [contains('no values')]);
      expect(
        appAxisProblems({
          'brand': ['tea', 'tea'],
        }),
        [contains('twice')],
      );
    });

    test('a word a path or a command line would cut', () {
      expect(
        appAxisProblems({
          'brand': ['tea, please'],
        }),
        [contains('`tea, please`')],
      );
      expect(
        appAxisProblems({
          'my brand': ['tea'],
        }),
        [contains('`my brand`')],
      );
    });
  });

  test('a slug writes values only, by axis name', () {
    expect(appAxisSlugParts({'contrast': 'high', 'brand': 'tea'}), [
      'tea',
      'high',
    ]);
  });

  test('a command line spells them back the way it reads them', () {
    var values = {'contrast': 'high', 'brand': 'tea'};
    expect(formatAppAxes(values), 'brand=tea,contrast=high');
    expect(parseAppAxes(formatAppAxes(values)), {
      'brand': ['tea'],
      'contrast': ['high'],
    });
  });

  test('points cross every axis, the last turning fastest', () {
    expect(
      appAxisPoints({
        'brand': ['coffee', 'tea'],
        'contrast': ['normal', 'high'],
      }),
      [
        {'brand': 'coffee', 'contrast': 'normal'},
        {'brand': 'coffee', 'contrast': 'high'},
        {'brand': 'tea', 'contrast': 'normal'},
        {'brand': 'tea', 'contrast': 'high'},
      ],
    );
    // One empty point, so a caller always has something to loop over.
    expect(appAxisPoints({}), [<String, String>{}]);
  });
}
