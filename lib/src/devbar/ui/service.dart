import 'dart:async';

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../../utils/value_stream.dart';
import '../devbar.dart';
import '../utils/dialog.dart';

enum DevbarButtonPosition { topRight, bottomRight }

class UiService {
  final devicePreview = ValueStream<bool>(false);
  final openState = ValueStream<OpenState?>(null);
  final buttons = ValueStream<List<DevbarButtonHandle>>([]);
  final tabs = ValueStream<List<DevbarTab>>([]);
  final wrappers = ValueStream<List<AppWrapper>>([]);
  final toasts = ValueStream<List<ToastHolder>>([]);
  final overlayVisible = ValueStream<int>(0);
  final overlayNavigatorKey = GlobalKey<NavigatorState>();

  final DevbarState service;
  OpenStateScale _scale = OpenStateScale.scales[1];

  UiService(this.service);

  Future<T?> showOverlayDialog<T>({
    required WidgetBuilder builder,
    bool? barrierDismissible,
  }) async {
    barrierDismissible ??= true;

    overlayVisible.add(overlayVisible.value + 1);
    var overlayState = overlayNavigatorKey.currentState!;
    var result = await overlayState.showDialog<T>(
      context: overlayState.context,
      builder: builder,
      barrierDismissible: barrierDismissible,
    );
    overlayVisible.add(overlayVisible.value - 1);
    return result;
  }

  void setDevicePreview(bool enabled) {
    devicePreview.add(enabled);
  }

  void close() {
    openState.add(null);
  }

  void open() {
    openState.add(OpenState(scale: _scale));
  }

  bool get nextScaleUp => _scale.nextScaleUp;

  void toggleScale() {
    _scale = _scale.next;
    openState.add(OpenState(scale: _scale));
  }

  DevbarButtonHandle addButton(
    Widget widget, {
    DevbarButtonPosition? position,
  }) {
    var button = DevbarButtonHandle(this, widget: widget, position: position);
    buttons.add(buttons.value..add(button));
    return button;
  }

  void removeButton(DevbarButtonHandle button) {
    buttons.value.remove(button);
    buttons.add(buttons.value);
  }

  DevbarTab addTab(Tab tab, Widget content, {List<String>? hierarchy}) {
    var devTab = DevbarTabWithContent(tab, content);

    if (hierarchy != null) {
      var parentNullable = tabs.value
          .whereType<DevbarTabWithSubTabs>()
          .firstWhereOrNull((t) => t.title == hierarchy.first);

      DevbarTabWithSubTabs parent;
      if (parentNullable == null) {
        parent = DevbarTabWithSubTabs(hierarchy.first);
        tabs.add([...tabs.value, parent]);
      } else {
        parent = parentNullable;
      }

      for (var i = 1; i < hierarchy.length; i++) {
        var title = hierarchy[i];
        var subTab = parent.tabs.value
            .whereType<DevbarTabWithSubTabs>()
            .firstWhereOrNull((t) => t.title == title);

        if (subTab == null) {
          subTab = DevbarTabWithSubTabs(title);
          parent.tabs.add([...parent.tabs.value, subTab]);
        }

        parent = subTab;
      }

      parent.tabs.add([...parent.tabs.value, devTab]);
    } else {
      tabs.add([...tabs.value, devTab]);
    }
    return devTab;
  }

  void removeTab(DevbarTab tab) {
    tabs.add(tabs.value..remove(tab));
  }

  void addWrapper(AppWrapper wrapper) {
    wrappers.add(wrappers.value..add(wrapper));
  }

  Timer? _toastTimer;
  void toast(Widget content, {Duration? duration, Alignment? alignment}) {
    duration ??= Duration(seconds: 3);

    var toast = ToastHolder(content, alignment: alignment);
    toasts.add([...toasts.value, toast]);
    _toastTimer = Timer(duration, () {
      toasts.value.remove(toast);
      toasts.add(toasts.value);
    });
  }

  void dispose() {
    devicePreview.dispose();
    openState.dispose();
    buttons.dispose();
    wrappers.dispose();
    toasts.dispose();
    overlayVisible.dispose();
    _toastTimer?.cancel();
  }
}

class OpenState {
  final OpenStateScale? scale;
  final Alignment alignment;

  OpenState({required this.scale, this.alignment = Alignment.bottomRight});
}

class OpenStateScale {
  static final scales = [
    OpenStateScale._(0.05),
    OpenStateScale._(0.25),
    OpenStateScale._(0.5),
  ];

  final double value;

  OpenStateScale._(this.value);

  OpenStateScale get next {
    var index = scales.indexOf(this);
    var nextIndex = index + 1;
    if (nextIndex == scales.length) {
      nextIndex = 0;
    }
    return scales[nextIndex];
  }

  bool get nextScaleUp => next.value > value;
}

class DevbarButtonHandle {
  final _refreshController = StreamController<void>.broadcast();
  final UiService service;
  Widget widget;
  final DevbarButtonPosition position;

  DevbarButtonHandle(
    this.service, {
    required this.widget,
    DevbarButtonPosition? position,
  }) : position = position ?? DevbarButtonPosition.topRight;

  Stream<void> get refreshStream => _refreshController.stream;

  void remove() {
    _refreshController.close();
    service.removeButton(this);
  }

  void refresh(Widget widget) {
    this.widget = widget;
    _refreshController.add(null);
  }
}

class ToastHolder {
  final Widget content;
  final Alignment alignment;

  ToastHolder(this.content, {Alignment? alignment})
    : alignment = alignment ?? Alignment.bottomCenter;
}

sealed class DevbarTab {}

class DevbarTabWithContent implements DevbarTab {
  final Tab tab;
  final Widget content;

  DevbarTabWithContent(this.tab, this.content);
}

class DevbarTabWithSubTabs implements DevbarTab {
  final String title;
  final tabs = ValueStream<List<DevbarTab>>([]);

  DevbarTabWithSubTabs(this.title);

  void dispose() {
    tabs.dispose();
  }
}

typedef AppWrapper = Widget Function({required Widget child});
