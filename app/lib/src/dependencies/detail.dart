import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';
import 'package:pub_scores/pub_scores.dart';
import 'package:url_launcher/url_launcher.dart';

import '../address/address_scope.dart';
import '../ui/empty_state.dart';
import '../ui/markdown_style.dart';
import '../ui/theme.dart';
import '../utils/async_value.dart';
import '../utils/cloc/cloc.dart';
import '../utils/utils.dart';
import '../utils/value_stream_builder.dart';
import 'model/package_imports.dart';
import 'model/package_origin.dart';
import 'model/pub_dev_api.dart';
import 'model/service.dart';
import 'utils.dart';
import '../ui/loading_state.dart';

class DependencyDetailScreen extends StatelessWidget {
  final DependenciesService dependencies;
  final String packageName;

  const DependencyDetailScreen(
    this.dependencies,
    this.packageName, {
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ValueStreamBuilder<Snapshot<Dependencies>>(
      stream: dependencies.dependencies.snapshots,
      builder: (context, snapshot, child) {
        if (snapshot.hasError) {
          return _NotFound(
            title: 'Could not load dependencies',
            message: '${snapshot.error}',
          );
        }
        if (snapshot.isLoading) {
          return const LoadingState(title: 'Reading the dependency…');
        }

        var dependency = snapshot.requireData[packageName];
        if (dependency == null) {
          return _NotFound(
            title: "$packageName is not in this package's graph",
            message:
                'It may belong to another workspace member, or the '
                'resolution may be out of date.',
          );
        }
        return _DetailScreen(dependencies, dependency);
      },
    );
  }
}

class _NotFound extends StatelessWidget {
  final String title;
  final String message;

  const _NotFound({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _BackBar(),
        Expanded(
          child: EmptyState(
            icon: Icons.search_off,
            title: title,
            message: message,
          ),
        ),
      ],
    );
  }
}

class _DetailScreen extends StatelessWidget {
  final DependenciesService dependencies;
  final Dependency dependency;

  const _DetailScreen(this.dependencies, this.dependency);

