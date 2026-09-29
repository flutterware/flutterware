import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'tappable.dart';
import 'theme.dart';

/// A desktop browser's window around an app: the traffic lights and one tab,
/// then back, forward, reload and the address — what a phone's body is to a
/// phone.
///
/// Artwork, like the phone's body: a browser in its light look whatever the
/// studio's theme, because that is what the person in front of it sees. Its
/// greys are the browser's, not the studio's tokens.
///
/// The address is live — typed into and submitted — and so is back; the
/// rest is only drawn.
class BrowserFrame extends StatefulWidget {
  const BrowserFrame({
    super.key,
    required this.screen,
    required this.title,
    required this.host,
    required this.path,
    required this.child,
    this.titleColor,
    this.onBack,
    this.onGo,
  });

  /// The page's size, in logical pixels: the window's, without its chrome.
  final Size screen;

  /// The tab's words.
  final String title;

  /// Beside the title, the way a site's icon is.
  final Color? titleColor;

  /// The address's muted part, before [path]: `lab.localhost`.
  final String host;

  /// What the app says it is showing: `/orders/o3`. Empty until it says.
  final String path;

  /// The back button; null draws it greyed.
  final VoidCallback? onBack;

  /// An address typed in and submitted, as typed.
  final ValueChanged<String>? onGo;

  final Widget child;

  static const _tabsHeight = 42.0;
  static const _barHeight = 40.0;

  /// The chrome above the page, its rule included.
  static const chromeHeight = _tabsHeight + _barHeight + 1;

  /// The whole window around a page of [screen]: its chrome and its border.
  static Size frameSize(Size screen) =>
      Size(screen.width + 2, screen.height + chromeHeight + 2);

  @override
  State<BrowserFrame> createState() => _BrowserFrameState();
}

// The browser's own greys.
const _tabsGround = Color(0xFFDFE3E8);
const _addressGround = Color(0xFFEEF1F4);
const _rule = Color(0xFFE3E5E8);
const _ink = Color(0xFF202124);
const _icon = Color(0xFF5F6368);
const _iconOff = Color(0xFFC4C7CB);
const _lights = [Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)];

class _BrowserFrameState extends State<BrowserFrame> {
  final _address = TextEditingController();
  final _typing = FocusNode(debugLabel: 'browser address');

  @override
  void initState() {
    super.initState();
    _typing.addListener(() {
      if (_typing.hasFocus) {
        _address
          ..text = widget.host + widget.path
          ..selection = TextSelection(
            baseOffset: 0,
            extentOffset: _address.text.length,
          );
      } else {
        // At rest the address is the one the app reports; what was typed
        // is gone, as in a browser once it has gone there.
        _address.clear();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _address.dispose();
    _typing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var size = BrowserFrame.frameSize(widget.screen);
    return Container(
      width: size.width,
      height: size.height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        border: Border.all(color: const Color(0x33000000)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x3815181D),
            blurRadius: 50,
            offset: Offset(0, 24),
          ),
          BoxShadow(
            color: Color(0x2915181D),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          _tabs(context),
          _bar(context),
          SizedBox.fromSize(size: widget.screen, child: widget.child),
        ],
      ),
    );
  }

  Widget _tabs(BuildContext context) => Container(
    height: BrowserFrame._tabsHeight,
    color: _tabsGround,
    padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          height: BrowserFrame._tabsHeight,
          child: Row(
            children: [
              for (var light in _lights) ...[
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: light,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: FwSpacing.md),
              ],
            ],
          ),
        ),
        const SizedBox(width: FwSpacing.sm),
        Container(
          height: 34,
          width: 250,
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
          decoration: const BoxDecoration(
            color: Color(0xFFFFFFFF),
            borderRadius: BorderRadius.vertical(top: Radius.circular(9)),
          ),
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.titleColor ?? _icon,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.title.isEmpty ? '' : widget.title[0].toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFFFFFFFF),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: FwSpacing.md),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _ink, fontSize: 13),
                ),
              ),
              const Icon(Icons.close, size: 15, color: _icon),
            ],
          ),
        ),
        const SizedBox(width: FwSpacing.md),
        const SizedBox(
          height: BrowserFrame._tabsHeight,
          child: Icon(Icons.add, size: 20, color: _icon),
        ),
      ],
    ),
  );

  Widget _bar(BuildContext context) {
    Widget button(IconData icon, VoidCallback? onTap) => Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.pill),
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xs),
        child: Icon(icon, size: 20, color: onTap == null ? _iconOff : _icon),
      ),
    );
    var go = widget.onGo;
    return Container(
      height: BrowserFrame._barHeight + 1,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
      decoration: const BoxDecoration(
        color: Color(0xFFFFFFFF),
        border: Border(bottom: BorderSide(color: _rule)),
      ),
      child: Row(
        children: [
          button(Icons.arrow_back, widget.onBack),
          button(Icons.arrow_forward, null),
          button(Icons.refresh, null),
          const SizedBox(width: FwSpacing.sm),
          Expanded(
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: _addressGround,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: _icon),
                  const SizedBox(width: FwSpacing.md),
                  Expanded(
                    child: go == null
                        ? _shown()
                        : Stack(
                            alignment: Alignment.centerLeft,
                            children: [
                              // Always in the tree, so a click on the address
                              // lands in it; drawn over at rest by the address
                              // as a browser shows it.
                              _field(go),
                              if (!_typing.hasFocus)
                                IgnorePointer(
                                  child: ColoredBox(
                                    color: _addressGround,
                                    child: SizedBox(
                                      width: double.infinity,
                                      child: _shown(),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: FwSpacing.sm),
          const Icon(Icons.more_vert, size: 20, color: _icon),
        ],
      ),
    );
  }

  static const _addressStyle = TextStyle(fontSize: 14, color: _ink);

  /// The address at rest: the host muted, the path the app is on in full.
  Widget _shown() => Align(
    alignment: Alignment.centerLeft,
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: widget.host,
            style: const TextStyle(color: _icon),
          ),
          TextSpan(text: widget.path),
        ],
      ),
      style: _addressStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );

  Widget _field(ValueChanged<String> go) {
    void submit() {
      _typing.unfocus();
      go(_address.text.trim());
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _typing.unfocus,
        // The key as well as the text input's action: whichever reaches the
        // field first goes, and a key event is what a scripted Enter is.
        const SingleActivator(LogicalKeyboardKey.enter): submit,
      },
      child: TextField(
        controller: _address,
        focusNode: _typing,
        style: _addressStyle,
        cursorColor: _ink,
        // The browser's field, not the studio's: no border, no fill, no
        // padding of its own inside the rounded ground.
        decoration: const InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
        ),
        onSubmitted: (_) => submit(),
      ),
    );
  }
}
