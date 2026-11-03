import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/world.dart';
import 'package:flutterware_app/src/run/channel_client.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/run/run_sources.dart';
import 'package:flutterware_app/src/ui/tappable.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/world/autofill_bar.dart';
import 'package:flutterware_app/src/world/open_world.dart';
import 'package:flutterware_app/src/world/world_autofill.dart';
import 'package:flutterware_app/src/world/world_files.dart';
import 'package:flutterware_app/src/world/world_trace.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const manager = Person(
    'Manager',
    email: 'manager@example.com',
    password: 'ward-7',
    phone: '+447700900001',
  );
  const nurse = Person(
    'Nurse',
    email: 'nurse@example.com',
    password: 'night-shift',
  );
  const visitor = Person('Visitor', phone: '+447700900002');
  const people = [nurse, manager, visitor];

  group('what a focused field is offered', () {
    List<(String?, String, String)> offers(
      WorldField field, {
      String person = 'Manager',
      List<OutboxMessage> received = const [],
    }) => [
      for (var offer in offersFor(person, field, people, received: received))
        (offer.person, offer.label, offer.value),
    ];

    test("an address: everyone's, the one typing first", () {
      expect(offers(const WorldField(FieldKind.email)), [
        ('Manager', "Manager's address", 'manager@example.com'),
        ('Nurse', "Nurse's address", 'nurse@example.com'),
      ]);
    });

    test('a password: their own, and nobody else’s', () {
      expect(offers(const WorldField(FieldKind.password)), [
        ('Manager', "Manager's password", 'ward-7'),
      ]);
      expect(
        offers(const WorldField(FieldKind.password), person: 'Visitor'),
        isEmpty,
      );
    });

    test('a name: theirs. A phone number: everyone’s', () {
      expect(offers(const WorldField(FieldKind.name)), [
        ('Manager', "Manager's name", 'Manager'),
      ]);
      expect(offers(const WorldField(FieldKind.phone)), [
        ('Manager', "Manager's phone number", '+447700900001'),
        ('Visitor', "Visitor's phone number", '+447700900002'),
      ]);
    });

    test('a code: the newest one they received', () {
      OutboxMessage sms(String id, String? code) => OutboxMessage(
        id: id,
        at: DateTime(2026, 11, 3),
        kind: 'sms',
        to: '+447700900001',
        text: 'Your code is $code',
        person: 'Manager',
        code: code,
      );
      var field = const WorldField(FieldKind.code);
      expect(
        offersFor(
          'Manager',
          field,
          people,
          received: [
            sms('lab/9', null),
            sms('lab/8', '4821'),
            sms('lab/2', '1111'),
          ],
        ).map((o) => (o.label, o.value, o.message)),
        [('the code from the SMS', '4821', 'lab/8')],
      );
      expect(offers(field), isEmpty);
    });

    test('anything else: nothing', () {
      expect(offers(const WorldField(FieldKind.other)), isEmpty);
    });

    test('in a sign-in form, an address with its password, and a password '
        'with its address', () {
      var email = offersFor(
        'Manager',
        const WorldField(FieldKind.email, group: [FieldKind.password]),
        people,
      );
      expect(email.map((o) => (o.label, o.value)), [
        ("Manager's address and password", 'manager@example.com'),
        ("Nurse's address and password", 'nurse@example.com'),
      ]);
      expect(email.map((o) => o.group), [
        {FieldKind.password: 'ward-7'},
        {FieldKind.password: 'night-shift'},
      ]);
      var password = offersFor(
        'Nurse',
        const WorldField(FieldKind.password, group: [FieldKind.email]),
        people,
      ).single;
      expect(password.value, 'night-shift');
      expect(password.group, {FieldKind.email: 'nurse@example.com'});
      expect(password.secret, isTrue);
    });
  });

  group('`worlds fill` reads', () {
    test('a person and what the world knows of them', () {
      var offer = offerNamed('Nurse.email', people, null)!;
      expect(
        (offer.label, offer.value),
        ("Nurse's address", 'nurse@example.com'),
      );
      expect(offer.group, isEmpty);
      expect(offerNamed('Manager.phone', people, null)!.value, '+447700900001');
      expect(offerNamed('Nurse.name', people, null)!.value, 'Nurse');
    });

    test('an address into a sign-in form with its password', () {
      var offer = offerNamed(
        'Nurse.email',
        people,
        const WorldField(FieldKind.email, group: [FieldKind.password]),
      )!;
      expect(offer.label, "Nurse's address and password");
      expect(offer.group, {FieldKind.password: 'night-shift'});
    });

    test('anything else as text to type', () {
      expect(offerNamed('hello', people, null), isNull);
      expect(offerNamed('nurse@example.com', people, null), isNull);
      expect(offerNamed('ward 7.b', people, null), isNull);
    });

    test('refuses a person who is not there, and a value they lack', () {
      expect(
        () => offerNamed('Nurze.email', people, null),
        throwsA(
          isA<WorldRefusal>().having(
            (r) => r.message,
            'message',
            'Nobody in this world is called Nurze: Nurse, Manager, Visitor.',
          ),
        ),
      );
      expect(
        () => offerNamed('Visitor.password', people, null),
        throwsA(
          isA<WorldRefusal>().having(
            (r) => r.message,
            'message',
            startsWith('Visitor has no password in this world.'),
          ),
        ),
      );
    });
  });

  group('the bar under a device', () {
    late _Apps apps;
    late OpenWorld world;

    setUp(() {
      apps = _Apps();
      world = OpenWorld(
        file: const WorldFile(
          package: 'server',
          path: 'tool/worlds/clinic.dart',
          name: 'Clinic',
        ),
        worktree: '/nowhere',
        flutterSdkRoot: '/nowhere/flutter',
        appRoot: '/nowhere/app',
        entrypoints: const [],
        guests: (_) => throw StateError('no app runs here'),
      );
      for (var person in people) {
        world.people[person.name] = WorldPerson(person)
          ..phase = PersonPhase.running;
      }
    });

    Future<_App> follow(WidgetTester tester, String person) async {
      var tracer = world.tracer ??= WorldTracer(
        worktree: '/nowhere',
        channels: apps,
      )..onField = () => world.onChanged?.call();
      addTearDown(tracer.close);
      var app = apps.of(person);
      await tracer.follow(
        person,
        RunHandle(
          worktree: '/nowhere',
          worktreeName: 'nowhere',
          device: person,
          entrypoint: 'lib/main.dart',
          launcherPid: 1,
          startedAt: DateTime(2026, 11, 3),
        ),
      );
      return app;
    }

    Future<void> pumpBar(WidgetTester tester, String person) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) {
                  // As the studio redraws when the world says it changed.
                  world.onChanged = () => setState(() {});
                  return AutofillBar(
                    world: world,
                    person: person,
                    colorOf: (_) => const Color(0xFF3366CC),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows nothing until a field has focus, then what fits it', (
      tester,
    ) async {
      var app = await follow(tester, 'Manager');
      await pumpBar(tester, 'Manager');
      expect(find.byType(Tappable), findsNothing);

      app.say(worldFocusChannel, {'kind': 'email', 'group': <String>[]});
      await tester.pump();
      expect(find.text('Manager'), findsOneWidget);
      expect(find.text('Nurse'), findsOneWidget);
      expect(find.text('Visitor'), findsNothing);

      app.say(worldFocusChannel, {'kind': 'other', 'group': <String>[]});
      await tester.pump();
      expect(find.text('Nurse'), findsNothing);

      app.say(worldFocusChannel, {});
      await tester.pump();
      expect(find.byType(Tappable), findsNothing);
    });

    testWidgets('a pick fills the field as a step named for it', (
      tester,
    ) async {
      var app = await follow(tester, 'Manager');
      await pumpBar(tester, 'Manager');
      app.say(worldFocusChannel, {'kind': 'email', 'group': <String>[]});
      await tester.pump();

      await tester.tap(find.text('Nurse'));
      await tester.pump();
      var (method, params) = app.asked.single;
      expect(method, 'fill');
      expect(params, {
        'text': 'nurse@example.com',
        'target': "Nurse's address",
        'group': <String, Object?>{},
      });
      // The guest names the step as it fills; the trace has it as the
      // others, with what its callbacks send to join it.
      app.say(worldStepsChannel, {
        'step': 'manager.4',
        'verb': 'fill',
        'target': "Nurse's address",
      });
      var step = world.tracer!.trace.step('manager.4')!;
      expect(step.person, 'Manager');
      expect(step.did, "fill Nurse's address");
    });

    testWidgets('one pick in a sign-in form fills the address and the '
        'password', (tester) async {
      var app = await follow(tester, 'Nurse');
      await pumpBar(tester, 'Nurse');
      app.say(worldFocusChannel, {
        'kind': 'password',
        'group': ['email'],
      });
      await tester.pump();
      // A password is never on the screen, only whose it is.
      expect(find.textContaining('night-shift'), findsNothing);

      await tester.tap(find.text('Nurse'));
      await tester.pump();
      expect(app.asked.single.$2, {
        'text': 'night-shift',
        'target': "Nurse's address and password",
        'group': {'email': 'nurse@example.com'},
      });
    });

    testWidgets('says so when the field let go before the pick reached it', (
      tester,
    ) async {
      var app = await follow(tester, 'Manager')
        ..answer = (_, _) => {'filled': 0};
      await pumpBar(tester, 'Manager');
      app.say(worldFocusChannel, {'kind': 'email', 'group': <String>[]});
      await tester.pump();

      await tester.tap(find.text('Nurse'));
      await tester.pump();
      expect(
        find.text(
          "No field has focus in Manager's app. Tap one first, then try again.",
        ),
        findsOneWidget,
      );
    });
  });

  test('`worlds fill` answers with the step it was', () async {
    var apps = _Apps();
    var world = OpenWorld(
      file: const WorldFile(package: 'server', path: 'c.dart', name: 'Clinic'),
      worktree: '/nowhere',
      flutterSdkRoot: '/nowhere/flutter',
      appRoot: '/nowhere/app',
      entrypoints: const [],
      guests: (_) => throw StateError('no app runs here'),
    );
    for (var person in people) {
      world.people[person.name] = WorldPerson(person)
        ..phase = PersonPhase.running;
    }
    var tracer = world.tracer = WorldTracer(
      worktree: '/nowhere',
      channels: apps,
    );
    addTearDown(tracer.close);
    var app = apps.of('Manager');
    await tracer.follow(
      'Manager',
      RunHandle(
        worktree: '/nowhere',
        worktreeName: 'nowhere',
        device: 'Manager',
        entrypoint: 'lib/main.dart',
        launcherPid: 1,
        startedAt: DateTime(2026, 11, 3),
      ),
    );

    var fill = await world.fill('Manager', 'Nurse.email');
    expect(fill.said, "manager.4 filled Nurse's address");
    expect(fill.fields, 1);

    // Literal text, typed as it is; a password field's is not repeated.
    await world.fill('Manager', 'Ward 7');
    expect(app.asked.last.$2['target'], '"Ward 7"');
    app.say(worldFocusChannel, {'kind': 'password', 'group': <String>[]});
    await world.fill('Manager', 'hunter2');
    expect(app.asked.last.$2['target'], 'a password');

    app.answer = (_, _) => {'filled': 0};
    await expectLater(
      world.fill('Manager', 'Nurse.email'),
      throwsA(
        isA<WorldRefusal>().having(
          (r) => r.message,
          'message',
          "No field has focus in Manager's app. Tap one first, then try again.",
        ),
      ),
    );
    await expectLater(
      world.fill('Matron', 'Nurse.email'),
      throwsA(isA<WorldRefusal>()),
    );
  });
}