  @override
  Widget build(BuildContext context) {
    // Two independent sources, neither of which the page waits for: pub.dev
    // metadata and the GitHub numbers from the vendored snapshot. Every section
    // below renders from disk first and fills in when they arrive.
    return ValueStreamBuilder<Snapshot<PubDevPackage>>(
      stream: dependencies.pubDevFor(dependency.name).snapshots,
      builder: (context, pubDev, child) {
        return ValueStreamBuilder<Snapshot<PubScores>>(
          stream: dependencies.pubScores.snapshots,
          builder: (context, scores, child) => _body(
            context,
            pubDev.data,
            scores.data?[dependency.name]?.github,
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    PubDevPackage? pubDev,
    GitHubInfo? github,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _BackBar(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.xxl,
              0,
              FwSpacing.xxl,
              FwSpacing.xxl,
            ),
            children: [
              _Header(dependency, pubDev),
              const Gap(FwSpacing.lg),
              _Stats(dependency, pubDev, github),
              const Gap(FwSpacing.lg),
              _VersionsSection(dependency, pubDev),
              const Gap(FwSpacing.lg),
              _WhySection(dependency),
              const Gap(FwSpacing.lg),
              _UsageSection(dependencies, dependency),
              if (pubDev != null) ...[
                const Gap(FwSpacing.lg),
                _CompatibilitySection(pubDev),
              ],
              const Gap(FwSpacing.lg),
              _DocumentSection(
                dependency: dependency,
                title: 'Readme',
                candidates: const ['README.md', 'readme.md', 'README'],
              ),
              const Gap(FwSpacing.lg),
              _DocumentSection(
                dependency: dependency,
                title: 'Changelog',
                candidates: const ['CHANGELOG.md', 'changelog.md', 'CHANGELOG'],
                highlightVersion: dependency.resolvedVersion,
              ),
              const Gap(FwSpacing.lg),
              _DocumentSection(
                dependency: dependency,
                // Not "License": the compatibility section already has a row
                // by that name carrying the SPDX id, and two headings reading
                // the same on one page is a question about which is which.
                title: 'License text',
                candidates: const ['LICENSE', 'LICENSE.md', 'LICENSE.txt'],
                startCollapsed: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Drops this screen's own segments, keeping the package the panel is on.
///
/// Read off the address rather than passed in: the package is already there —
/// it is what put this screen on screen — and threading it down would be a
/// second copy of something the address holds.
class _BackBar extends StatelessWidget {
  const _BackBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xxl,
        FwSpacing.lg,
        FwSpacing.xxl,
        FwSpacing.md,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () {
            var handle = AddressScope.write(context);
            handle.setSegments([?handle.segment(0)]);
          },
          icon: const Icon(Icons.arrow_back, size: FwIconSize.md),
          label: const Text('All dependencies'),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Dependency dependency;
  final PubDevPackage? pubDev;

  const _Header(this.dependency, this.pubDev);

  @override
  Widget build(BuildContext context) {
    var description = dependency.description ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: FwSpacing.md,
          runSpacing: FwSpacing.xs,
          children: [
            Text(dependency.name, style: context.type.pageTitle),
            _Chip(
              label: dependency.hasMeaningfulVersion
                  ? 'v${dependency.resolvedVersion}'
                  : dependency.origin.label,
            ),
            _KindChip(dependency.kind),
            _OriginChip(dependency.origin),
            if (pubDev?.isDiscontinued ?? false)
              _Chip(
                label: pubDev?.replacedBy == null
                    ? 'Discontinued'
                    : 'Discontinued → ${pubDev!.replacedBy}',
                tone: context.colors.red,
              ),
            if (pubDev?.publisher case var publisher?)
              _Chip(label: publisher, icon: Icons.verified_outlined),
          ],
        ),
        if (description.isNotEmpty) ...[
          const Gap(FwSpacing.sm),
          Text(description, style: context.type.bodyMuted),
        ],
        const Gap(FwSpacing.md),
        Wrap(
          spacing: FwSpacing.md,
          children: [
            if (dependency.origin case HostedOrigin _)
              _LinkButton(
                label: 'pub.dev',
                icon: Icons.open_in_new,
                onTap: () => openPub(dependency),
              ),
            if (_repository case var repository?)
              _LinkButton(
                label: 'Repository',
                icon: Icons.code,
                onTap: () => launchUrl(Uri.parse(repository)),
              ),
            if (dependency.rootPath case var path?)
              _LinkButton(
                label: 'Reveal on disk',
                icon: Icons.folder_open,
                onTap: () => launchUrl(Uri.file(path)),
              ),
          ],
        ),
      ],
    );
  }

  /// The git URL when the package came from git — which is more accurate than
  /// whatever its pubspec claims — otherwise what pub.dev lists.
  String? get _repository => switch (dependency.origin) {
    GitOrigin git when git.url.startsWith('http') => git.url,
    _ => pubDev?.repository,
  };
}

/// The numbers, in one strip. Each tile renders whatever it has and says
/// nothing where it has nothing, so a package that is not on pub.dev shows
/// lines of code and size rather than a row of dashes.
class _Stats extends StatelessWidget {
  final Dependency dependency;
  final PubDevPackage? pubDev;
  final GitHubInfo? github;

  const _Stats(this.dependency, this.pubDev, this.github);

  @override
  Widget build(BuildContext context) {
    var number = NumberFormat.compact(locale: 'en_US');
    return Wrap(
      spacing: FwSpacing.md,
      runSpacing: FwSpacing.md,
      children: [
        if (pubDev?.downloadCount30Days case var downloads?)
          _StatTile(
            label: 'Downloads / 30d',
            value: number.format(downloads),
            icon: Icons.download_outlined,
          ),
        if (pubDev?.likeCount case var likes?)
          _StatTile(
            label: 'Likes',
            value: number.format(likes),
            icon: Icons.thumb_up_outlined,
          ),
        if (pubDev?.grantedPoints case var points?)
          _StatTile(
            label: 'Pub points',
            value: '$points / ${pubDev?.maxPoints ?? 160}',
            icon: Icons.workspace_premium_outlined,
          ),
        if (github != null)
          _StatTile(
            label: 'GitHub stars',
            value: number.format(github!.starCount),
            icon: Icons.star_outline,
            onTap: () => openGithub(github!),
          ),
        _ClocTile(dependency),
        _SizeTile(dependency),
        if (pubDev?.publishedAt(dependency.resolvedVersion) case var date?)
          _StatTile(
            label: 'This version',
            value: formatAge(date),
            icon: Icons.schedule,
          ),
      ],
    );
  }
}

class _ClocTile extends StatelessWidget {
  final Dependency dependency;

  const _ClocTile(this.dependency);

  @override
  Widget build(BuildContext context) {
    return ValueStreamBuilder<Snapshot<ClocReport>>(
      stream: dependency.cloc.snapshots,
      builder: (context, snapshot, child) {
        var data = snapshot.data;
        if (data == null) {
          return const _StatTile(
            label: 'Lines of code',
            value: '…',
            icon: Icons.subject,
          );
        }
        var byLanguage = data.languages.entries
            .sortedBy<num>((e) => e.value.lines)
            .reversed
            .toList();
        var total = byLanguage.fold(0, (sum, e) => sum + e.value.lines);
        return _StatTile(
          label: 'Lines of code',
          value: NumberFormat.compact(locale: 'en_US').format(total),
          icon: Icons.subject,
          tooltip: byLanguage
              .take(5)
              .map(
                (e) =>
                    '${NumberFormat.decimalPattern('en_US').format(e.value.lines)} ${e.key.name}',
              )
              .join('\n'),
        );
      },
    );
  }
}

class _SizeTile extends StatelessWidget {
  final Dependency dependency;

  const _SizeTile(this.dependency);

  @override
  Widget build(BuildContext context) {
    return ValueStreamBuilder<Snapshot<SizeReport>>(
      stream: dependency.size.snapshots,
      builder: (context, snapshot, child) {
        var data = snapshot.data;
        return _StatTile(
          label: 'On disk',
          value: data == null ? '…' : getSizeAsMB(data.totalBytes),
          icon: Icons.folder_outlined,
          tooltip: data == null ? null : '${data.fileCount} files',
        );
      },
    );
  }
}

/// What you asked for, what you got, and what exists.
class _VersionsSection extends StatelessWidget {
  final Dependency dependency;
  final PubDevPackage? pubDev;

  const _VersionsSection(this.dependency, this.pubDev);

  @override
  Widget build(BuildContext context) {
    var latest = pubDev?.latestVersion;
    var behind =
        latest != null &&
        dependency.hasMeaningfulVersion &&
        latest != dependency.resolvedVersion;

    return _Section(
      title: 'Versions',
      trailing: behind
          ? _Chip(label: 'Update available', tone: context.colors.amber)
          : null,
      child: Column(
        children: [
          _Row(
            label: 'Constraint',
            child: Text(
              dependency.constraint ??
                  'not declared here — pulled in transitively',
              style: dependency.constraint == null
                  ? context.type.bodyMuted
                  : context.type.body,
            ),
          ),
          _Row(
            label: 'Resolved',
            child: Text(
              dependency.hasMeaningfulVersion
                  ? dependency.resolvedVersion
                  : dependency.origin.label,
            ),
          ),
          if (latest != null)
            _Row(
              label: 'Latest on pub.dev',
              child: Row(
                children: [
                  Text(latest),
                  if (pubDev?.published case var date?) ...[
                    const Gap(FwSpacing.md),
                    Text(
                      'published ${formatAge(date)}',
                      style: context.type.bodyMuted,
                    ),
                  ],
                ],
              ),
            ),
          _Row(label: 'Source', child: _OriginDetail(dependency.origin)),
        ],
      ),
    );
  }
}

/// Why this package is here — the chains, as a tree rather than the
/// arrow-joined string that used to live in a tooltip.
class _WhySection extends StatefulWidget {
  final Dependency dependency;

  const _WhySection(this.dependency);

  @override
  State<_WhySection> createState() => _WhySectionState();
}

class _WhySectionState extends State<_WhySection> {
  static const _collapsedCount = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    var paths = widget.dependency.dependencyPaths;
    if (paths.isEmpty) {
      return const _Section(
        title: 'Why is this here?',
        child: Text('Nothing in this package reaches it.'),
      );
    }

    var shown = _expanded ? paths : paths.take(_collapsedCount).toList();
    var hidden = paths.length - shown.length;

    return _Section(
      title: 'Why is this here?',
      trailing: _Chip(
        label: widget.dependency.isDirect
            ? 'Declared by you'
            : '${paths.length} path${paths.length > 1 ? 's' : ''}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var path in shown) ...[_Chain(path), const Gap(FwSpacing.sm)],
          if (hidden > 0)
            TextButton(
              onPressed: () => setState(() => _expanded = true),
              child: Text('Show $hidden more'),
            ),
        ],
      ),
    );
  }
}

/// One chain, indented step by step so the shape is readable at a glance.
class _Chain extends StatelessWidget {
  final List<String> path;

  const _Chain(this.path);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var (index, name) in path.indexed)
          Padding(
            padding: EdgeInsets.only(left: index * 14.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (index > 0)
                  Icon(
                    Icons.subdirectory_arrow_right,
                    size: FwIconSize.sm,
                    color: context.colors.mut3,
                  ),
                const Gap(FwSpacing.xxs),
                Text(
                  name,
                  style: index == path.length - 1
                      ? context.type.bodyStrong
                      : context.type.bodyMuted,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Where this package is actually referenced from.
class _UsageSection extends StatefulWidget {
  final DependenciesService dependencies;
  final Dependency dependency;

  const _UsageSection(this.dependencies, this.dependency);

  @override
  State<_UsageSection> createState() => _UsageSectionState();
}

class _UsageSectionState extends State<_UsageSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ValueStreamBuilder<Snapshot<PackageImports>>(
      stream: widget.dependencies.packageImports.snapshots,
      builder: (context, snapshot, child) {
        var imports = snapshot.data;
        if (imports == null) {
          return const _Section(title: 'Usage', child: Text('Scanning…'));
        }

        var name = widget.dependency.name;
        var references = imports[name];
        var assets = imports.assetsOf(name);

        if (references.isEmpty && assets.isEmpty) {
          return _Section(
            title: 'Usage',
            child: Text(
              widget.dependency.isDirect
                  // Deliberately not called "unused": a package can be needed
                  // without ever being imported — build_runner through
                  // annotations, a lint set through analysis_options, a plugin
                  // through its native side. Saying what was searched for is
                  // honest; concluding it is dead weight is not.
                  ? 'No Dart file imports it and no asset declaration names '
                        'it. That does not always mean it is unused — build '
                        'tooling, lint sets and native-only plugins are never '
                        'referenced from source.'
                  : 'Not imported directly; it arrives through another package.',
              style: context.type.bodyMuted,
            ),
          );
        }

        var byLibrary = groupBy(references, (e) => e.library);
        var shown = _expanded ? references : references.take(8).toList();
        var fileCount = imports.fileCount(name);

        return _Section(
          title: 'Usage',
          trailing: Wrap(
            spacing: FwSpacing.xs,
            children: [
              if (fileCount > 0)
                _Chip(label: '$fileCount file${fileCount > 1 ? 's' : ''}'),
              for (var scope in imports.scopesOf(name))
                _Chip(label: scope.label),
              if (assets.isNotEmpty)
                _Chip(
                  label:
                      '${assets.length} asset${assets.length > 1 ? 's' : ''}',
                ),
              if (imports.isTestOnly(name) &&
                  widget.dependency.kind == DependencyKind.direct)
                _Chip(
                  label: 'test-only — could be a dev dependency',
                  tone: context.colors.amber,
                ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (assets.isNotEmpty) ...[
                Text(
                  references.isEmpty
                      // The whole point of reading the pubspec: a font or icon
                      // package is shipped without a line of Dart naming it,
                      // and the panel used to call that no usage at all.
                      ? 'Not imported, but shipped through pubspec.yaml:'
                      : 'Also shipped through pubspec.yaml:',
                  style: context.type.bodyMuted,
                ),
                const Gap(FwSpacing.xs),
                for (var asset in assets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: FwSpacing.xxs),
                    child: Row(
                      children: [
                        Icon(
                          asset.isFont ? Icons.text_fields : Icons.image,
                          size: FwIconSize.sm,
                          color: context.colors.mut3,
                        ),
                        const Gap(FwSpacing.xs),
                        Expanded(
                          child: Text(
                            asset.path,
                            style: context.type.body,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (references.isNotEmpty) const Gap(FwSpacing.md),
              ],
              if (byLibrary.length > 1) ...[
                Text(
                  'Libraries used: ${byLibrary.keys.sorted().join(', ')}',
                  style: context.type.bodyMuted,
                ),
                const Gap(FwSpacing.md),
              ],
              for (var reference in shown)
                Padding(
                  padding: const EdgeInsets.only(bottom: FwSpacing.xxs),
                  child: Row(
                    children: [
                      Icon(
                        reference.isExport ? Icons.output : Icons.arrow_forward,
                        size: FwIconSize.sm,
                        color: context.colors.mut3,
                      ),
                      const Gap(FwSpacing.xs),
                      Expanded(
                        child: Text(
                          reference.path,
                          style: context.type.body,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Without the condition the row is a lie: the file does
                      // not import this URI unconditionally, and two rows for
                      // the same file would otherwise look like a duplicate.
                      if (reference.condition case var condition?) ...[
                        Text(
                          'if ${condition.split('.').last} ',
                          style: context.type.caption.copyWith(
                            color: context.colors.mut3,
                          ),
                        ),
                      ],
                      Text(reference.uri, style: context.type.caption),
                    ],
                  ),
                ),
              if (references.length > shown.length)
                TextButton(
                  onPressed: () => setState(() => _expanded = true),
                  child: Text('Show ${references.length - shown.length} more'),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Platforms, SDKs and licence — all of it out of pub.dev's `tags` list.
class _CompatibilitySection extends StatelessWidget {
  final PubDevPackage pubDev;

  const _CompatibilitySection(this.pubDev);

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Compatibility',
      child: Column(
        children: [
          if (pubDev.platforms.isNotEmpty)
            _Row(
              label: 'Platforms',
              child: Wrap(
                spacing: FwSpacing.xs,
                runSpacing: FwSpacing.xs,
                children: [
                  for (var platform in pubDev.platforms) _Chip(label: platform),
                ],
              ),
            ),
          if (pubDev.sdks.isNotEmpty)
            _Row(label: 'SDK', child: Text(pubDev.sdks.join(', '))),
          if (pubDev.license case var license?)
            _Row(label: 'License', child: Text(license)),
          if (pubDev.topics.isNotEmpty)
            _Row(
              label: 'Topics',
              child: Wrap(
                spacing: FwSpacing.xs,
                runSpacing: FwSpacing.xs,
                children: [
                  for (var topic in pubDev.topics) _Chip(label: topic),
                ],
              ),
            ),
          _Row(
            label: 'WebAssembly',
            child: Text(pubDev.isWasmReady ? 'Ready' : 'Not ready'),
          ),
        ],
      ),
    );
  }
}

/// A markdown file from the package, collapsible.
///
/// The old version was a `FutureBuilder` with no error branch, so a package
/// whose changelog is `CHANGELOG` or `.txt` — or missing entirely — rendered as
/// a silent blank tab. This says which names it looked for.
class _DocumentSection extends StatefulWidget {
  final Dependency dependency;
  final String title;
  final List<String> candidates;
  final String? highlightVersion;
  final bool startCollapsed;

  const _DocumentSection({
    required this.dependency,
    required this.title,
    required this.candidates,
    this.highlightVersion,
    this.startCollapsed = false,
  });

  @override
  State<_DocumentSection> createState() => _DocumentSectionState();
}

class _DocumentSectionState extends State<_DocumentSection> {
  late Future<_Document> _document;
  late bool _open = !widget.startCollapsed;

  @override
  void initState() {
    super.initState();
    _document = _load();
  }

  Future<_Document> _load() async {
    if (widget.dependency.rootPath == null) {
      return const _Document.missing('the package is not on disk');
    }
    try {
      var found = await widget.dependency.document(widget.candidates);
      if (found == null) {
        return _Document.missing('looked for ${widget.candidates.join(', ')}');
      }
      return _Document(found.name, found.text);
    } catch (error) {
      return _Document.missing('could not be read: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: widget.title,
      trailing: TextButton(
        onPressed: () => setState(() => _open = !_open),
        child: Text(_open ? 'Hide' : 'Show'),
      ),
      child: !_open
          ? const SizedBox.shrink()
          : FutureBuilder<_Document>(
              future: _document,
              builder: (context, snapshot) {
                var document = snapshot.data;
                if (document == null) return const Text('…');
                if (document.reason case var reason?) {
                  return Text(
                    'No ${widget.title.toLowerCase()} — $reason.',
                    style: context.type.bodyMuted,
                  );
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: MarkdownBody(
                    data: _emphasised(document.content),
                    styleSheet: markdownStyleSheet(context),
                    onTapLink: (text, href, title) {
                      if (href != null) launchUrl(Uri.parse(href));
                    },
                  ),
                );
              },
            ),
    );
  }

  /// Trims a changelog to the entry for the version actually resolved, plus
  /// what came after it — which is the part you want when deciding whether to
  /// upgrade, and is otherwise buried in a thousand-line file.
  String _emphasised(String content) {
    var version = widget.highlightVersion;
    if (version == null) return content;
    var lines = content.split('\n');
    var index = lines.indexWhere(
      (line) => line.startsWith('#') && line.contains(version),
    );
    if (index < 0) return content;
    return [
      '> Showing from your resolved version, $version.',
      '',
      ...lines.take(index + 1),
      ...lines.skip(index + 1).takeWhile((line) => true),
    ].join('\n');
  }
}

class _Document {
  const _Document(this.name, this.content) : reason = null;
  const _Document.missing(this.reason) : name = null, content = '';

  final String? name;
  final String content;

  /// Why there is nothing to show, when there is nothing to show.
  final String? reason;
}

// ---------------------------------------------------------------------------
// Small shared pieces.
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final Widget child;

  const _Section({required this.title, this.trailing, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: context.type.sectionLabel)),
                ?trailing,
              ],
            ),
            const Gap(FwSpacing.md),
            child,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final Widget child;

  const _Row({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: context.type.bodyMuted),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color? tone;
  final IconData? icon;

  const _Chip({required this.label, this.tone, this.icon});

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var accent = tone;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: accent == null ? colors.panel2 : colors.statusFill(accent),
        border: Border.all(
          color: accent == null ? colors.line : colors.statusBorder(accent),
        ),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: FwIconSize.xs, color: accent ?? colors.mut),
            const Gap(FwSpacing.xxs),
          ],
          Text(
            label,
            style: context.type.micro.copyWith(color: accent ?? colors.mut),
          ),
        ],
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  final DependencyKind kind;

  const _KindChip(this.kind);

  @override
  Widget build(BuildContext context) {
    var (label, tone) = switch (kind) {
      DependencyKind.direct => ('Direct', context.colors.grn),
      DependencyKind.dev => ('Dev dependency', context.colors.amber),
      DependencyKind.transitive => ('Transitive', context.colors.mut),
    };
    return _Chip(label: label, tone: tone);
  }
}

class _OriginChip extends StatelessWidget {
  final PackageOrigin origin;

  const _OriginChip(this.origin);

  @override
  Widget build(BuildContext context) {
    if (origin is HostedOrigin && (origin as HostedOrigin).isPubDev) {
      return const SizedBox.shrink();
    }
    return _Chip(label: origin.detail ?? origin.label, icon: _icon);
  }

  IconData get _icon => switch (origin) {
    GitOrigin() => Icons.commit,
    PathOrigin() => Icons.folder_outlined,
    SdkOrigin() => Icons.flutter_dash,
    WorkspaceOrigin() => Icons.workspaces_outline,
    _ => Icons.help_outline,
  };
}

/// The origin spelled out — the git URL and the commit actually resolved, not
/// just the branch that was asked for.
class _OriginDetail extends StatelessWidget {
  final PackageOrigin origin;

  const _OriginDetail(this.origin);

  @override
  Widget build(BuildContext context) {
    return switch (origin) {
      GitOrigin git => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(git.url),
          if (git.shortRef case var ref?)
            Text(ref, style: context.type.bodyMuted),
          if (git.subPath case var path?)
            Text('in $path', style: context.type.bodyMuted),
        ],
      ),
      PathOrigin path => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(path.path),
          if (!path.relative)
            Text(
              'Absolute — this will not resolve on another machine.',
              style: context.type.bodyMuted.copyWith(color: context.colors.red),
            ),
        ],
      ),
      HostedOrigin hosted => Text(hosted.server),
      SdkOrigin sdk => Text('Ships with the ${sdk.sdk} SDK'),
      WorkspaceOrigin() => const Text('A member of this workspace'),
      UnknownOrigin unknown => Text('Unrecognised source: ${unknown.source}'),
    };
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;

  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    Widget tile = Container(
      width: 150,
      padding: const EdgeInsets.all(FwSpacing.lg),
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radii.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: FwIconSize.sm, color: colors.mut),
              const Gap(FwSpacing.xs),
              Expanded(
                child: Text(
                  label,
                  style: context.type.micro,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Gap(FwSpacing.xs),
          Text(value, style: context.type.heading),
        ],
      ),
    );
    if (tooltip != null) tile = Tooltip(message: tooltip!, child: tile);
    if (onTap != null) {
      tile = InkWell(
        borderRadius: BorderRadius.circular(context.radii.radius),
        onTap: onTap,
        child: tile,
      );
    }
    return tile;
  }
}

class _LinkButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _LinkButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: FwIconSize.md),
      label: Text(label),
    );
  }
}

/// "3 days ago", "2 years ago" — coarse on purpose; nobody needs the hour a
/// package was published.
String formatAge(DateTime date) {
  // Through `package:clock`, so a scenario of this page — the studio's own,
  // over a recording — reads the same age every day it runs.
  var days = clock.now().difference(date).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 30) return '$days days ago';
  if (days < 365) {
    var months = (days / 30).floor();
    return '$months month${months > 1 ? 's' : ''} ago';
  }
  var years = (days / 365).floor();
  return '$years year${years > 1 ? 's' : ''} ago';
}
