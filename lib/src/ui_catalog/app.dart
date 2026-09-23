import 'dart:core' as core;
import 'dart:core';

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../third_party/device_frame/lib/device_frame.dart';
import 'default_device_list.dart';
import 'form_factor.dart';
import 'knobs.dart';
import 'detail.dart';
import 'device_choice_panel.dart';
import 'figma/provider.dart';
import 'figma/service.dart';
import 'index.dart';
import 'search.dart';
import 'treeview.dart';
import 'ui_catalog.dart';

const _menuBackground = Color(0xfff7f9fc);

typedef FormFactorPicker = FormFactor? Function(String);

class UICatalog extends StatefulWidget {
  final String title;
  final Map<String, dynamic> Function() catalog;
  final Widget Function(BuildContext, Widget) appBuilder;
  final FigmaUserConfig figmaConfig;
  final FormFactorPicker? formFactor;

  UICatalog({
    super.key,
    required this.title,
    required this.catalog,
    required this.appBuilder,
    String? figmaApiToken,
    String? figmaLinksPath,
    this.formFactor,
  }) : figmaConfig = FigmaUserConfig(
         apiToken: figmaApiToken,
         linksPath: figmaLinksPath,
       );

  @override
  State<UICatalog> createState() => UICatalogAppState();

  static UICatalog of(BuildContext context) =>
      context.findAncestorWidgetOfExactType<UICatalog>()!;
}

class UICatalogAppState extends State<UICatalog> {
  DeviceChoice mobileDevice = DeviceChoice(
    isEnabled: true,
    useMosaic: false,
    availableDevices: defaultMobileDevices,
    single: SingleDeviceChoice(
      device: Devices.ios.iPhoneSE,
      orientation: Orientation.portrait,
      showFrame: true,
    ),
    mosaic: MosaicDeviceChoice(
      devices: defaultMobileDevices.keys.toSet(),
      orientations: Orientation.values.toSet(),
    ),
  );
  DeviceChoice desktopDevice = DeviceChoice(
    isEnabled: false,
    useMosaic: false,
    availableDevices: defaultDesktopDevices,
    single: SingleDeviceChoice(
      device: Devices.macOS.macBookPro,
      orientation: Orientation.landscape,
      showFrame: true,
    ),
    mosaic: MosaicDeviceChoice(
      devices: defaultDesktopDevices.keys.toSet(),
      orientations: {Orientation.landscape},
    ),
  );
  String? _selected;

  DeviceChoice deviceForEntry(TreeEntry entry) {
    var formFactor = widget.formFactor?.call(entry.path) ?? FormFactor.all;
    return switch (formFactor) {
      FormFactor.mobile => mobileDevice,
      FormFactor.all => mobileDevice,
      FormFactor.desktop => desktopDevice,
    };
  }

  void setDeviceForEntry(TreeEntry entry, DeviceChoice choice) {
    var formFactor = widget.formFactor?.call(entry.path) ?? FormFactor.all;
    switch (formFactor) {
      case FormFactor.mobile:
        mobileDevice = choice;
      case FormFactor.all:
        mobileDevice = choice;
      case FormFactor.desktop:
        desktopDevice = choice;
    }
  }

  @override
  Widget build(BuildContext context) {
    var allCatalog = widget.catalog();
    var entries = _mapToEntries(allCatalog);
    TreeEntry? selected;
    if (_selected case var selectedPath?) {
      selected = _flatEntries(entries)
          .firstWhereOrNull((e) => e.path == selectedPath);
    } else {
      selected = TreeEntry(null, MapEntry('', allCatalog));
    }

    return MaterialApp(
      color: Colors.red,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(useMaterial3: true),
      home: Scaffold(
        body: FigmaProvider(
          userConfig: widget.figmaConfig,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Menu(
                title: widget.title,
                entries: entries,
                selected: selected,
                onSelect: (e) {
                  setState(() {
                    _selected = e?.path;
                  });
                },
              ),
              Expanded(
                child: selected == null
                    ? SizedBox()
                    : _detailOrListing(selected),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailOrListing(TreeEntry entry) {
    var value = entry.value;
    if (value != null) {
      return DetailView(
        entry,
        value,
        onSelect: (e) {
          setState(() {
            _selected = e.path;
          });
        },
        appState: this,
        key: Key(entry.path),
      );
    } else {
      var scaffold = Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 10),
              child: entry.isRoot
                  ? Text(
                      widget.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    )
                  : Breadcrumb(
                      entry,
                      onSelect: (e) {
                        setState(() {
                          _selected = e.path;
                        });
                      },
                    ),
            ),
            Expanded(
              child: IndexView(
                isRoot: true,
                entry.children ?? [],
                formFactorPicker: widget.formFactor,
                onSelect: (e) {
                  setState(() {
                    _selected = e.path;
                  });
                },
              ),
            ),
          ],
        ),
      );
      return KnobsProvider(
        knobs: Knobs.unanswered,
        child: Builder(
          builder: (context) {
            return widget.appBuilder(context, scaffold);
          },
        ),
      );
    }
  }

  static List<TreeEntry> _mapToEntries(Map<String, dynamic> map) {
    return map.entries.map((e) => TreeEntry(null, e)).toList();
  }

  static Iterable<TreeEntry> _flatEntries(List<TreeEntry> roots) sync* {
    for (var root in roots) {
      yield root;
      yield* root.descendants;
    }
  }
}

