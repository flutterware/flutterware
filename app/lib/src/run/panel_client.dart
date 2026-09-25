import 'dart:async';

import 'package:flutterware/channels.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart'
    show InspectorRequestException;

import 'channel_client.dart';

/// The cockpit's reader for an app's panels: list them, read a state, get and
/// set knobs, run an action.
///
/// Thin on purpose. Every method is one request on the channel the panel owns,
/// and the shapes coming back are the published descriptors — there is no
/// cockpit-side model of a panel, because a second model is a second thing to
/// keep in step with the app.
class RunPanels {
  RunPanels(this.client);

  final RunAttachment client;

  /// Fires when the app says its panel list moved — a plugin mounted, a devbar
  /// unmounted. Carries nothing: the answer is to re-[list], which is one
  /// round trip and always right.
  Stream<void> get changed =>
      client.events.where((event) => event.channel == panelsChannel);

  /// What the app declares — none, for an app nothing has declared a panel in.
  ///
  /// Such an app does not answer with an empty list: `GuestChannels.panels`
  /// is created on first use, so every app the run guest wraps can be attached
  /// to, but only one that declared a panel has `panels.list` registered. The
  /// rest say nothing handles it, which means the same thing.
  Future<List<PanelDescriptor>> list() async {
    Map<String, Object?> reply;
    try {
      reply = await client.request(panelsChannel, panelsList);
    } on Object catch (e) {
      if (!isUnhandled(e, panelsChannel)) rethrow;
      return const [];
    }
    return [
      for (var panel in reply['panels'] as List? ?? const [])
        PanelDescriptor.fromJson((panel as Map).cast<String, Object?>()),
    ];
  }

  Future<Map<String, Object?>> state(String panelId, String stateId) =>
      client.request(panelId, panelStateMethod, {'id': stateId});

  Future<List<KnobDescriptor>> knobs(String panelId) async =>
      _knobs(await client.request(panelId, panelKnobsMethod));

  /// Sets a knob and answers with **what the app now holds**, which is not
  /// necessarily what was asked for: an app may clamp a slider or reject a
  /// value, and a cockpit that echoed the request would show a lie.
  Future<List<KnobDescriptor>> setKnob(
    String panelId,
    String knobId,
    Object? value,
  ) async => _knobs(
    await client.request(panelId, panelSetKnobMethod, {
      'id': knobId,
      'value': value,
    }),
  );

  /// Runs one of the panel's commands inside the app.
  Future<Map<String, Object?>> invoke(
    String panelId,
    String actionId, [
    Map<String, Object?> args = const {},
  ]) => client.request(panelId, actionId, args);

  List<KnobDescriptor> _knobs(Map<String, Object?> reply) => [
    for (var knob in reply['knobs'] as List? ?? const [])
      KnobDescriptor.fromJson((knob as Map).cast<String, Object?>()),
  ];
}

/// Whether [error] is the app saying nothing is registered on [channel] — how
/// `InspectorCore` answers a request to a panel that was never declared.
bool isUnhandled(Object error, String channel) =>
    error is InspectorRequestException &&
    error.message.startsWith('no handler for $channel.');
