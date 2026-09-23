import 'dart:async';

import 'package:material_ui/material_ui.dart';

const _buttonBackground = Color(0xffeaeaea);
const _textStyle = TextStyle(fontSize: 13, color: Colors.black87);

/// An inline segmented control for the toolbar — all [items] visible at once,
/// the selected one filled. Better than [ToolbarPicker] for a few options.
class ToolbarSegmented<T> extends StatelessWidget {
  final T value;
  final void Function(T) onChanged;
  final Map<T, Widget> items;
  final Widget? title;

  const ToolbarSegmented({
    super.key,
    required this.value,
    required this.onChanged,
    required this.items,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          DefaultTextStyle.merge(style: _textStyle, child: title!),
          const SizedBox(width: 6),
        ],
        DecoratedBox(
          decoration: BoxDecoration(
            color: _buttonBackground,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var entry in items.entries)
                _Segment(
                  selected: entry.key == value,
                  onTap: () => onChanged(entry.key),
                  child: entry.value,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Segment extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  const _Segment({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? Colors.white : null,
          borderRadius: BorderRadius.circular(4),
          border: selected ? Border.all(color: const Color(0xffcfcfcf)) : null,
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.black87 : Colors.black54,
          ),
          child: child,
        ),
      ),
    );
  }
}

class Toolbar extends StatelessWidget {
  static const height = 40.0;

  final List<Widget> children;

  const Toolbar({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Material(
      child: DefaultTextStyle.merge(
        style: _textStyle,
        child: Theme(
          data: _theme(context),
          child: SizedBox(
            height: height,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(vertical: 5, horizontal: 10),
              children: [
                for (var child in children) ...[
                  child,
                  if (child != children.last) SizedBox(width: 7),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  ThemeData _theme(BuildContext context) {
    var theme = Theme.of(context);
    return theme.copyWith(
      elevatedButtonTheme: _buttonTheme(),
      iconTheme: theme.iconTheme.merge(_iconTheme()),
    );
  }

  ElevatedButtonThemeData _buttonTheme() {
    return ElevatedButtonThemeData(
      style: ButtonStyle(
        elevation: WidgetStateProperty.all(0),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
        ),
        backgroundColor: WidgetStateProperty.all(_buttonBackground),
        foregroundColor: WidgetStateProperty.all(Colors.black87),
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStateProperty.all(_textStyle),
      ),
    );
  }

  IconThemeData _iconTheme() {
    return IconThemeData(size: 20);
  }
}

class ToolbarDropdown<T> extends StatelessWidget {
  static const _highlightColor = Color(0xff0000ff);

  final T value;
  final void Function(T?) onChanged;
  final Map<T, Widget> items;
  final bool showArrow;
  final bool highlight;

  const ToolbarDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    required this.items,
    bool? showArrow,
    bool? highlight,
  }) : showArrow = showArrow ?? true,
       highlight = highlight ?? false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: highlight ? _highlightColor : _buttonBackground,
        borderRadius: BorderRadius.circular(2),
      ),
      child: DropdownButton<T>(
        value: value,
        items: [
          for (var entry in items.entries)
            DropdownMenuItem(value: entry.key, child: entry.value),
        ],
        onChanged: (v) => onChanged(v),
        icon: Icon(
          Icons.arrow_drop_down,
          color: highlight ? Colors.white : null,
        ),
        iconSize: showArrow ? 18 : 0,
        style: _textStyle.copyWith(color: highlight ? Colors.white : null),
        dropdownColor: highlight ? _highlightColor : null,
        underline: SizedBox(),
      ),
    );
  }
}

class ToolbarPicker<T> extends StatelessWidget {
  final Widget? title;
  final T value;
  final void Function(T) onChanged;
  final Map<T, Widget> items;
  final Map<T, Widget>? itemTiles;

  const ToolbarPicker({
    super.key,
    this.title,
    required this.value,
    required this.onChanged,
    required this.items,
    this.itemTiles,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: () {
        showDialog(context: context, builder: _dialog);
      },
      child: items[value] ?? items.values.first,
    );
  }

  Widget _dialog(BuildContext context) {
    return AlertDialog(
      title: title,
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: ListTile.divideTiles(
            context: context,
            tiles: [
              for (var item in items.entries) _itemTile(context, item.key),
            ],
          ).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: Text('CANCEL'),
        ),
      ],
    );
  }

  Widget _itemTile(BuildContext context, T key) {
    Widget? tile;
    if (itemTiles != null) {
      tile = itemTiles![key];
      if (tile != null) {
        tile = InkWell(onTap: () => _onTap(context, key), child: tile);
      }
    }
    tile ??= ListTile(title: items[key], onTap: () => _onTap(context, key));

    tile = Row(
      children: [
        Expanded(child: tile),
        Icon(key == value ? Icons.check : null, color: Color(0xff0000ff)),
      ],
    );

    return tile;
  }

