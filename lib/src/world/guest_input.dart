import '../server/vm_transport.dart' show GuestChannels;
import '../ui_catalog/guest_text_input.dart';
import 'step_names.dart';

/// Lets the world type into this app: a code it delivers arrives in the
/// focused field the way the platform's own input would — an SMS code's
/// autofill — through [GuestTextInput], this guest's text input. Asked on
/// [worldInputChannel]; call once [GuestTextInput.install] has run.
void installWorldInput() => GuestChannels.core.registerHandler(
  worldInputChannel,
  'type',
  (params) => {
    'typed': GuestTextInput.instance.fill('${params['text'] ?? ''}'),
  },
);
