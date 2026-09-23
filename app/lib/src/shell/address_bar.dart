import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/plugins.dart';

import '../address/address_scope.dart';
import '../ui/design/design.dart';
import '../ui/tappable.dart';
import 'shell_controller.dart';
import 'worktree_filter.dart';

/// Height of the strip. Deliberately smaller than the band: this is a readout,
/// and the tabs above it are the thing you aim at.
const addressBarHeight = 24.0;

/// The current address along the bottom of the window.
///
/// It is the instrument before it is a feature. Everything that writes the
/// address — a search hit, a click in a catalog tree, eventually a knob — is
/// invisible until something displays the result, and "did that write land?" is
/// not a question worth answering by reading code. Clicking it goes the other
/// way: paste an address and the app has to become it, which is the only honest
/// test that the address really is the state rather than a caption on it.
///
/// Along the bottom rather than in the band because the band is worth more.
/// Tabs are aimed at; this is glanced at, and a full-width strip also means the
/// address rarely needs shortening at all.
///
/// The readout is a row of independently live parts. The bar used to be one
/// tap target that opened the editor, with the worktree chevron as the single
/// exception; the second live part would have been a mode you discover by being
/// surprised, so editing got its own affordance instead — the `edit` button on
/// the right, sitting where its hint used to appear — and each part now answers
/// for itself: the worktree opens the switcher, the plugin jumps to its root,
/// a middle segment truncates the address there, a chip removes its axis. Each
/// lights under its own pointer, which is what keeps five behaviours from being
/// five surprises. Blank space still opens the editor — the parts win the arena
/// where they are, and a dead strip would read as a broken one.
class AddressBar extends StatefulWidget {
  const AddressBar(this.shell, {super.key});

  final ShellController shell;

  @override
  State<AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends State<AddressBar> {
  final _menu = MenuController();
  final _field = TextEditingController();
  final _focus = FocusNode();

  /// What the field held when it was last seeded, so an address that moves
  /// underneath an *untouched* field can refresh it without overwriting
  /// something half-typed.
  var _seeded = '';

  /// Why the last submission went nowhere, or null.
  String? _problem;

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _open(Address address) {
    _seed(address);
    _menu.open();
    // Once the menu has an overlay to focus into.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _field.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _field.text.length,
      );
    });
  }

  void _seed(Address address) {
    _seeded = address.toString();
    _field.text = _seeded;
    _problem = null;
  }

  void _submit() {
    var parsed = Address.tryParse(_field.text.trim());
    if (parsed == null) {
      setState(() => _problem = 'Not a flutterware address.');
      return;
    }

    var result = widget.shell.go(parsed);
    setState(() {
      _problem = switch (result) {
        GoResult.ok || GoResult.unchanged => null,
        GoResult.worktreeUnknown =>
          parsed.worktree == null
              ? 'That address names no worktree.'
              : 'No worktree named "${parsed.worktree}" in this repo.',
      };
    });
    if (_problem == null) _menu.close();
  }

  @override
  Widget build(BuildContext context) {
    // The one place reading the whole address is the right thing to do: it is
    // what this widget displays.
    var address = AddressScope.of(context).full;

    // The field follows the app while it is open and untouched, so watching the
    // address move as you click around does not mean closing it first.
    if (_menu.isOpen &&
        _field.text == _seeded &&
        address.toString() != _seeded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _menu.isOpen && _field.text == _seeded) {
          setState(() => _seed(address));
        }
      });
    }

    var shell = widget.shell;
    var colors = context.colors;
    return Container(
      height: addressBarHeight,
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: MenuAnchor(
        controller: _menu,
        alignmentOffset: const Offset(0, -4),
        style: MenuStyle(
          alignment: Alignment.topLeft,
          backgroundColor: WidgetStatePropertyAll(colors.bg),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(context.radii.radius),
              side: BorderSide(color: colors.line),
            ),
          ),
        ),
        menuChildren: [_Editor(this, address)],
        builder: (context, controller, child) => Tappable(
          onTap: () => controller.isOpen ? controller.close() : _open(address),
          feedback: TapFeedback.none,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
            child: AddressReadout(
              address: address,
              worktrees: [
                for (var worktree in shell.worktrees)
                  WorktreeChoice(
                    name: worktree.name,
                    displayName: worktree.displayName,
                    branch: worktree.branch,
                    isOpen: shell.isOpen(worktree),
                  ),
              ],
              onGo: (destination) => shell.go(destination),
              onPickWorktree: (choice) {
                var worktree = shell.worktreeNamed(choice.name);
                if (worktree != null) shell.goToWorktree(worktree);
              },
              onEdit: () =>
                  controller.isOpen ? controller.close() : _open(address),
              editing: controller.isOpen,
            ),
          ),
        ),
      ),
    );
  }
}