  void _onTap(BuildContext context, T key) {
    onChanged(key);
    Navigator.pop(context);
  }
}

/// A compact chip that opens an anchored popover menu under it — lighter than
/// [ToolbarPicker]'s modal dialog, with all options still one tap away.
class ToolbarPopover<T> extends StatelessWidget {
  final Widget? title;
  final T value;
  final void Function(T) onChanged;
  final Map<T, Widget> items;

  const ToolbarPopover({
    super.key,
    this.title,
    required this.value,
    required this.onChanged,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          DefaultTextStyle.merge(style: _textStyle, child: title!),
          const SizedBox(width: 6),
        ],
        MenuAnchor(
          style: MenuStyle(
            visualDensity: VisualDensity.compact,
            backgroundColor: WidgetStateProperty.all(Colors.white),
          ),
          menuChildren: [
            for (var entry in items.entries)
              MenuItemButton(
                leadingIcon: Icon(
                  entry.key == value ? Icons.check : null,
                  size: 16,
                ),
                onPressed: () => onChanged(entry.key),
                child: DefaultTextStyle.merge(
                  style: _textStyle,
                  child: entry.value,
                ),
              ),
          ],
          builder: (context, controller, child) {
            return InkWell(
              onTap: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              borderRadius: BorderRadius.circular(2),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _buttonBackground,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    items[value] ?? const SizedBox.shrink(),
                    const SizedBox(width: 2),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class ToolbarCheckbox extends StatelessWidget {
  final String title;
  final bool value;
  final void Function(bool) onChanged;

  const ToolbarCheckbox({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        onChanged(!value);
      },
      child: Row(
        children: [
          Center(child: Text(title)),
          Checkbox(value: value, onChanged: (v) => onChanged(v!)),
        ],
      ),
    );
  }
}

class ToolbarPanel extends StatefulWidget {
  final Widget button;
  final Widget panel;
  final Widget Function({
    required VoidCallback onPressed,
    required Widget button,
  })?
  buttonBuilder;
  final Offset panelOffset;
  final Alignment panelTargetAnchor;
  final Alignment panelFollowerAnchor;

  const ToolbarPanel({
    super.key,
    required this.button,
    required this.panel,
    this.buttonBuilder,
    this.panelOffset = Offset.zero,
    this.panelTargetAnchor = Alignment.bottomLeft,
    this.panelFollowerAnchor = Alignment.topLeft,
  });

  @override
  State<ToolbarPanel> createState() => ToolbarPanelState();

  static ToolbarPanelState of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_ToolbarPanelProvider>()!
        .panel;
  }
}

class ToolbarPanelState extends State<ToolbarPanel> {
  final _refreshStream = StreamController.broadcast();
  final LayerLink layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  void showMenu() {
    hideMenu();
    var overlay = _overlayEntry = OverlayEntry(
      builder: (BuildContext context) {
        return _ToolbarPanelProvider(
          panel: this,
          child: Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: hideMenu,
              child: _Menu(link: layerLink, panelState: this),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(overlay);
  }

  void hideMenu() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    _refreshStream.add(null);

    var child = CompositedTransformTarget(
      link: layerLink,
      child: widget.button,
    );
    if (widget.buttonBuilder case var iconBuilder?) {
      return iconBuilder(onPressed: showMenu, button: child);
    } else {
      return ElevatedButton(onPressed: showMenu, child: child);
    }
  }

  @override
  void dispose() {
    _refreshStream.close();
    super.dispose();
  }
}

class _Menu extends StatelessWidget {
  final LayerLink link;
  final ToolbarPanelState panelState;

  const _Menu({required this.link, required this.panelState});

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: link,
        offset: panelState.widget.panelOffset,
        targetAnchor: panelState.widget.panelTargetAnchor,
        followerAnchor: panelState.widget.panelFollowerAnchor,
        child: Card(
          color: theme.canvasColor,
          child: GestureDetector(
            onTap: () {},
            behavior: HitTestBehavior.opaque,
            child: StreamBuilder<void>(
              stream: panelState._refreshStream.stream,
              builder: (context, snapshot) {
                return panelState.widget.panel;
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarPanelProvider extends InheritedWidget {
  final ToolbarPanelState panel;
  const _ToolbarPanelProvider({required super.child, required this.panel});

  @override
  bool updateShouldNotify(_ToolbarPanelProvider oldWidget) {
    return true;
  }
}
