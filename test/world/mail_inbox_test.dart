import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutterware/src/world/mail_inbox.dart';
import 'package:test/test.dart';

void main() {
  late MailInbox inbox;
  late List<InboxMail> mails;

  setUp(() async {
    mails = [];
    inbox = await MailInbox.start(onMail: mails.add);
  });
  tearDown(() => inbox.close());

  /// Sends [message] to [inbox] on a connection of its own and returns the
  /// mail the inbox reported.
  Future<InboxMail> deliver(
    String message, {
    String from = 'noreply@example.test',
    List<String> to = const ['ada@example.test'],
    Encoding encoding = utf8,
  }) async {
    var client = await _Client.connect(inbox.port);
    expect(await client.send('EHLO app.example.test'), startsWith('250'));
    var before = mails.length;
    expect(
      await client.mail(message, from: from, to: to, encoding: encoding),
      startsWith('250'),
    );
    expect(await client.send('QUIT'), startsWith('221'));
    await client.close();
    expect(mails, hasLength(before + 1));
    return mails.last;
  }

  group('SMTP', () {
    test(
      'greets, and advertises 8BITMIME, SMTPUTF8 and AUTH but not STARTTLS',
      () async {
        var client = await _Client.connect(inbox.port);
        expect(client.greeting, matches(RegExp(r'^220 \S+ ESMTP')));
        var ehlo = await client.send('EHLO app.example.test');
        var lines = ehlo.split('\n');
        expect(lines.first, startsWith('250-'));
        expect(lines.last, startsWith('250 '));
        expect(
          lines.map((line) => line.substring(4)),
          containsAll(['8BITMIME', 'SMTPUTF8', 'AUTH PLAIN LOGIN']),
        );
        expect(ehlo, isNot(contains('STARTTLS')));
        expect(await client.send('HELO app.example.test'), startsWith('250 '));
        await client.close();
      },
    );

    test('answers the other commands, whatever their case', () async {
      var client = await _Client.connect(inbox.port);
      expect(await client.send('ehlo app.example.test'), startsWith('250'));
      expect(await client.send('noop'), startsWith('250'));
      expect(await client.send('Vrfy ada'), startsWith('252'));
      expect(await client.send('DATA'), startsWith('503'));
      expect(
        await client.send('RCPT TO:<ada@example.test>'),
        startsWith('503'),
      );
      expect(await client.send('MAIL FROM ada'), startsWith('501'));
      expect(await client.send('STARTTLS'), startsWith('502'));
      expect(await client.send('SHOUT hello'), startsWith('502'));

      expect(
        await client.send('mail from:<> SIZE=120 BODY=8BITMIME'),
        startsWith('250'),
      );
      expect(await client.send('DATA'), startsWith('503'));
      expect(
        await client.send('rcpt to:<ada@example.test> NOTIFY=NEVER'),
        startsWith('250'),
      );
      expect(await client.send('rset'), startsWith('250'));
      expect(await client.send('data'), startsWith('503'));

      expect(await client.send('quit'), startsWith('221'));
      expect(await client.closed, isTrue);
      await client.close();
    });

    test('reports a plain mail with its envelope and headers', () async {
      var mail = await deliver(
        '''
From: Example Support <support@example.test>
To: "Lovelace, Ada" <ada@example.test>
Subject: Your sign-in code
Date: Sun, 27 Sep 2026 10:00:00 +0000
Message-ID: <code-1@example.test>

Your code is 482913.
It expires in ten minutes.''',
        from: 'bounces@example.test',
        to: ['ada@example.test', 'audit@example.test'],
      );
      expect(mail.sender, 'bounces@example.test');
      expect(mail.recipients, ['ada@example.test', 'audit@example.test']);
      expect(mail.from, 'support@example.test');
      expect(mail.to, ['ada@example.test']);
      expect(mail.subject, 'Your sign-in code');
      expect(mail.text, 'Your code is 482913.\nIt expires in ten minutes.\n');
      expect(mail.html, isNull);
      expect(
        mail.received.difference(DateTime.now()).abs(),
        lessThan(Duration(minutes: 1)),
      );
    });

    test('reports the null sender of a bounce as null', () async {
      var mail = await deliver(
        'Subject: Undeliverable\n\nIt bounced.',
        from: '',
      );
      expect(mail.sender, isNull);
      expect(mail.recipients, ['ada@example.test']);
    });

    test('undoes dot-stuffing', () async {
      var mail = await deliver(_dots);
      expect(mail.text, '.leading dot\n..two leading dots\n.\nlast line\n');
    });

    test('takes several mails on one connection', () async {
      var client = await _Client.connect(inbox.port);
      await client.send('EHLO app.example.test');
      expect(await client.mail('Subject: One\n\nfirst'), startsWith('250'));
      expect(
        await client.mail('Subject: Two\n\nsecond', to: ['bob@example.test']),
        startsWith('250'),
      );
      await client.send('QUIT');
      await client.close();
      expect(mails.map((mail) => mail.subject), ['One', 'Two']);
      expect(mails.map((mail) => mail.text), ['first\n', 'second\n']);
      expect(mails.last.recipients, ['bob@example.test']);
    });

    test('accepts any AUTH PLAIN and AUTH LOGIN', () async {
      String encoded(String text) => base64.encode(utf8.encode(text));

      var client = await _Client.connect(inbox.port);
      await client.send('EHLO app.example.test');
      var plain = encoded('\u0000ada@example.test\u0000not-checked');
      expect(await client.send('AUTH PLAIN $plain'), startsWith('235'));
      expect(await client.send('AUTH PLAIN'), '334 ');
      expect(await client.send(plain), startsWith('235'));
      expect(await client.send('auth login'), '334 VXNlcm5hbWU6');
      expect(
        await client.send(encoded('ada@example.test')),
        '334 UGFzc3dvcmQ6',
      );
      expect(await client.send(encoded('not-checked')), startsWith('235'));
      expect(
        await client.send('AUTH LOGIN ${encoded('ada@example.test')}'),
        '334 UGFzc3dvcmQ6',
      );
      expect(await client.send(encoded('not-checked')), startsWith('235'));
      expect(await client.send('AUTH LOGIN'), startsWith('334'));
      expect(await client.send('*'), startsWith('501'));
      expect(await client.send('AUTH CRAM-MD5'), startsWith('504'));

      expect(await client.mail('Subject: Signed in\n\nhi'), startsWith('250'));
      await client.close();
      expect(mails.single.subject, 'Signed in');
    });

    test('understands bare LF line endings', () async {
      var client = await _Client.connect(inbox.port, eol: '\n');
      expect(await client.send('EHLO app.example.test'), startsWith('250'));
      expect(await client.send('AUTH LOGIN'), startsWith('334'));
      expect(await client.send('dXNlcg=='), startsWith('334'));
      expect(await client.send('cGFzcw=='), startsWith('235'));
      expect(
        await client.mail(
          'Subject: Bare\nContent-Type: text/plain\n\none\n.dot\ntwo',
        ),
        startsWith('250'),
      );
      await client.send('QUIT');
      await client.close();
      expect(mails.single.subject, 'Bare');
      expect(mails.single.text, 'one\n.dot\ntwo\n');
    });

    test('keeps serving when the handler throws', () async {
      var calls = 0;
      var throwing = await MailInbox.start(
        onMail: (_) {
          calls++;
          throw StateError('the handler failed');
        },
      );
      addTearDown(throwing.close);
      var client = await _Client.connect(throwing.port);
      await client.send('EHLO app.example.test');
      expect(await client.mail('Subject: One\n\nfirst'), startsWith('250'));
      expect(await client.mail('Subject: Two\n\nsecond'), startsWith('250'));
      expect(await client.send('QUIT'), startsWith('221'));
      await client.close();
      expect(calls, 2);

      var another = await _Client.connect(throwing.port);
      expect(another.greeting, startsWith('220'));
      await another.close();
    });

    test('keeps serving when a client hangs up mid-mail', () async {
      var client = await _Client.connect(inbox.port);
      await client.send('EHLO app.example.test');
      await client.send('MAIL FROM:<noreply@example.test>');
      await client.send('RCPT TO:<ada@example.test>');
      expect(await client.send('DATA'), startsWith('354'));
      client.write('Subject: Half\r\n\r\nhalf a bo');
      await client.close();

      await deliver('Subject: Whole\n\nwhole');
      expect(mails.map((mail) => mail.subject), ['Whole']);
    });

    test('stops accepting connections once closed', () async {
      var port = inbox.port;
      var open = await _Client.connect(port);
      await inbox.close();
      expect(await open.closed, isTrue);
      await open.close();
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('decoding', () {
    test('multipart/alternative: a quoted-printable HTML part and a base64 text part', () async {
      var mail = await deliver(_alternative);
      expect(mail.from, 'noreply@example.test');
      expect(mail.subject, 'Verify your address');
      expect(mail.text, _alternativeText);
      expect(
        mail.html,
        '<p>Hé Ada, '
        '<a href="https://app.example.test/verify?token=abc123">verify</a> '
        'to finish signing up.</p>',
      );
    });

    test('UTF-8 subjects in B and Q encoded words', () async {
      var b = base64.encode(utf8.encode('Votre code : '));
      var mail = await deliver(
        'Subject: =?UTF-8?B?$b?=\n =?utf-8?q?=C3=A9t=C3=A9_2026?=\n\nbody',
      );
      expect(mail.subject, 'Votre code : été 2026');

      String? subject(String header) =>
          InboxMail.parse(utf8.encode('Subject: $header\n\nbody')).subject;
      var ete = base64.encode(utf8.encode('été'));
      expect(subject('Re: =?utf-8?b?$ete?= plans'), 'Re: été plans');
      expect(subject('=?utf-8?Q?caf=C3?= =?utf-8?Q?=A9?= open'), 'café open');
      expect(subject('=?ISO-8859-1?Q?cr=E8me?='), 'crème');
      expect(subject('=?us-ascii?Q?plain_text?='), 'plain text');
      expect(subject('=?x-unknown?Q?caf=C3=A9?='), 'café');
      expect(subject('=?utf-8?Q?a?=  =?latin1?Q?=E9?='), 'aé');
      expect(subject('no encoded words'), 'no encoded words');
    });

    test('skips attachments, however deep the body sits', () async {
      var mail = await deliver(_withAttachments);
      expect(mail.text, 'Your invoice is attached.');
      expect(mail.html, '<p>Your invoice is attached.</p>');
    });

    test('reads 8-bit bodies in their charset', () async {
      var latin = await deliver('''
Subject: =?iso-8859-1?q?Cr=E8me?=
Content-Type: text/plain; charset=ISO-8859-1
Content-Transfer-Encoding: 8bit

Café crème, déjà.''', encoding: latin1);
      expect(latin.subject, 'Crème');
      expect(latin.text, 'Café crème, déjà.\n');

      var utf = await deliver('''
Subject: Été à la plage
Content-Type: text/html; charset="utf-8"
Content-Transfer-Encoding: 8bit

<p>Ça marche ✓</p>''');
      expect(utf.subject, 'Été à la plage');
      expect(utf.html, '<p>Ça marche ✓</p>\n');
      expect(utf.text, isNull);
    });

    test('bare addresses from address lists', () {
      var mail = InboxMail.parse(
        utf8.encode('''
From: =?utf-8?Q?Caf=C3=A9_Team?= <team@example.test>
To: "Lovelace, Ada" <ada@example.test>, bob@example.test,
 (the reviewer) Carol <carol@example.test>,
 Team: dan@example.test, "Eve" <eve@example.test>;, undisclosed-recipients:;

body'''),
        received: DateTime.utc(2026, 9, 27),
      );
      expect(mail.from, 'team@example.test');
      expect(mail.to, [
        'ada@example.test',
        'bob@example.test',
        'carol@example.test',
        'dan@example.test',
        'eve@example.test',
      ]);
      expect(mail.received, DateTime.utc(2026, 9, 27));
    });

    test('header names are case-insensitive and folded values unfold', () {
      var mail = InboxMail.parse(
        utf8.encode(
          'SUBJECT: A subject that\r\n goes on\r\n'
          'content-type: TEXT/HTML;\r\n\tCHARSET="UTF-8"\r\n'
          'CONTENT-TRANSFER-ENCODING: Quoted-Printable\r\n'
          '\r\n'
          '<b>=E2=9C=93</b>=\r\n',
        ),
      );
      expect(mail.subject, 'A subject that goes on');
      expect(mail.html, '<b>✓</b>');
      expect(mail.text, isNull);
    });
  });

  group('relay', () {
    test('hands each mail on, unchanged and in order', () async {
      var caught = StreamController<InboxMail>();
      var catcher = await MailInbox.start(onMail: caught.add);
      var errors = <Object>[];
      var front = await MailInbox.start(
        onMail: mails.add,
        relay: (host: InternetAddress.loopbackIPv4.address, port: catcher.port),
        onRelayError: errors.add,
      );
      addTearDown(() async {
        await front.close();
        await catcher.close();
        await caught.close();
      });

      var client = await _Client.connect(front.port);
      await client.send('EHLO app.example.test');
      expect(
        await client.mail(
          _alternative,
          from: 'bounces@example.test',
          to: ['ada@example.test', 'audit@example.test'],
        ),
        startsWith('250'),
      );
      expect(await client.mail(_dots), startsWith('250'));
      await client.send('QUIT');
      await client.close();

      expect(mails, hasLength(2));
      expect(mails.first.html, isNotNull);
      var relayed = StreamIterator(caught.stream);
      for (var original in mails) {
        expect(await relayed.moveNext().timeout(Duration(seconds: 5)), isTrue);
        var copy = relayed.current;
        expect(copy.sender, original.sender);
        expect(copy.recipients, original.recipients);
        expect(copy.from, original.from);
        expect(copy.to, original.to);
        expect(copy.subject, original.subject);
        expect(copy.text, original.text);
        expect(copy.html, original.html);
      }
      await relayed.cancel();
      expect(errors, isEmpty);
    });

    test(
      'reports a relay that is not listening, and keeps receiving',
      () async {
        var gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        var port = gone.port;
        await gone.close();
        var errors = StreamController<Object>();
        var front = await MailInbox.start(
          onMail: mails.add,
          relay: (host: InternetAddress.loopbackIPv4.address, port: port),
          onRelayError: errors.add,
        );
        addTearDown(() async {
          await front.close();
          await errors.close();
        });
        var reported = StreamIterator(errors.stream);

        var client = await _Client.connect(front.port);
        await client.send('EHLO app.example.test');
        expect(await client.mail('Subject: One\n\nfirst'), startsWith('250'));
        expect(await reported.moveNext().timeout(Duration(seconds: 5)), isTrue);
        expect(
          reported.current,
          isA<MailRelayException>().having(
            (error) => error.cause,
            'cause',
            isA<SocketException>(),
          ),
        );

        expect(await client.mail('Subject: Two\n\nsecond'), startsWith('250'));
        expect(await reported.moveNext().timeout(Duration(seconds: 5)), isTrue);
        await client.close();
        await reported.cancel();
        expect(mails.map((mail) => mail.subject), ['One', 'Two']);
      },
    );

    test('close waits for a relay that never answers, but not long', () async {
      var silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var held = <Socket>[];
      var accepting = silent.listen(held.add);
      addTearDown(() async {
        for (var socket in held) {
          socket.destroy();
        }
        await accepting.cancel();
        await silent.close();
      });
      var errors = <Object>[];
      var front = await MailInbox.start(
        onMail: mails.add,
        relay: (host: InternetAddress.loopbackIPv4.address, port: silent.port),
        onRelayError: errors.add,
      );

      var client = await _Client.connect(front.port);
      await client.send('EHLO app.example.test');
      expect(await client.mail('Subject: Stuck\n\nstuck'), startsWith('250'));
      await client.close();

      var watch = Stopwatch()..start();
      await front.close();
      expect(watch.elapsed, lessThan(Duration(seconds: 6)));
      expect(held, hasLength(1));
      expect(errors, isEmpty);
    });
  });
}

/// Just enough of an SMTP client to talk to a [MailInbox] the way a service
/// sending its own mail would.
final class _Client {
  _Client._(this._socket, this._eol)
    : _lines = StreamIterator(
        utf8.decoder.bind(_socket).transform(const LineSplitter()),
      );

  static Future<_Client> connect(int port, {String eol = '\r\n'}) async {
    var client = _Client._(
      await Socket.connect(InternetAddress.loopbackIPv4, port),
      eol,
    );
    client.greeting = await client.reply();
    return client;
  }

  final Socket _socket;
  final String _eol;
  final StreamIterator<String> _lines;
  late final String greeting;

  /// The next reply, the lines of a multi-line one joined by `\n`.
  Future<String> reply() async {
    var lines = <String>[];
    while (await _lines.moveNext()) {
      var line = _lines.current;
      lines.add(line);
      if (line.length < 4 || line[3] != '-') return lines.join('\n');
    }
    throw StateError('The server hung up after "${lines.join(' / ')}"');
  }

  Future<String> send(String command) {
    _socket.write('$command$_eol');
    return reply();
  }

  void write(String text) => _socket.write(text);

  /// Sends [message], whose lines are separated by `\n`, as a mail from
  /// [from] to [to], and returns the reply to its end.
  Future<String> mail(
    String message, {
    String from = 'noreply@example.test',
    List<String> to = const ['ada@example.test'],
    Encoding encoding = utf8,
  }) async {
    expect(await send('MAIL FROM:<$from>'), startsWith('250'));
    for (var recipient in to) {
      expect(await send('RCPT TO:<$recipient>'), startsWith('250'));
    }
    expect(await send('DATA'), startsWith('354'));
    for (var line in message.split('\n')) {
      _socket
        ..add(encoding.encode(line.startsWith('.') ? '.$line' : line))
        ..write(_eol);
    }
    return send('.');
  }

  /// Whether the server has hung up.
  Future<bool> get closed async {
    try {
      return !await _lines.moveNext();
    } on SocketException {
      return true;
    }
  }

  Future<void> close() async {
    await _lines.cancel();
    _socket.destroy();
  }
}

const _dots = '''
Subject: Dots

.leading dot
..two leading dots
.
last line''';

const _alternativeText =
    'Hé Ada, open https://app.example.test/verify?token=abc123 to '
    'finish signing up. This sentence is long enough for its base64 to wrap '
    'across more than one line.';

final _alternative =
    '''
From: "Example App" <noreply@example.test>
To: ada@example.test
Subject: Verify your address
MIME-Version: 1.0
Content-Type: multipart/alternative;
 boundary="=_part_1"

This is a multi-part message in MIME format.
--=_part_1
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: base64

${_wrapped(base64.encode(utf8.encode(_alternativeText)))}
--=_part_1
Content-Type: text/html; charset="utf-8"
Content-Transfer-Encoding: quoted-printable

<p>H=C3=A9 Ada, <a href=3D"https://app.example.test/verify?token=3Dabc123">=
verify</a> =
to finish signing up.</p>
--=_part_1--
''';

const _withAttachments = '''
From: noreply@example.test
To: ada@example.test
Subject: Your invoice
Content-Type: multipart/mixed; boundary=outer

--outer
Content-Type: text/plain; name="terms.txt"
Content-Disposition: attachment; filename="terms.txt"

These are the terms.
--outer
Content-Type: multipart/related; boundary="related"

--related
Content-Type: multipart/alternative; boundary="alt"

--alt
Content-Type: text/plain; charset=us-ascii

Your invoice is attached.
--alt
Content-Type: text/html

<p>Your invoice is attached.</p>
--alt--
--related
Content-Type: image/png
Content-Transfer-Encoding: base64
Content-ID: <logo>

iVBORw0KGgo=
--related--
--outer
Content-Type: text/html; charset=utf-8
Content-Disposition: ATTACHMENT; filename="invoice.html"

<p>The invoice itself</p>
--outer--''';

String _wrapped(String text) => [
  for (var i = 0; i < text.length; i += 76)
    text.substring(i, min(i + 76, text.length)),
].join('\n');
