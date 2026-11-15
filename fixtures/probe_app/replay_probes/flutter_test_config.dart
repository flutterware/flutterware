import 'dart:async';

import 'package:flutterware/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain);
