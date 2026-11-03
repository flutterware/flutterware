import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart' show MailCatcherKind;
import 'package:flutterware_app/src/world/mail_catcher.dart';

import 'fake_mail_catcher.dart';

void main() {
  late FakeMailCatcher fake;
  late List<CaughtMail> caught;
  late List<String> said;

  setUp(() {
    caught = [];
    said = [];
  });

  Future<CatcherWatch> watch({DateTime? opened}) async {
    var watch = await CatcherWatch.start(
      WorldMailCatcher(
        name: 'mailcatcher',
        kind: MailCatcherKind.mailcatcher,
        api: fake.api,
        senders: {'No-Reply@Identity.test': 'identity'},
      ),
      opened: opened ?? DateTime.now(),
      onMail: caught.add,
      say: said.add,
    );
    addTearDown(watch.close);
    return watch;
  }

  Future<void> until(bool Function() done) async {
    var deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out. Caught: $caught. Said: $said');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  group('with its websocket', () {
    setUp(() async {
      fake = await FakeMailCatcher.start();
      addTearDown(fake.close);
    });

    test('hands on each new mail, and none it already held', () async {
      fake.catches(
        from: 'no-reply@identity.test',
        recipients: ['old@example.com'],
        subject: 'From another world',
      );
      await watch();
      await until(() => fake.listening == 1);
      fake.catches(
        from: 'The Lab <no-reply@identity.test>',
        recipients: ['ana@example.com', 'leo@example.com'],
        subject: 'Invitation',
        text: 'Join at https://example.com/join?code=42',
        messageId: '<Inv-1@Identity.Test>',
      );
      await until(() => caught.length == 2);

      expect(
        [for (var mail in caught) mail.to],
        ['ana@example.com', 'leo@example.com'],
      );
      var mail = caught.first.mail;
      expect(mail.subject, 'Invitation');
      expect(mail.text, 'Join at https://example.com/join?code=42');
      expect(mail.messageId, 'Inv-1@Identity.Test');
      // The envelope, without the parameters Mailcatcher keeps after it.
      expect(mail.sender, 'no-reply@identity.test');
      expect(caught.first.sender, 'identity');

      fake.catches(
        from: 'billing@example.com',
        recipients: ['ana@example.com'],
        subject: 'Your invoice',
      );
      await until(() => caught.length == 3);
      // A From address no sender names: the catcher's own.
      expect(caught.last.sender, 'mailcatcher');
      expect(said, ['Reading the mail mailcatcher catches, at ${fake.api}']);
    });

    test('a mail under an id used before a clear is new', () async {
      fake.catches(
        from: 'no-reply@identity.test',
        recipients: ['old@example.com'],
        subject: 'Before',
        at: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      await watch();
      await until(() => fake.listening == 1);
      fake
        ..clear()
        ..catches(
          from: 'no-reply@identity.test',
          recipients: ['ana@example.com'],
          subject: 'After',
        );
      await until(() => caught.length == 1);
      expect(caught.single.mail.subject, 'After');
    });

    test('reads the list once its websocket closes', () async {
      await watch();
      await until(() => fake.listening == 1);
      await fake.dropSockets();
      fake.catches(
        from: 'no-reply@identity.test',
        recipients: ['ana@example.com'],
        subject: 'While it was closed',
      );
      await until(() => caught.length == 1);
      expect(caught.single.mail.subject, 'While it was closed');
    });
  });

  test('reads the list every second when it has no websocket', () async {
    fake = await FakeMailCatcher.start(websocket: false);
    addTearDown(fake.close);
    fake.catches(
      from: 'no-reply@identity.test',
      recipients: ['old@example.com'],
      subject: 'Before',
    );
    await watch();
    fake.catches(
      from: 'no-reply@identity.test',
      recipients: ['ana@example.com'],
      subject: 'Polled',
    );
    await until(() => caught.isNotEmpty);
    expect([for (var mail in caught) mail.mail.subject], ['Polled']);
  });

  test('a catcher that answers late: what came after the world opened is '
      'new', () async {
    fake = await FakeMailCatcher.start()
      ..answering = false;
    addTearDown(fake.close);
    var opened = DateTime.now();
    fake
      ..catches(
        from: 'no-reply@identity.test',
        recipients: ['old@example.com'],
        subject: 'Before',
        at: opened.subtract(const Duration(minutes: 5)),
      )
      ..catches(
        from: 'no-reply@identity.test',
        recipients: ['ana@example.com'],
        subject: 'After',
        at: opened.add(const Duration(seconds: 1)),
      );
    await watch(opened: opened);
    expect(said.last, startsWith('mailcatcher is not answering at'));
    fake.answering = true;
    await until(() => caught.isNotEmpty);
    expect([for (var mail in caught) mail.mail.subject], ['After']);
    expect(said.last, 'mailcatcher answers again at ${fake.api}');
  });
}
