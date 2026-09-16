import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/scenarios/time_mode.dart';

void main() {
  test('parses the two names and refuses anything else', () {
    expect(parseScenarioTime('fake'), ScenarioTime.fake);
    expect(parseScenarioTime('real'), isA<ScenarioTimeReal>());
    expect(
      () => parseScenarioTime('wall'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('One of: fake, real'),
        ),
      ),
    );
  });

  test('real scales animations to a tenth unless told otherwise', () {
    expect(ScenarioTime.real().animations, 0.1);
    expect(ScenarioTime.real(animations: 1).animations, 1);
    expect(ScenarioTime.fake.animations, 1);
    expect(ScenarioTime.real().isReal, isTrue);
    expect(ScenarioTime.fake.isReal, isFalse);
  });

  test('the name is what the wire and the report say', () {
    expect(ScenarioTime.fake.name, 'fake');
    expect(ScenarioTime.real().name, 'real');
  });
}
