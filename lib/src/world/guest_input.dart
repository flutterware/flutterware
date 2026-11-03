import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../server/vm_transport.dart' show GuestChannels;
import '../ui_catalog/guest_text_input.dart';
import 'guest_steps.dart';
import 'step_names.dart';

/// Lets the world deliver to this app, each delivery a step of [steps] the
/// way a tap is, so what it causes joins it rather than the tap before.
/// Asked on [worldInputChannel]; call once [GuestTextInput.install] has run.
///
/// - `type`: a code arrives in the focused field the way the platform's own
///   input would — an SMS code's autofill — through [GuestTextInput], this
///   guest's text input. What the field's callbacks start runs in the step.
/// - `fill`: what the world knows — an address, a password — arrives the
///   same way, and so does the rest of a sign-in form: each other field of
///   the focused one's `AutofillGroup` whose [FieldKind] `group` has a value
///   for, as a password manager fills a username with its password.
/// - `open`: names the step a link is about to arrive under. The link comes
///   through the links plugin's own stream, which runs where the app
///   listened, so what it starts joins by time. Given a `link`, it arrives
///   here instead, the way Flutter's own deep linking delivers one — see
///   [pushRouteInformation] — and the answer says whether the app took it.
///
/// Each takes the `target` the trace names the step by: `the code from SMS`.
/// Without [steps] — a guest built before deliveries were steps — a code is
/// still typed, on no step.
///
/// Every time focus moves, the guest says on [worldFocusChannel] what kind of
/// field has it, so the studio can offer what fits.
void installWorldInput([WorldSteps? steps]) {
  var input = GuestTextInput.instance;
  String? said;
  void report() {
    var focused = focusedField(input);
    // A field that rebuilds hands its configuration over again, unchanged.
    if (jsonEncode(focused) == said) return;
    said = jsonEncode(focused);
    GuestChannels.core.addEvent(worldFocusChannel, focused);
  }

  input.field.addListener(report);
  GuestChannels.core
    ..registerHandler(worldInputChannel, 'type', (params) {
      // Nowhere for it to go is no step at all.
      if (!input.focused) return {'typed': false};
      var text = '${params['text'] ?? ''}';
      if (steps == null) return {'typed': input.fill(text)};
      String? step;
      var typed = steps.deliver('type', _target(params, 'a code'), (id) {
        step = id;
        return input.fill(text);
      });
      return {'typed': typed, 'step': ?step};
    })
    ..registerHandler(worldInputChannel, 'fill', (params) {
      if (!input.focused) return {'filled': 0};
      var text = '${params['text'] ?? ''}';
      var group = {
        for (var MapEntry(:key, :value)
            in (params['group'] as Map? ?? const {}).entries)
          FieldKind.of(key): '$value',
      };
      if (steps == null) return {'filled': fillFocused(input, text, group)};
      String? step;
      var filled = steps.deliver('fill', _target(params, 'a field'), (id) {
        step = id;
        return fillFocused(input, text, group);
      });
      return {'filled': filled, 'step': ?step};
    })
    ..registerHandler(worldInputChannel, 'open', (params) async {
      var link = params['link'];
      if (link is! String) {
        if (steps == null) return <String, Object?>{};
        var step = steps.deliver('open', _target(params, 'a link'), (id) => id);
        return {'step': step};
      }
      if (steps == null) return {'routed': await pushRouteInformation(link)};
      String? step;
      var routed = await steps.deliver('open', _target(params, 'a link'), (id) {
        step = id;
        return pushRouteInformation(link);
      });
      return {'routed': routed, 'step': ?step};
    });
}