class Menu extends StatefulWidget {
  final String title;
  final List<TreeEntry> entries;
  final TreeEntry? selected;
  final void Function(TreeEntry?) onSelect;

  const Menu({
    super.key,
    required this.entries,
    required this.title,
    this.selected,
    required this.onSelect,
  });

  @override
  State<Menu> createState() => _MenuState();
}

class _MenuState extends State<Menu> {
  final _treeView = GlobalKey<TreeViewState>();
  String? _search;

  @override
  Widget build(BuildContext context) {
    Widget results;
    var adapter = TreeEntryAdapter<TreeEntry>(
      children: (e) => e.children,
      title: (e) => e.title,
      ancestors: (e) => e.parent?.breadcrumb ?? [],
    );
    if (_search case var search?) {
      results = SearchResults(
        query: search,
        entries: widget.entries,
        onSelected: widget.onSelect,
        selected: widget.selected,
        adapter: adapter,
        breadcrumbBuilder: (e) {
          return _SearchBreadcrumb(e);
        },
      );
    } else {
      results = TreeView<TreeEntry>(
        key: _treeView,
        entries: widget.entries,
        onSelected: widget.onSelect,
        selected: widget.selected,
        adapter: adapter,
      );
    }

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: _menuBackground,
        border: Border(right: BorderSide(color: Color(0xffe4e5e8), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 15),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () {
                      widget.onSelect(null);
                    },
                    child: Text(
                      widget.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                _SettingsButton(
                  onExpandAll: () {
                    _treeView.currentState!.expandAll();
                  },
                  onCollapseAll: () {
                    _treeView.currentState!.collapseAll();
                  },
                ),
              ],
            ),
          ),
          _SearchField(
            onSearch: (q) {
              setState(() {
                _search = q;
              });
            },
          ),
          Expanded(child: results),
        ],
      ),
    );
  }
}

class _SettingsButton extends StatelessWidget {
  final void Function() onExpandAll;
  final void Function() onCollapseAll;

  const _SettingsButton({
    required this.onExpandAll,
    required this.onCollapseAll,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton(
      icon: Icon(Icons.settings_outlined, color: Colors.black38),
      iconSize: 15,
      itemBuilder: (c) => [
        PopupMenuItem(onTap: onExpandAll, child: Text('Expand all')),
        PopupMenuItem(onTap: onCollapseAll, child: Text('Collapse all')),
      ],
    );
  }
}

class _SearchField extends StatefulWidget {
  final void Function(String?) onSearch;

  const _SearchField({required this.onSearch});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _textController = TextEditingController();

  @override
  void initState() {
    super.initState();

    _textController.addListener(_search);
  }

  void _search() {
    var query = _textController.text.trim();
    widget.onSearch(query.isEmpty ? null : query);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
      child: TextField(
        controller: _textController,
        decoration: InputDecoration(
          hintText: 'Filter',
          prefixIcon: Icon(Icons.search),
          prefixIconConstraints: BoxConstraints(minHeight: 40, minWidth: 40),
          suffixIconConstraints: BoxConstraints(),
          suffixIcon: _textController.text.isNotEmpty
              ? SizedBox(
                  height: 30,
                  child: IconButton(
                    onPressed: () {
                      setState(() {
                        _textController.clear();
                      });
                      FocusScope.of(context).unfocus();
                    },
                    icon: Icon(Icons.clear),
                    padding: EdgeInsets.zero,
                  ),
                )
              : null,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
          contentPadding: EdgeInsets.zero,
          isDense: true,
        ),
        style: const TextStyle(fontSize: 13),
        onChanged: (v) {
          setState(() {
            // Update suffix
          });
        },
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }
}

class _SearchBreadcrumb extends StatelessWidget {
  final TreeEntry entry;

  const _SearchBreadcrumb(this.entry);

  @override
  Widget build(BuildContext context) {
    var breadcrumb = entry.parent?.breadcrumb ?? [];
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var e in breadcrumb) ...[
          Text(e.title, style: const TextStyle(fontSize: 12)),
          if (e != breadcrumb.last) Icon(Icons.arrow_right, size: 10),
        ],
      ],
    );
  }
}

class TreeEntry {
  final TreeEntry? parent;
  final MapEntry<String, dynamic> entry;
  late final List<TreeEntry> breadcrumb = <TreeEntry>[
    ...?parent?.breadcrumb,
    this,
  ];

  TreeEntry(this.parent, this.entry);

  bool get isRoot => entry.key.isEmpty;

  String get title => entry.key;

  String get path => breadcrumb
      .where((e) => e.entry.key.isNotEmpty)
      .map((e) => e.entry.key)
      .join('/');

  Object? get value {
    var mapValue = entry.value;
    if (mapValue is Map) {
      return null;
    }
    return mapValue;
  }

  bool get isLeaf => entry.value is! Map;

  List<TreeEntry>? get children {
    var mapValue = entry.value;
    if (mapValue is Map) {
      return mapValue.entries
          .map((e) => TreeEntry(this, MapEntry('${e.key}', e.value)))
          .toList();
    }
    return null;
  }

  Iterable<TreeEntry> get descendants sync* {
    if (children == null) return;
    for (var child in children!) {
      yield child;
      yield* child.descendants;
    }
  }

  @override
  bool operator ==(other) => other is TreeEntry && other.path == path;

  @override
  int get hashCode => path.hashCode;
}
