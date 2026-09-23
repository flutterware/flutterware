import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/shell/address_bar.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'command_palette.dart' show wrapInAppTheme;

/// The address readout as a row of live parts, without a shell behind it.
///
/// The first entry is wired: clicking the plugin, a segment or a chip rewrites
/// the address it displays, and the worktree menu offers a made-up repo. The
/// rest are states — what the strip looks like bare, deep, squeezed, and naming
/// a worktree that does not exist.
///
/// No Figma behind this — it is flutterware's own chrome; the part behaviour
/// is specified in `AddressBar`'s doc comment.
/// Enough of them that the switcher's filter earns its place.
const _worktrees = [
  WorktreeChoice(name: '~', displayName: 'master', isOpen: true),
  WorktreeChoice(
    name: 'repo-explorer',
    displayName: 'feature/explorer',
    isOpen: true,
  ),
  WorktreeChoice(
    name: 'repo-switcher',
    displayName: 'claude/worktree-switcher',
    isOpen: false,
  ),
  WorktreeChoice(
    name: 'repo-scenarios',
    displayName: 'claude/scenarios-m4',
    isOpen: false,
  ),
  WorktreeChoice(
    name: 'repo-icons',
    displayName: 'fix/launcher-icons',
    isOpen: false,
  ),
  WorktreeChoice(
    name: 'repo-assets',
    displayName: 'feature/asset-pipeline',
    isOpen: true,
  ),
  // The row a title has taken the label of. Its branch rides alongside, because
  // it is a name you can still filter by and it is nowhere else on the row.
  WorktreeChoice(
    name: 'repo-split',
    displayName: 'Split button rework',
    branch: 'claude/split-button-rework',
    isOpen: false,
  ),
];

Address get _deep => Address(
  worktree: '~',
  plugin: 'flutterware.previews',
  segments: ['app', 'tool/demos', 'avatar.dart#members'],
  axes: {'axis.theme': 'dark'},
);

/// The shape that overflowed: a deep path, a leaf long enough to matter, and a
/// device framed sideways — which is two chips rather than one, because
/// orientation rides beside the device it applies to.
Address get _crowded => Address(
  worktree: '~',
  plugin: 'flutterware.previews',
  segments: [
    'app',
    'tool',
    'catalog',
    'demos',
    'avatar_tile.dart#avatarTileEmpty',
  ],
  axes: {'device': 'iphone-16', 'orientation': 'landscape'},
);

@Preview(name: 'Live', group: 'Address bar', wrapper: wrapInAppTheme)
Widget addressBarLive() => const _Live();

@Preview(name: 'States', group: 'Address bar', wrapper: wrapInAppTheme)
Widget addressBarStates() => ListView(
  padding: const EdgeInsets.symmetric(vertical: FwSpacing.xl),
  children: [
    _Labelled('a worktree and nothing else', _Strip(Address(worktree: '~'))),
    _Labelled(
      'a plugin root',
      _Strip(Address(worktree: '~', plugin: 'flutterware.dependencies')),
    ),
    _Labelled('a deep entry with an axis applied', _Strip(_deep)),
    _Labelled(
      'squeezed — the middle gives way first, the leaf only once it must',
      _Strip(_deep, width: 480),
    ),
    _Labelled(
      'a long leaf and two axes — what used to run off the end',
      _Strip(_crowded),
    ),
    _Labelled(
      'an address naming a worktree this repo does not have',
      _Strip(_deep.copyWith(worktree: 'gone')),
    ),
  ],
);

/// One readout that clicking actually rewrites, plus a line saying where it is.
class _Live extends StatefulWidget {
  const _Live();

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  var _address = _deep;
  var _note = 'Click the parts. Each one answers for itself.';

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _Strip(
          _address,
          onGo: (destination) => setState(() {
            _address = destination;
            _note = 'went to $destination';
          }),
          onPickWorktree: (choice) => setState(() {
            _address = _address.copyWith(worktree: choice.name);
            _note =
                'switched to ${choice.displayName}'
                '${choice.isOpen ? '' : ' — the shell would open it first'}';
          }),
          onEdit: () => setState(() => _note = 'the editor opens here'),
        ),
        const Gap(FwSpacing.md),
        Text(_note, style: context.type.micro.copyWith(color: colors.mut3)),
      ],
    );
  }
}

/// The strip as the shell draws it — height, panel, hairline — so the demo
/// shows the readout at the size it actually lives at.
class _Strip extends StatelessWidget {
  const _Strip(
    this.address, {
    this.width,
    this.onGo,
    this.onPickWorktree,
    this.onEdit,
  });

  final Address address;
  final double? width;
  final ValueChanged<Address>? onGo;
  final ValueChanged<WorktreeChoice>? onPickWorktree;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Center(
      child: Container(
        width: width,
        height: addressBarHeight,
        decoration: BoxDecoration(
          color: colors.panel,
          border: Border(top: BorderSide(color: colors.line)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
        child: AddressReadout(
          address: address,
          worktrees: _worktrees,
          onGo: onGo ?? (_) {},
          onPickWorktree: onPickWorktree ?? (_) {},
          onEdit: onEdit ?? () {},
        ),
      ),
    );
  }
}

/// A caption above a state, so a screenshot of this entry says what each strip
/// is meant to be showing.
class _Labelled extends StatelessWidget {
  const _Labelled(this.caption, this.child);

  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.lg,
            0,
            FwSpacing.lg,
            FwSpacing.xs,
          ),
          child: Text(
            caption,
            style: context.type.micro.copyWith(color: context.colors.mut3),
          ),
        ),
        child,
      ],
    ),
  );
}