/// A worktree as the switcher menu needs it: nothing of the shell, so the
/// readout can be exercised in the catalog with a made-up repo.
class WorktreeChoice {
  const WorktreeChoice({
    required this.name,
    required this.displayName,
    this.branch,
    required this.isOpen,
  });

  /// The identity that goes in the address (`Worktree.name`).
  final String name;

  /// The branch or title a human knows the checkout by.
  final String displayName;

  /// The checked-out branch, when it is not already [displayName] — a title a
  /// plugin contributed displaces it there, and a detached checkout has none.
  /// Carried so the filter can find a row by a name the title hid.
  final String? branch;

  /// Whether picking it navigates, or first opens it.
  final bool isOpen;

  /// [branch], when the row is not already showing it as [displayName]. Null
  /// otherwise, so the row draws it exactly when it would be new information —
  /// and the filter never lights a run in a string twice.
  String? get hiddenBranch => branch == displayName ? null : branch;
}

/// The address as parts rather than as a string, each part live on its own.
///
/// Only the middle collapses. The worktree says which checkout you are in and
/// the last segment says what you are looking at; the path between them is
/// usually the same one it was a minute ago, so that is what gives way when the
/// window is narrow — segment by segment now, so a squeezed breadcrumb keeps
/// its joints where a single ellipsized string would lose them.
///
/// What each part does when clicked is the breadcrumb reading of the address:
/// the worktree switches checkout, the plugin drops the path below it, a middle
/// segment truncates there. The last segment is where you already are, so it is
/// the one piece of the path that stays text.
class AddressReadout extends StatelessWidget {
  const AddressReadout({
    super.key,
    required this.address,
    required this.worktrees,
    required this.onGo,
    required this.onPickWorktree,
    required this.onEdit,
    this.editing = false,
  });

  final Address address;

  /// Everything the switcher offers, current one included.
  final List<WorktreeChoice> worktrees;

  /// A part asking the app to become [Address] — a truncated path, a plugin
  /// root, an address with one axis fewer.
  final ValueChanged<Address> onGo;

  /// The switcher menu choosing a checkout. Separate from [onGo] because
  /// switching keeps the place and the axes, which is the shell's move to make.
  final ValueChanged<WorktreeChoice> onPickWorktree;

  /// The `edit` button. The bar behind the readout is the other way in.
  final VoidCallback onEdit;

  /// Whether the editor is open, so its button stays lit while it is.
  final bool editing;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mono = context.type.micro.copyWith(
      fontFamily: 'monospace',
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    );

