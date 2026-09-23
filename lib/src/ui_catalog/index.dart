import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../third_party/device_frame/lib/device_frame.dart';
import 'app.dart';
import 'form_factor.dart';
import 'treeview.dart';

class IndexView extends StatelessWidget {
  final List<TreeEntry> children;
  final void Function(TreeEntry) onSelect;
  final bool isRoot;
  final FormFactorPicker? formFactorPicker;

  const IndexView(
    this.children, {
    super.key,
    required this.onSelect,
    required this.isRoot,
    required this.formFactorPicker,
  });

  @override
  Widget build(BuildContext context) {
    var leafs = children.where((e) => e.isLeaf);
    var folders = children.where((e) => !e.isLeaf);

    var widgets = <Widget>[
      GridView.count(
        padding: const EdgeInsets.all(20),
        crossAxisCount: 5,
        mainAxisSpacing: 30,
        crossAxisSpacing: 30,
        shrinkWrap: true,
        physics: NeverScrollableScrollPhysics(),
        children: [
          for (var child in leafs)
            _IndexPreview(
              child,
              child.value,
              onTap: () {
                onSelect(child);
              },
              formFactor: formFactorPicker?.call(child.path) ?? FormFactor.all,
            ),
        ],
      ),
      for (var folder in folders)
        _Folder(
          title: folder.title,
          onSelect: () => onSelect(folder),
          child: IndexView(
            folder.children!,
            onSelect: onSelect,
            isRoot: false,
            formFactorPicker: formFactorPicker,
          ),
        ),
    ];

    if (isRoot) {
      return FittedWidget(
        minimumSize: Size(600, 100),
        child: ListView(children: widgets),
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: widgets,
      );
    }
  }
}

class _IndexPreview extends StatelessWidget {
  final TreeEntry entry;
  final dynamic value;
  final VoidCallback onTap;
  final FormFactor formFactor;

  _IndexPreview(
    this.entry,
    this.value, {
    required this.onTap,
    required this.formFactor,
  });

  @override
  Widget build(BuildContext context) {
    var value = this.value;
    Widget mainWidget;
    if (value is Widget) {
      var widget = Center(child: value);
      mainWidget = DeviceFrame(
        device: switch (formFactor) {
          FormFactor.mobile => Devices.android.smallPhone,
          FormFactor.all => Devices.android.smallPhone,
          FormFactor.desktop => Devices.windows.laptop,
        },
        screen: widget,
        isFrameVisible: false,
      );
    } else {
      mainWidget = Center(
        child: Text('Entry is not a widget. Type: ${value.runtimeType}'),
      );
    }
    return InkWell(
      onTap: onTap,
      focusColor: Colors.transparent,
      child: AbsorbPointer(
        child: AspectRatio(
          aspectRatio: 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Material(
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(color: Colors.black12, width: 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: 200, maxWidth: 200),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: mainWidget,
                      ),
                    ),
                  ),
                ),
              ),
              Text(
                entry.title,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Folder extends StatelessWidget {
  final Widget child;
  final String title;
  final VoidCallback onSelect;

  const _Folder({
    required this.title,
    required this.child,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 30, left: 20, right: 20),
      decoration: BoxDecoration(
        color: folderColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: folderColor.withValues(alpha: 0.5), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onSelect,
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class FittedWidget extends StatelessWidget {
  final Widget child;
  final Size minimumSize;

  const FittedWidget({
    super.key,
    required this.child,
    required this.minimumSize,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var size = constraints.biggest;
        var widthRatio = size.width / minimumSize.width;
        var heightRatio = size.height / minimumSize.height;

        var width = size.width;
        var height = size.height;

        if (min(widthRatio, heightRatio) < 1) {
          if (widthRatio < heightRatio) {
            width = minimumSize.width;
            height = size.height / widthRatio;
          } else {
            height = minimumSize.height;
            width = size.width / heightRatio;
          }
        }

        return FittedBox(
          child: SizedBox(width: width, height: height, child: child),
        );
      },
    );
  }
}
