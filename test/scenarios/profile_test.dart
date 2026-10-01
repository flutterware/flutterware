import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/profile.dart';

/// What one `flutter test` invocation declares: the profile's heads by
/// default, the request's lists when CI names them.
void main() {
  const phones = ScenarioProfile(
    'phones',
    devices: [Devices.iphone16, Devices.iphoneSe],
    languages: ['en', 'fr'],
  );

  test('the head of each axis is the default, and it is one pass', () {
    var assignments = scenarioAssignments(phones);

    expect(assignments, hasLength(1));
    expect(assignments.single.device, Devices.iphone16);
    expect(assignments.single.language, 'en');
  });

  test('no profile means no assignment at all — the bare test surface', () {
    var assignments = scenarioAssignments(null);

    expect(assignments, hasLength(1));
    expect(assignments.single.isEmpty, isTrue);
  });

  test('a profile with no languages leaves the platform locale alone', () {
    var assignments = scenarioAssignments(
      const ScenarioProfile('one', devices: [Devices.iphoneSe]),
    );

    expect(assignments.single.device, Devices.iphoneSe);
    expect(assignments.single.language, isNull);
  });

  test("CI's lists win over the profile, and cross", () {
    var assignments = scenarioAssignments(
      phones,
      devicesOverride: 'iphone-se,android-tall',
      languagesOverride: 'en,fr,de',
    );

    expect(assignments, hasLength(6));
    expect(assignments.map((a) => a.slug), [
      'iphone-se-en',
      'iphone-se-fr',
      'iphone-se-de',
      'android-tall-en',
      'android-tall-fr',
      'android-tall-de',
    ]);
  });

  test('one axis overridden leaves the other on its default', () {
    var assignments = scenarioAssignments(phones, languagesOverride: 'ja');

    expect(assignments.single.device, Devices.iphone16);
    expect(assignments.single.language, 'ja');
  });

  test('fit is a device: the bare surface, named', () {
    var assignments = scenarioAssignments(phones, devicesOverride: 'fit');

    expect(assignments.single.device, isNull);
    expect(assignments.single.language, 'en');
  });

  test('a device this build does not know is refused, not approximated', () {
    expect(
      () => scenarioAssignments(phones, devicesOverride: 'iphone-99'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '$e',
          'message',
          allOf(contains('no such device'), contains('iphone-se')),
        ),
      ),
    );
  });

  test('an assignment names itself for a path and for a test name', () {
    var assignment = ScenarioAssignment(
      device: Devices.iphone16,
      language: 'fr',
    );

    expect(assignment.slug, 'iphone-16-fr');
    expect(assignment.label, 'iPhone 16 · fr');
  });

  test('orientation crosses the other two axes', () {
    var assignments = scenarioAssignments(
      phones,
      devicesOverride: 'ipad,iphone-se',
      languagesOverride: 'en,fr',
      orientationsOverride: 'portrait,landscape',
    );

    expect(assignments, hasLength(8));
    expect(assignments.map((a) => a.slug), [
      'ipad-en',
      'ipad-fr',
      'ipad-landscape-en',
      'ipad-landscape-fr',
      'iphone-se-en',
      'iphone-se-fr',
      'iphone-se-landscape-en',
      'iphone-se-landscape-fr',
    ]);
  });

  test('portrait writes nothing, so existing artifact paths do not move', () {
    var portrait = ScenarioAssignment(
      device: Devices.iphone16,
      orientation: ScreenOrientation.portrait,
      language: 'fr',
    );

    expect(portrait.slug, 'iphone-16-fr');
    expect(portrait.label, 'iPhone 16 · fr');

    var landscape = ScenarioAssignment(
      device: Devices.iPad,
      orientation: ScreenOrientation.landscape,
      language: 'fr',
    );

    expect(landscape.slug, 'ipad-landscape-fr');
    expect(landscape.label, 'iPad · landscape · fr');
  });

  test('a device that cannot turn contributes one point, not two', () {
    var assignments = scenarioAssignments(
      phones,
      devicesOverride: 'ipad,window-wide',
      orientationsOverride: 'portrait,landscape',
    );

    // Three, not four: the window would have produced the same pixels twice.
    expect(assignments.map((a) => a.slug), [
      'ipad-en',
      'ipad-landscape-en',
      'window-wide-en',
    ]);
  });

  test('the bare surface collapses for the same reason', () {
    var assignments = scenarioAssignments(
      phones,
      devicesOverride: 'fit',
      orientationsOverride: 'portrait,landscape',
    );

    expect(assignments, hasLength(1));
    expect(assignments.single.device, isNull);
  });

  test('an orientation this build does not know is refused', () {
    expect(
      () => scenarioAssignments(phones, orientationsOverride: 'sideways'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '$e',
          'message',
          allOf(contains('no such orientation'), contains('landscape')),
        ),
      ),
    );
  });

  group("the app's own axes", () {
    const brands = ScenarioProfile(
      'brands',
      devices: [Devices.iphone16],
      languages: ['en'],
      axes: {
        'brand': ['coffee', 'tea'],
        'contrast': ['normal', 'high'],
      },
    );

    test('each runs at its head, and is said in every name', () {
      var assignment = scenarioAssignments(brands).single;

      expect(assignment.axes, {'brand': 'coffee', 'contrast': 'normal'});
      // The head is written, not left out as portrait is: it is the order
      // somebody listed the values in, and reordering them must not quietly
      // rename which directory is which.
      expect(assignment.slug, 'iphone-16-en-coffee-normal');
      expect(assignment.label, 'iPhone 16 · en · coffee · normal');
    });

    test("CI's values cross like any other list, innermost", () {
      var assignments = scenarioAssignments(
        brands,
        languagesOverride: 'en,fr',
        axesOverride: 'brand=coffee,tea',
      );

      expect(assignments.map((a) => a.slug), [
        'iphone-16-en-coffee-normal',
        'iphone-16-en-tea-normal',
        'iphone-16-fr-coffee-normal',
        'iphone-16-fr-tea-normal',
      ]);
    });

    test('a value the profile does not declare is refused, naming them', () {
      expect(
        () => scenarioAssignments(brands, axesOverride: 'brand=juice'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            allOf(contains('brand=juice'), contains('coffee, tea')),
          ),
        ),
      );
    });

    // `FW_AXES` is one environment for every folder `flutter test` walks, and
    // the folder next door may be the one that declares it.
    test('an axis the profile does not declare is left alone', () {
      var assignment = scenarioAssignments(
        phones,
        axesOverride: 'brand=tea',
      ).single;

      expect(assignment.axes, isEmpty);
      expect(assignment.slug, 'iphone-16-en');
    });

    test('a declaration no directory could carry is refused', () {
      expect(
        () => scenarioAssignments(
          const ScenarioProfile('broken', axes: {'brand': []}),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('no values'),
          ),
        ),
      );
    });

    test('a slug orders them by name, however they were declared', () {
      var assignment = ScenarioAssignment(
        language: 'fr',
        axes: {'contrast': 'high', 'brand': 'tea'},
      );

      expect(assignment.slug, 'fr-tea-high');
      expect(assignment.isEmpty, isFalse);
    });
  });

  test('a landscape assignment hands down a device already turned', () {
    var assignment = ScenarioAssignment(
      device: Devices.iPad,
      orientation: ScreenOrientation.landscape,
    );

    expect(assignment.orientedDevice!.width, Devices.iPad.height);
    expect(assignment.orientedDevice!.height, Devices.iPad.width);
  });
}