    Widget part(String text, Color color) =>
        Text(text, style: mono.copyWith(color: color), softWrap: false);
    Widget separator() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: part('/', colors.mut3),
    );

    // `fw://` then the empty project then the leading slash — one inert piece,
    // because there is nothing to click or read in the middle of it. The space
    // that follows is inert for the same reason it is here at all: there is one
    // of them, and nowhere else to go.
    var head = <Widget>[part('fw://${address.project ?? ''}/', colors.mut3)];
    if (address.space case var space?) {
      head.add(part(space, colors.mut3));
    }
    if (address.worktree case var worktree?) {
      head
        ..add(separator())
        ..add(
          _WorktreeSwitcher(
            current: worktree,
            worktrees: worktrees,
            onPick: onPickWorktree,
            style: mono,
          ),
        );
    }
    if (address.plugin case var plugin?) {
      head
        ..add(separator())
        ..add(
          _Part(
            onTap: () => onGo(
              Address(
                project: address.project,
                worktree: address.worktree,
                plugin: plugin,
              ),
            ),
            child: (lit) => part(plugin, lit ? colors.ink2 : colors.mut),
          ),
        );
    }

    // The middle gives way first; the last gives way only once there is
    // nothing left to take from it.
    var segments = address.segments;
    var last = segments.lastOrNull;

    return Row(
      children: [
        // Its own row inside the Expanded, rather than parts and a Spacer in
        // one flex pool: a Spacer is flex too, and sharing with it squeezed
        // the middle segments long before the window did.
        Expanded(
          child: Row(
            children: [
              ...head,
              // **The middle path is one flexible block, not one per segment.**
              // A `Row` hands every flex child `freeSpace / totalFlex` and never
              // gives the unused part back, so a leaf competing with each
              // segment individually would be clamped to a sixth of the bar on a
              // deep path and ellipsized with room to spare. Grouped, it
              // competes with a single sibling — and this block is the one that
              // yields, because the path between the worktree and the leaf is
              // usually the same one it was a minute ago.
              if (segments.length > 1)
                Flexible(
                  child: Row(
                    // Shrink-wrapped, or the block would swallow its whole
                    // allotment and hand the leaf the leftovers of a half it
                    // never needed.
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < segments.length - 1; i++) ...[
                        separator(),
                        Flexible(
                          child: _Part(
                            onTap: () => onGo(
                              address.copyWith(
                                segments: segments.sublist(0, i + 1),
                                // The axes applied to the leaf do not describe
                                // its parents.
                                axes: const {},
                              ),
                            ),
                            child: (lit) => Text(
                              segments[i],
                              style: mono.copyWith(
                                color: lit ? colors.ink2 : colors.mut3,
                              ),
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              if (last != null) ...[
                separator(),
                // **Ellipsized rather than overflowing.** It used to be laid out
                // at its natural width whatever the bar could afford, which is
                // fine until the bar is full: a long leaf and two axis chips
                // painted 55 pixels of debug stripes across the strip. It is
                // still the last part to give way — it just gives way now
                // instead of running off the end.
                Flexible(
                  child: Text(
                    last,
                    style: mono.copyWith(color: colors.ink2),
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              for (var axis in address.axes.entries) ...[
                const Gap(FwSpacing.sm),
                _AxisChip(
                  axis.key,
                  axis.value,
                  onRemove: () => onGo(
                    address.copyWith(axes: {...address.axes}..remove(axis.key)),
                  ),
                ),
              ],
            ],
          ),
        ),
        _Part(
          onTap: onEdit,
          lit: editing,
          child: (lit) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.edit_outlined,
                size: 10,
                color: lit ? colors.ink2 : colors.mut3,
              ),
              const Gap(3),
              part('edit', lit ? colors.ink2 : colors.mut3),
            ],
          ),
        ),
      ],
    );
  }
}

/// One live part of the readout: quiet text until the pointer is on it, its
/// hit box padded to the strip's height so nothing here has to be aimed at.
class _Part extends StatefulWidget {
  const _Part({required this.onTap, required this.child, this.lit = false});

  final VoidCallback onTap;

  /// Lit from outside — a menu this part opened being open counts as hovered.
  final bool lit;

  final Widget Function(bool lit) child;

  @override
  State<_Part> createState() => _PartState();
}

class _PartState extends State<_Part> {
  @override
  // Its own target, so a tap here is this part rather than the editor the whole
  // bar sits under: the inner one wins the arena.
  Widget build(BuildContext context) => Tappable.builder(
    onTap: widget.onTap,
    builder: (context, hovered) => Padding(
      // Most of the target, and none of the weight.
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      child: widget.child(hovered || widget.lit),
    ),
  );
}

/// The worktree segment: switch which checkout the address names.
///
/// The name and the chevron are one target now that every part is live — the
/// chevron stays drawn because it is what says "this one opens a menu" where
/// its neighbours navigate, not because it is the only place to click.
///
/// The menu opens on a filter field, because a repo with a worktree per
/// branch-in-flight has too many rows to scan: type a few letters of the
/// branch or the name, press ↵, and the first match is picked — the same
/// contract as the address editor's "↵ to go there". The field sits at the
/// *bottom*: this menu grows up from the bar, so the bottom edge is the one
/// that stays put, and a filter that narrows the list must not move under the
/// cursor that is typing into it.
///
/// Quiet on purpose. The bar is glanced at far more often than it is used, so
/// the chevron is mut3 until the pointer is on the part.
class _WorktreeSwitcher extends StatefulWidget {
  const _WorktreeSwitcher({
    required this.current,
    required this.worktrees,
    required this.onPick,
    required this.style,
  });

  /// The worktree the address names, which may not be one that exists.
  final String current;

  final List<WorktreeChoice> worktrees;

  final ValueChanged<WorktreeChoice> onPick;

  /// The readout's type, so the identities in the menu line up with the bar.
  final TextStyle style;

  @override
  State<_WorktreeSwitcher> createState() => _WorktreeSwitcherState();
}

class _WorktreeSwitcherState extends State<_WorktreeSwitcher> {
  final _menu = MenuController();
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();
  var _query = '';

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  /// Every name on the row, because every one of them is a name you might
  /// filter by: the label, git's own name, and the branch when a title has
  /// taken the label from it.
  List<(WorktreeChoice, FilterMatch?)> get _matches {
    if (_query.trim().isEmpty) {
      return [for (var worktree in widget.worktrees) (worktree, null)];
    }
    return [
      for (var worktree in widget.worktrees)
        if (matchWorktreeFilter(_query, [
              worktree.displayName,
              worktree.name,
              worktree.hiddenBranch,
            ])
            case var match?)
          (worktree, match),
    ];
  }

  void _open() {
    _filter.clear();
    _query = '';
    _menu.open();
    // Once the menu has an overlay to focus into.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _filterFocus.requestFocus();
    });
  }

  void _pickFirst() {
    var first = _matches.firstOrNull;
    if (first == null) return;
    _menu.close();
    widget.onPick(first.$1);
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var here = widget.worktrees
        .where((w) => w.name == widget.current)
        .firstOrNull;

    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, -4),
      style: MenuStyle(
        alignment: Alignment.topLeft,
        backgroundColor: WidgetStatePropertyAll(colors.bg),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(context.radii.radius),
            side: BorderSide(color: colors.line),
          ),
        ),
      ),
      menuChildren: [
        // Rows first, field last: the menu grows upward, so document order
        // puts the field on the fixed bottom edge, beside the bar it came
        // from, with the list narrowing away above it.
        if (_matches.isEmpty) const NoWorktreeMatches(),
        for (var (worktree, match) in _matches)
          MenuItemButton(
            leadingIcon: Icon(
              worktree.name == widget.current ? Icons.check : null,
              size: FwIconSize.sm,
              color: colors.accent,
            ),
            onPressed: () => widget.onPick(worktree),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The branch, because that is what a checkout is known by, with
                // git's name for it alongside, because that is what the address
                // will say once you have picked it.
                matchedName(
                  context,
                  worktree.displayName,
                  context.type.bodySmall,
                  match: match,
                ),
                const Gap(FwSpacing.sm),
                matchedName(
                  context,
                  worktree.name,
                  widget.style.copyWith(color: colors.mut3),
                  match: match,
                  field: 1,
                ),
                // Only when a title took the label: the branch is what you
                // filtered by, so it has to be on the row that the filter kept.
                if (worktree.hiddenBranch case var branch?) ...[
                  const Gap(FwSpacing.sm),
                  matchedName(
                    context,
                    branch,
                    widget.style.copyWith(color: colors.mut3),
                    match: match,
                    field: 2,
                  ),
                ],
                // Choosing it opens it, which costs a config subprocess and a
                // cold compile. Cheap enough to be worth doing and dear enough
                // to be worth knowing about first.
                if (!worktree.isOpen) ...[
                  const Gap(FwSpacing.sm),
                  Text(
                    'opens',
                    style: context.type.caption.copyWith(color: colors.mut3),
                  ),
                ],
              ],
            ),
          ),
        WorktreeFilterField(
          controller: _filter,
          focusNode: _filterFocus,
          onChanged: (value) => setState(() => _query = value),
          onSubmitted: (_) => _pickFirst(),
        ),
      ],
      builder: (context, controller, child) => Tooltip(
        // Says what `~` means, which the address deliberately does not, and says
        // how this differs from the switcher in the band above: that one takes
        // you to where a worktree was left, this brings where you are to it.
        message: here == null
            ? 'Show this in another worktree'
            : 'On ${here.displayName} — show this in another worktree',
        waitDuration: const Duration(milliseconds: 400),
        child: _Part(
          onTap: () => controller.isOpen ? controller.close() : _open(),
          lit: controller.isOpen,
          child: (lit) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.current,
                style: widget.style.copyWith(
                  color: lit ? colors.ink2 : colors.mut,
                ),
                softWrap: false,
              ),
              const Gap(2),
              Icon(
                Icons.expand_more,
                size: FwIconSize.xs,
                color: lit ? colors.ink2 : colors.mut3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One applied axis. A chip rather than `?theme=dark` run together, because
/// what a demo is set to is worth reading at a glance and this is where knobs
/// will land next.
///
/// Clicking it removes the axis — the value came from a picker somewhere, and
/// the chip is the one place the *application* of it is visible, so it is the
/// natural place to undo it. The × only draws under the pointer; read, it is a
/// label, and only touched is it a control.
class _AxisChip extends StatelessWidget {
  const _AxisChip(this.name, this.value, {required this.onRemove});

  final String name;
  final String value;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return _Part(
      onTap: onRemove,
      child: (lit) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: colors.panel2,
          borderRadius: BorderRadius.circular(context.radii.micro),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${name.split('.').last} $value',
              style: context.type.micro.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
                color: lit ? colors.ink2 : colors.mut,
              ),
            ),
            if (lit) ...[
              const Gap(3),
              Icon(Icons.close, size: 9, color: colors.ink2),
            ],
          ],
        ),
      ),
    );
  }
}

