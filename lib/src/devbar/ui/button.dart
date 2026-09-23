import 'package:material_ui/material_ui.dart';

import '../devbar.dart';
import 'service.dart';

class AddDevbarButton extends StatefulWidget {
  final Widget? child;
  final Widget button;
  final DevbarButtonPosition? position;

  const AddDevbarButton({
    super.key,
    this.child,
    required this.button,
    this.position,
  });

  @override
  State<AddDevbarButton> createState() => _AddDevbarButtonState();
}

class _AddDevbarButtonState extends State<AddDevbarButton> {
  late DevbarButtonHandle _buttonHandle;

  @override
  void initState() {
    super.initState();

    var devbar = DevbarState.of(context);
    _buttonHandle = devbar.ui.addButton(
      widget.button,
      position: widget.position,
    );
  }

  @override
  Widget build(BuildContext context) {
    _buttonHandle.refresh(widget.button);
    return widget.child ?? const SizedBox();
  }

  @override
  void dispose() {
    _buttonHandle.remove();
    super.dispose();
  }
}

class DevbarIcon extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  final Color? color;

  const DevbarIcon({
    super.key,
    required this.onTap,
    required this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: _Icon(icon: icon, color: color),
      ),
    );
  }
}

class _Icon extends StatelessWidget {
  final IconData icon;
  final Color? color;

  const _Icon({required this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: (color ?? Colors.black54).withValues(alpha: 0.1),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.5),
          width: 3,
        ),
      ),
      child: Icon(icon, color: color ?? Colors.black54, size: 26),
    );
  }
}

class DevbarDropdown<T> extends StatefulWidget {
  final void Function(T) onChanged;
  final IconData icon;
  final Color? color;
  final Map<T, Widget> values;

  const DevbarDropdown({
    super.key,
    required this.onChanged,
    required this.icon,
    this.color,
    required this.values,
  });

  @override
  State<DevbarDropdown<T>> createState() => _DevbarDropdownButtonState<T>();
}

class _DevbarDropdownButtonState<T> extends State<DevbarDropdown<T>> {
  final _key = LabeledGlobalKey('button_icon');
  bool _isMenuOpen = false;
  late Offset _buttonPosition;
  late Size _buttonSize;
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    super.dispose();
  }

  void closeMenu() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _isMenuOpen = !_isMenuOpen;
  }

  void openMenu() {
    var renderBox = _key.currentContext!.findRenderObject()! as RenderBox;
    _buttonSize = renderBox.size;
    _buttonPosition = renderBox.localToGlobal(Offset.zero);
    var overlayEntry = _overlayEntry = _overlayEntryBuilder();
    Overlay.of(context).insert(overlayEntry);
    _isMenuOpen = !_isMenuOpen;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _key,
      onTap: () {
        if (_isMenuOpen) {
          closeMenu();
        } else {
          openMenu();
        }
      },
      child: _Icon(icon: widget.icon, color: widget.color),
    );
  }

  OverlayEntry _overlayEntryBuilder() {
    return OverlayEntry(
      builder: (context) {
        return Positioned(
          top: _buttonPosition.dy + _buttonSize.height,
          right: 0,
          child: SizedBox(
            width: 200,
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(5),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var entry in widget.values.entries) ...[
                      GestureDetector(
                        onTap: () {
                          widget.onChanged(entry.key);
                          closeMenu();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: entry.value,
                        ),
                      ),
                      Divider(),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
