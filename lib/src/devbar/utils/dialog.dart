import 'package:material_ui/material_ui.dart';

extension NavigatorExtension on NavigatorState {
  Future<T?> showDialog<T>({
    required BuildContext context,
    bool barrierDismissible = true,
    required WidgetBuilder builder,
    bool useRootNavigator = true,
  }) {
    assert(debugCheckHasMaterialLocalizations(context));

    final theme = Theme.of(context);
    return showGeneralDialog(
      context: context,
      pageBuilder:
          (
            BuildContext buildContext,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) {
            final Widget pageChild = Builder(builder: builder);
            return SafeArea(
              child: Builder(
                builder: (BuildContext context) {
                  return Theme(data: theme, child: pageChild);
                },
              ),
            );
          },
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 150),
      transitionBuilder: _buildMaterialDialogTransitions,
      useRootNavigator: useRootNavigator,
    );
  }

  Future<T?> showGeneralDialog<T>({
    required BuildContext context,
    required RoutePageBuilder pageBuilder,
    bool barrierDismissible = true,
    String? barrierLabel,
    Color? barrierColor,
    Duration? transitionDuration,
    RouteTransitionsBuilder? transitionBuilder,
    bool useRootNavigator = true,
  }) {
    assert(!barrierDismissible || barrierLabel != null);
    return push<T>(
      _DialogRoute<T>(
        pageBuilder: pageBuilder,
        barrierDismissible: barrierDismissible,
        barrierLabel: barrierLabel,
        barrierColor: barrierColor,
        transitionDuration: transitionDuration,
        transitionBuilder: transitionBuilder,
      ),
    );
  }
}

class _DialogRoute<T> extends PopupRoute<T> {
  _DialogRoute({
    required this._pageBuilder,
    this._barrierDismissible = true,
    this._barrierLabel,
    Color? barrierColor,
    Duration? transitionDuration,
    this._transitionBuilder,
    super.settings,
  }) : _barrierColor = barrierColor ?? const Color(0x80000000),
       _transitionDuration =
           transitionDuration ?? const Duration(milliseconds: 200);

  final RoutePageBuilder _pageBuilder;

  @override
  bool get barrierDismissible => _barrierDismissible;
  final bool _barrierDismissible;

  @override
  String? get barrierLabel => _barrierLabel;
  final String? _barrierLabel;

  @override
  Color get barrierColor => _barrierColor;
  final Color _barrierColor;

  @override
  Duration get transitionDuration => _transitionDuration;
  final Duration _transitionDuration;

  final RouteTransitionsBuilder? _transitionBuilder;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: _pageBuilder(context, animation, secondaryAnimation),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    var transitionBuilder = _transitionBuilder;
    if (transitionBuilder == null) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.linear),
        child: child,
      );
    } // Some default transition
    return transitionBuilder(context, animation, secondaryAnimation, child);
  }
}

Widget _buildMaterialDialogTransitions(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  );
}
