import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/previews/catalog_devices.dart';
import 'package:flutterware_app/src/previews/catalog_session.dart';
import 'package:flutterware_app/src/previews/staged_device.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The preview panel's own device capsule — picker, rotation, frame, keyboard
/// — in every state it takes, all at once.
///
/// What this is for. The control is four 24pt segments sharing one border,
/// and everything interesting about it is a pixel or a glyph: whether the
/// border survives the corner, whether the two icons beside each other read as
/// two different controls, what "dim" looks like next to "lit". None of that
/// can be judged from the running studio, where the capsule is 130px in a
/// corner of a window and every variant costs a device pick — and none of it
/// survives a widget test, which has no icon font and draws every glyph as a
/// box. Here they are side by side at whatever size you frame them.
///
/// The dependencies are the whole point of it being possible: an [Address] in a
/// [ValueNotifier] and a [CatalogStaging], both of which are constructible in a
/// line. Nothing needs a session, a guest or a shell.

@Preview(
  name: 'Device capsule',
  group: 'Previews panel',
  wrapper: wrapInAppTheme,
)
Widget deviceCapsule() => const _Sheet();

@Preview(
  name: 'Device capsule · dark',
  group: 'Previews panel',
  wrapper: wrapInDarkTheme,
)
Widget deviceCapsuleDark() => const _Sheet();

/// Every combination worth looking at, each in its own address so they can all
/// be live at the same time.
class _Sheet extends StatelessWidget {
  const _Sheet();

  @override
  Widget build(BuildContext context) => Container(
    color: context.colors.panel,
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Row('a phone, framed', device: 'iphone-16'),
        _Row('on its side', device: 'iphone-16', orientation: 'landscape'),
        _Row('frame off', device: 'iphone-16', framed: false),
        _Row('a tablet', device: 'ipad'),
        _Row(
          'keyboard up because the demo focused a field',
          device: 'iphone-16',
          keyboardUp: true,
        ),
        _Row('keyboard held up', device: 'iphone-16', keyboard: 'up'),
        _Row('keyboard held down', device: 'iphone-16', keyboard: 'down'),
        _Row('a window — only the picker applies', device: 'window-wide'),
        _Row('Fit — the panel itself'),
      ],
    ),
  );
}

/// One capsule with its own address, labelled. Live: the segments write to the
/// notifier beside them, so a demo of six is six working controls.
class _Row extends StatefulWidget {
  const _Row(
    this.label, {
    this.device,
    this.orientation,
    this.framed = true,
    this.keyboard,
    this.keyboardUp,
  });

  final String label;
  final String? device;
  final String? orientation;
  final bool framed;
  final String? keyboard;

  /// Whether a keyboard is on screen. Null follows the mode, which is what
  /// every row but one wants — the exception is the row that exists to show
  /// what `auto` looks like once the demo itself has focused something, which
  /// no address can say.
  final bool? keyboardUp;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  late final address = ValueNotifier(
    Address(
      worktree: 'demo',
      plugin: 'flutterware.previews',
      axes: {
        if (widget.device != null) 'device': widget.device!,
        if (widget.orientation != null) 'orientation': widget.orientation!,
        if (widget.keyboard != null) 'keyboard': widget.keyboard!,
      },
    ),
  );
  late final staging = CatalogStaging()..frameVisible = widget.framed;

  @override
  void dispose() {
    address.dispose();
    staging.dispose();
    super.dispose();
  }

  KeyboardMode get keyboardMode =>
      keyboardModeById(address.value.axes['keyboard'] ?? '') ??
      KeyboardMode.auto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: AddressRoot(
      address: address,
      onChanged: (next) => address.value = next,
      child: ListenableBuilder(
        listenable: staging,
        builder: (context, _) => Row(
          children: [
            StagedDevice(
              device: resolveDevice(address.value.axes['device']),
              orientation: resolveOrientation(
                address.value.axes['orientation'],
              ),
              declared: const [],
              staging: staging,
              keyboard: keyboardMode,
              keyboardUp: widget.keyboardUp ?? keyboardMode == KeyboardMode.up,
            ),
            const SizedBox(width: 16),
            // Flexible because this sheet is looked at inside the panel too,
            // where the pane is narrower than the labels — and a demo that
            // reports an overflow is a demo nobody trusts about anything else.
            Flexible(
              child: Text(
                widget.label,
                style: context.type.caption,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