/// The expanded form: the whole address, editable, and what went wrong.
class _Editor extends StatelessWidget {
  const _Editor(this.state, this.address);

  final _AddressBarState state;
  final Address address;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return SizedBox(
      width: 560,
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: state._field,
                    focusNode: state._focus,
                    onSubmitted: (_) => state._submit(),
                    style: context.type.bodySmall.copyWith(
                      fontFamily: 'monospace',
                      letterSpacing: 0,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: colors.panel,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: FwSpacing.md,
                        vertical: FwSpacing.md,
                      ),
                      border: _border(context, colors.line),
                      enabledBorder: _border(context, colors.line),
                      focusedBorder: _border(context, colors.accent),
                    ),
                  ),
                ),
                const Gap(FwSpacing.sm),
                IconButton(
                  tooltip: 'Copy',
                  icon: Icon(
                    Icons.copy_rounded,
                    size: FwIconSize.sm,
                    color: colors.mut,
                  ),
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: address.toString()),
                  ),
                ),
              ],
            ),
            const Gap(FwSpacing.sm),
            Text(
              state._problem ?? 'Press ↵ to go there.',
              style: context.type.caption.copyWith(
                color: state._problem == null ? colors.mut3 : colors.red,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The field chrome both menus share — the editor's address field and the
/// switcher's filter.
OutlineInputBorder _border(BuildContext context, Color color) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(context.radii.radius),
      borderSide: BorderSide(color: color),
    );