/// Hands [location] — a whole link, `https://example.com/invite?t=1` — to
/// the app as the platform does when it opens the app on a link and the app
/// has Flutter's deep linking on: `pushRouteInformation` on
/// `flutter/navigation`, which reaches `didPushRouteInformation` and from
/// there a `Router` or the root `Navigator`. Answers whether anything in the
/// app took it.
Future<bool> pushRouteInformation(String location) {
  var channel = SystemChannels.navigation;
  var taken = Completer<bool>();
  ServicesBinding.instance.channelBuffers.push(
    channel.name,
    channel.codec.encodeMethodCall(
      MethodCall('pushRouteInformation', {'location': location, 'state': null}),
    ),
    (reply) {
      try {
        taken.complete(
          reply != null && channel.codec.decodeEnvelope(reply) == true,
        );
      } on Object {
        taken.complete(false);
      }
    },
  );
  return taken.future;
}

/// What kind of field [configuration] is: its autofill hints first — what the
/// app says the field is for — then its keyboard, then whether it hides what
/// is typed, which only a password does.
FieldKind fieldKindOf(TextInputConfiguration configuration) {
  for (var hint in configuration.autofillConfiguration.autofillHints) {
    if (_hinted[hint] case var kind?) return kind;
  }
  return switch (configuration.inputType) {
    TextInputType.emailAddress => FieldKind.email,
    TextInputType.phone => FieldKind.phone,
    TextInputType.name => FieldKind.name,
    TextInputType.visiblePassword => FieldKind.password,
    _ when configuration.obscureText => FieldKind.password,
    _ => FieldKind.other,
  };
}

/// Flutter's [AutofillHints], and the web's `autocomplete` words an app
/// written for both might use instead.
const _hinted = {
  AutofillHints.email: FieldKind.email,
  AutofillHints.username: FieldKind.email,
  AutofillHints.newUsername: FieldKind.email,
  AutofillHints.password: FieldKind.password,
  AutofillHints.newPassword: FieldKind.password,
  'current-password': FieldKind.password,
  'new-password': FieldKind.password,
  AutofillHints.name: FieldKind.name,
  AutofillHints.givenName: FieldKind.name,
  AutofillHints.familyName: FieldKind.name,
  AutofillHints.nickname: FieldKind.name,
  'given-name': FieldKind.name,
  'family-name': FieldKind.name,
  AutofillHints.telephoneNumber: FieldKind.phone,
  AutofillHints.telephoneNumberDevice: FieldKind.phone,
  AutofillHints.telephoneNumberNational: FieldKind.phone,
  'tel': FieldKind.phone,
  AutofillHints.oneTimeCode: FieldKind.code,
  // AutofillHints.emailOTPCode, which stable Flutter does not have yet.
  'emailOTPCode': FieldKind.code,
  'one-time-code': FieldKind.code,
};

/// What [worldFocusChannel] says of [input]'s focused field: its kind, and
/// the kinds of the other fields in its `AutofillGroup`; empty when nothing
/// has focus.
Map<String, Object?> focusedField(GuestTextInput input) {
  var field = input.field.value;
  if (field == null) return const {};
  var self = field.autofillConfiguration.uniqueIdentifier;
  return {
    'kind': fieldKindOf(field).name,
    'group': [
      for (var other in input.group)
        if (other.autofillId != self)
          fieldKindOf(other.textInputConfiguration).name,
    ],
  };
}

/// Fills [input]'s focused field with [text], and each other field of its
/// `AutofillGroup` whose kind [group] has a value for. Answers how many
/// fields it filled: none when nothing has focus.
int fillFocused(
  GuestTextInput input,
  String text,
  Map<FieldKind, String> group,
) {
  var field = input.field.value;
  if (field == null || !input.fill(text)) return 0;
  var filled = 1;
  if (group.isEmpty) return filled;
  var self = field.autofillConfiguration.uniqueIdentifier;
  for (var other in input.group.toList()) {
    if (other.autofillId == self) continue;
    var value = group[fieldKindOf(other.textInputConfiguration)];
    if (value == null) continue;
    other.autofill(
      TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      ),
    );
    filled++;
  }
  return filled;
}

String _target(Map<String, Object?> params, String otherwise) =>
    params['target'] is String ? params['target']! as String : otherwise;