/// The apps the world attaches to, by their device: stand-ins that say
/// what a guest would and answer what it is asked.
class _Apps extends RunChannels {
  final _apps = <String, _App>{};

  _App of(String person) => _apps[person] ??= _App();

  @override
  Future<RunAttachment> attach(
    RunHandle handle, {
    required String peer,
  }) async => of(handle.device);
}

class _App implements RunAttachment {
  final _events = StreamController<InspectorEvent>.broadcast(sync: true);
  var _id = 0;

  /// Every `world/input` call, by method.
  final asked = <(String, Map<String, Object?>)>[];

  /// What the guest answers: a fill reaches one field, as step `manager.4`.
  Map<String, Object?> Function(String method, Map<String, Object?> params)
  answer = (_, _) => {'filled': 1, 'step': 'manager.4'};

  void say(String channel, Map<String, Object?> payload) => _events.add(
    InspectorEvent(
      channel: channel,
      id: _id++,
      time: DateTime.now(),
      payload: payload,
      isReplay: false,
    ),
  );

  @override
  List<InspectorEvent> get received => const [];

  @override
  Stream<InspectorEvent> get events => _events.stream;

  @override
  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (channel != worldInputChannel) {
      throw StateError('no handler for $channel.$method');
    }
    asked.add((method, params));
    return answer(method, params);
  }

  @override
  Future<Map<String, Object?>?> details(int eventId) async => null;

  @override
  Future<void> close() => _events.close();
}
