import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import '../plugins/manifest_loader.dart';
import '../ui/panel_header.dart';
import '../ui/theme.dart';
import 'shell_controller.dart';
import 'worktree.dart';

/// The config screen's root, so a test can scope to it.
const configScreenKey = Key('config-screen');

/// `fw:///worktrees/<worktree>/config` — the shell's own screen for
/// `tool/flutterware.dart`.
///
/// Deliberately not a plugin. Which plugins exist is this file's decision, so a
/// plugin panel that explained it could be removed by the very edit that broke
/// it — and a worktree whose config fails to load is exactly when you need this
/// screen most. It lives in the plugin *slot* of the address because it is
/// addressed like one (see [Address.shellConfig]), and nowhere else.
///
/// Two questions: **what did it resolve to**, and **why did it fail**. There
/// was a third — a history of what each reload cost — which existed to make a
/// surgical reload auditable. A reload that rebuilds the whole graph has nothing
/// per-row left to say, so the history went with the surgery and what remains
/// of it is one line in the band and one in the terminal.
class ConfigScreen extends StatelessWidget {
  const ConfigScreen(this.shell, this.worktree, {super.key});

  final ShellController shell;
  final Worktree worktree;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var error = shell.errorFor(worktree);
    var manifest = shell.manifestFor(worktree);

    return ListView(
      key: configScreenKey,
      padding: const EdgeInsets.only(bottom: FwSpacing.xxxl),
      children: [
        FwPanelHeader(
          'Config',
          subtitle: ['${worktree.path}/$configFilePath'],
          selectableSubtitle: true,
          trailing: _ReloadAction(shell, worktree),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: panelGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Watch(shell, worktree),

              if (error != null) ...[
                const Gap(FwSpacing.xxl),
                _Failure(error.message),
              ],

              if (manifest != null) ...[
                const Gap(FwSpacing.xxl),
                Text('Resolved', style: context.type.sectionLabel),
                const Gap(FwSpacing.sm),
                _Resolved(shell, worktree, manifest),
              ],

              if (manifest == null && error == null) ...[
                const Gap(FwSpacing.xxl),
                Text(
                  'This worktree declares no $configFilePath.',
                  style: context.type.bodyMuted.copyWith(color: colors.mut),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Re-runs the config. The same call the band button used to make, moved to
/// where the result of making it is on screen.
class _ReloadAction extends StatelessWidget {
  const _ReloadAction(this.shell, this.worktree);

  final ShellController shell;
  final Worktree worktree;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Re-run $configFilePath',
    child: FilledButton.icon(
      // Only while one is already running. It used to also refuse while a
      // plugin hard-blocked teardown, which made the button that fixes a broken
      // config refusable by the plugins the broken config left running.
      onPressed: shell.isLoading(worktree) ? null : () => shell.reloadConfig(),
      icon: const Icon(Icons.refresh, size: FwIconSize.sm),
      label: const Text('Reload'),
    ),
  );
}

/// What is actually being watched.
///
/// Naming the directory is functional rather than decorative. "It did not notice my
/// edit" is the standard complaint about file watching, and the standard cause is
/// that the thing you edited was not in the watched set. Saying which directory
/// is watched turns that from a mystery into a fact — and today the answer is
/// only the config's own directory, so an edit to a file it imports really does
/// need the button until the import closure arrives with the resident compiler.
///
/// There is no off switch. There was one, on the theory that a watcher which
/// looks armed and is not should be turnable off to say so — but this line
/// already says what is armed, and the switch brought its own failure mode: a
/// fresh watcher takes the current file as its baseline, so every edit made
/// while it was off had to be caught up on re-enabling or be silently eaten.
/// That was a review finding, not a hypothetical.
class _Watch extends StatelessWidget {
  const _Watch(this.shell, this.worktree);

  final ShellController shell;
  final Worktree worktree;

  @override
  Widget build(BuildContext context) {
    var watching = shell.watchingFor(worktree);
    return Text(
      watching == null
          ? 'Nothing to watch — this worktree has no $configFilePath'
          : 'Reloads on save · watching $watching',
      style: context.type.caption.copyWith(color: context.colors.mut),
    );
  }
}

/// Why the config did not load, with the compiler's own words.
///
/// The whole output, not a first line: this is the screen you came to in order
/// to read it, so there is nothing left to hide it behind.
class _Failure extends StatelessWidget {
  const _Failure(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var lines = message.trimRight().split('\n');

    return Container(
      padding: const EdgeInsets.all(FwSpacing.lg),
      decoration: BoxDecoration(
        border: Border.all(color: colors.red),
        borderRadius: BorderRadius.circular(context.radii.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lines.first,
            style: context.type.bodyStrong.copyWith(color: colors.red),
          ),
          if (lines.length > 1) ...[
            const Gap(FwSpacing.sm),
            SelectableText(
              lines.skip(1).join('\n').trim(),
              style: context.type.caption.copyWith(fontFamily: 'monospace'),
            ),
          ],
          const Gap(FwSpacing.sm),
          Text(
            'The plugins below are the ones from the last config that loaded. '
            'Nothing was torn down.',
            style: context.type.caption.copyWith(color: colors.mut),
          ),
        ],
      ),
    );
  }
}

/// What the config actually said: its packages, then its plugins.
///
/// The answer to "why isn't my plugin showing up", which is otherwise only
/// answerable by reading the file and guessing.
///
/// The packages are **derived** — read off the plugins that name them, since
/// `fw.packages([...])` went away — so this list is not something the file says
/// anywhere in one place. That makes showing it more useful than it was, not
/// less: it is the only view of the union.
class _Resolved extends StatelessWidget {
  const _Resolved(this.shell, this.worktree, this.manifest);

  final ShellController shell;
  final Worktree worktree;
  final PluginManifest manifest;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var missing =
        shell.workspaceFor(worktree)?.unknownDeclarations ?? const <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var pkg in manifest.packages)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Icon(
                  missing.contains(pkg.path)
                      ? Icons.error_outline
                      : Icons.folder_outlined,
                  size: FwIconSize.xs,
                  color: missing.contains(pkg.path) ? colors.red : colors.mut2,
                ),
                const Gap(FwSpacing.sm),
                Text(
                  pkg.path,
                  style: context.type.caption.copyWith(
                    fontFamily: 'monospace',
                    color: missing.contains(pkg.path) ? colors.red : null,
                  ),
                ),
                if (missing.contains(pkg.path)) ...[
                  const Gap(FwSpacing.sm),
                  Text(
                    'not on disk',
                    style: context.type.micro.copyWith(color: colors.red),
                  ),
                ],
              ],
            ),
          ),

        const Gap(FwSpacing.lg),

        for (var plugin in manifest.plugins)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(plugin.label, style: context.type.bodyStrong),
                    const Gap(FwSpacing.sm),
                    Text(
                      plugin.id,
                      style: context.type.micro.copyWith(
                        fontFamily: 'monospace',
                        color: colors.mut2,
                      ),
                    ),
                  ],
                ),
                // The config keys, not their values: a value can be a nested
                // list of packages and this is an orientation, not a dump.
                if (plugin.config.isNotEmpty)
                  Text(
                    plugin.config.keys.join(', '),
                    style: context.type.micro.copyWith(color: colors.mut2),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
