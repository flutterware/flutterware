import 'package:material_ui/material_ui.dart';

import 'extensions.dart';
import 'loading_page.dart';
import 'path.dart';
import 'provider.dart';
import 'router_root.dart';

typedef RouteBuilder = Widget Function(MatchedPath);

class RouterOutlet extends StatefulWidget {
  final Map<String, RouteBuilder> routes;
  final String? Function(OnNotFoundEvent)? onNotFound;

  const RouterOutlet(this.routes, {super.key, this.onNotFound});

  static Widget root({required Widget child}) {
    return Builder(
      builder: (context) {
        var source = RouterRoot.maybeSourceOf(context);
        if (source == null) {
          return RouterRootAuto(child: child);
        } else {
          return child;
        }
      },
    );
  }

  @override
  State<RouterOutlet> createState() => _RouterOutletState();

  static State<RouterOutlet>? parentOf(BuildContext context) {
    return context.findAncestorStateOfType<_RouterOutletState>();
  }
}

class _RouterOutletState extends State<RouterOutlet> {
  final _entries = <_RouteEntry>[];
  SubMatchTrackerState? _tracker;
  MatchedPath? _lastMatched;

  @override
  void initState() {
    super.initState();
    _setupEntries();
  }

  @override
  void didUpdateWidget(covariant RouterOutlet oldWidget) {
    super.didUpdateWidget(oldWidget);
    _setupEntries();
  }

  void _setupEntries() {
    _entries.clear();

    for (var route in widget.routes.entries) {
      _entries.add(_RouteEntry(PathPattern(route.key), route.value));
    }
    _entries.sort((a, b) => b.pattern.length.compareTo(a.pattern.length));
  }

  @override
  Widget build(BuildContext context) {
    var tracker = _tracker = SubMatchTracker.of(context);
    var parentPath = MatchedPathProvider.of(context);

    Exception? error;

    try {
      for (var routeEntry in _entries) {
        var matched = parentPath.matchesRemaining(routeEntry.pattern);
        if (matched != null) {
          var widget = routeEntry.builder(matched);
          if (matched != _lastMatched) {
            tracker.removeSubMatch(_lastMatched);
            tracker.addSubMatch(matched);
            _lastMatched = matched;
          }
          // Key the subtree by the matched segments so a change in a path
          // argument (`detail/15` -> `detail/14`) tears down the old State
          // instead of silently reusing it. Query parameters and extra don't
          // affect the key.
          return MatchedPathProvider(
            path: matched,
            child: KeyedSubtree(
              key: ValueKey(matched.matched.toString()),
              child: widget,
            ),
          );
        }
      }
    } on Exception catch (e, stackTrace) {
      debugPrint(
        'Fail to build widget for route $parentPath:\n$e\n$stackTrace',
      );
      error = e;
    }
    tracker.removeSubMatch(_lastMatched);
    _lastMatched = null;

    var redirect = widget.onNotFound?.call(
      OnNotFoundEvent(parentPath, error: error),
    );
    if (redirect != null) {
      context.go(redirect);
    } else {
      // TODO: Up the chain to call onNotFound. If nothing found, back to
      // the root (and take the first path)
    }

    //TODO: allow to customize (provide a builder at root) + provide a builder
    // in outlet
    // TODO: allow _RouteBuilder to return a FutureOr<Widget> and return
    // a RouteLoader() which handle the LoadingState & ErrorState
    // => Maybe just easier to provide it as a utility class to return in the builder
    // itself
    return const LoadingPage();
  }

  @override
  void dispose() {
    _tracker?.removeSubMatch(_lastMatched);
    super.dispose();
  }
}

class OnNotFoundEvent {
  final MatchedPath path;
  final Exception? error;

  OnNotFoundEvent(this.path, {this.error});
}

class _RouteEntry {
  final PathPattern pattern;
  final RouteBuilder builder;

  _RouteEntry(this.pattern, this.builder);

  @override
  String toString() => '_RouteEntry($pattern)';
}
