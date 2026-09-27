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
///   listened, so what it starts joins by time.
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
    ..registerHandler(worldInputChannel, 'open', (params) {
      if (steps == null) return <String, Object?>{};
      var step = steps.deliver('open', _target(params, 'a link'), (id) => id);
      return {'step': step};
    });
}

String _target(Map<String, Object?> params, String otherwise) =>
    params['target'] is String ? params['target']! as String : otherwise;
