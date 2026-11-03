import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../drive/navigator.dart';
import '../utils/value_stream.dart';
import 'path.dart';
import 'provider.dart';
import 'url_source.dart';

class RouterRoot extends StatefulWidget {
  final UrlSource urlSource;
  final Widget child;

  const RouterRoot({super.key, required this.urlSource, required this.child});

  @override
  State<RouterRoot> createState() => _RouterRootState();

  static UrlSource sourceOf(BuildContext context) {
    return context
        .findAncestorStateOfType<_RouterRootState>()!
        .widget
        .urlSource;
  }

  static UrlSource? maybeSourceOf(BuildContext context) {
    return context
        .findAncestorStateOfType<_RouterRootState>()
        ?.widget
        .urlSource;
  }
}

class _RouterRootState extends State<RouterRoot> with WidgetsBindingObserver {
  /// The `navigate` handler this root installed. The slot is one global, so
  /// this is what says whether the handler standing there is still ours.
  void Function(String route)? _navigator;

  @override
  void initState() {
    super.initState();
    _registerNavigator();
    WidgetsBinding.instance.addObserver(this);
  }

  /// A deep link the platform opens the app on, the way a phone hands one
  /// over: its path and query go to the source. On the web the source follows
  /// the browser's address itself, so the push is left to it.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    if (kIsWeb) return SynchronousFuture(false);
    var uri = routeInformation.uri;
    var route = Uri(
      path: uri.path.isEmpty ? '/' : uri.path,
      query: uri.hasQuery ? uri.query : null,
    ).toString();
    widget.urlSource.go(PagePath(route, isAbsolute: true));
    return SynchronousFuture(true);
  }

  @override
  void didUpdateWidget(RouterRoot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.urlSource != widget.urlSource) _registerNavigator();
  }

  /// Gives the drive layer's `navigate` verb a handler, so an app on this
  /// router is driven to a screen by its path without registering anything.
  /// The route is the path the URL carries, query string included.
  void _registerNavigator() {
    _navigator = driveNavigator = (route) {
      widget.urlSource.go(PagePath(route, isAbsolute: true));
    };
  }

  /// Clears the slot only if the handler is still ours. Flutter builds a
  /// subtree's replacement before retiring the old one, so a rebuild that
  /// moves this root runs the new root's `initState` and then this `dispose`;
  /// clearing unconditionally would throw away the registration the new root
  /// had just made.
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(driveNavigator, _navigator)) driveNavigator = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PagePath>(
      stream: widget.urlSource.onChange,
      initialData: widget.urlSource.current,
      builder: (context, snapshot) {
        return MatchedPathProvider(
          path: snapshot.requireData.rootMatch,
          child: SubMatchTracker(child: widget.child),
        );
      },
    );
  }
}

class SubMatchTracker extends StatefulWidget {
  final Widget child;

  const SubMatchTracker({super.key, required this.child});

  @override
  SubMatchTrackerState createState() => SubMatchTrackerState();

  static SubMatchTrackerState of(BuildContext context) {
    return context.findAncestorStateOfType<SubMatchTrackerState>()!;
  }
}

class SubMatchTrackerState extends State<SubMatchTracker> {
  final allMatches = ValueStream<List<MatchedPath>>([]);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MatchedPath>>(
      stream: allMatches.stream,
      initialData: allMatches.value,
      builder: (context, snapshot) {
        return SubMatches(
          allMatches: snapshot.requireData,
          child: widget.child,
        );
      },
    );
  }

  void addSubMatch(MatchedPath path) {
    if (!allMatches.value.contains(path)) {
      allMatches.add(allMatches.value..add(path));
    }
  }

  void removeSubMatch(MatchedPath? path) {
    if (path != null) {
      allMatches.add(allMatches.value..remove(path));
    }
  }

  @override
  void dispose() {
    allMatches.dispose();
    super.dispose();
  }
}

class SubMatches extends InheritedWidget {
  final List<MatchedPath> allMatches;

  const SubMatches({super.key, required super.child, required this.allMatches});

  static List<MatchedPath> of(BuildContext context) {
    final result = context.dependOnInheritedWidgetOfExactType<SubMatches>()!;
    return result.allMatches;
  }

  @override
  bool updateShouldNotify(SubMatches oldWidget) {
    return true;
  }
}

class RouterRootAuto extends StatefulWidget {
  final Widget child;

  const RouterRootAuto({super.key, required this.child});

  @override
  State<RouterRootAuto> createState() => _RouterRootAuto();
}

class _RouterRootAuto extends State<RouterRootAuto> {
  final _urlSource = UrlSource.defaultFactory();

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return RouterRoot(urlSource: _urlSource, child: widget.child);
  }

  @override
  void dispose() {
    _urlSource.dispose();
    super.dispose();
  }
}
