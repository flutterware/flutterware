import 'dart:async';

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
/// - `open`: names the step a link is about to arrive under. The link comes
///   through the links plugin's own stream, which runs where the app
///   listened, so what it starts joins by time. Given a `link`, it arrives
///   here instead, the way Flutter's own deep linking delivers one — see
///   [pushRouteInformation] — and the answer says whether the app took it.
///
/// Both take the `target` the trace names the step by: `the code from SMS`.
/// Without [steps] — a guest built before deliveries were steps — a code is
/// still typed, on no step.
void installWorldInput([WorldSteps? steps]) {
  GuestChannels.core
    ..registerHandler(worldInputChannel, 'type', (params) {
      var input = GuestTextInput.instance;
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

String _target(Map<String, Object?> params, String otherwise) =>
    params['target'] is String ? params['target']! as String : otherwise;
