/// What the demo app's `tool/stack.dart` prints, for each verb the dev stack
/// declaration sends it, in each state the stack can be in.
///
/// Raw process output on purpose: the recording is what a spawned script
/// would have written to stdout, and the core reads it through the same
/// parser it reads a live script with — a probe's JSON, a command's tail.
library;

import 'dart:convert';

const stackPort = 8090;
const stackBase = 'http://localhost:$stackPort';

Map<String, Object?> recordedStackAnswers() {
  Map<String, Object?> printed(String stdout, {int exitCode = 0}) => {
    'exitCode': exitCode,
    'stdout': stdout,
    'stderr': '',
  };
  return {
    'status@up': printed(
      '${jsonEncode({
        'state': 'up',
        'detail': 'localhost:$stackPort',
        'services': [
          {'name': 'http', 'port': stackPort, 'state': 'up'},
        ],
      })}\n',
    ),
    'status@down': printed(
      '${jsonEncode({'state': 'down', 'detail': 'nothing listening on :$stackPort'})}\n',
    ),
    'up': printed('Orders server up on $stackBase (pid 4242).\n'),
    'down': printed('Orders server stopped (pid 4242).\n'),
    'logs': printed('${_logs.join('\n')}\n'),
    'hit': printed(
      '200 $stackBase/menu\n'
      '${jsonEncode({
        'drinks': [
          {'id': 'cappuccino', 'name': 'Cappuccino', 'price': 4.2},
          {'id': 'flat-white', 'name': 'Flat white', 'price': 4.6},
          {'id': 'matcha', 'name': 'Matcha latte', 'price': 5.1},
          {'id': 'chai', 'name': 'Chai latte', 'price': 4.8},
          {'id': 'cold-brew', 'name': 'Cold brew', 'price': 3.9},
        ],
      })}\n',
    ),
  };
}

/// The last forty lines the server logged — `package:logging` records, as
/// the server writes them through to its log file.
const _logs = [
  '[INFO] brewline: listening on http://localhost:8090',
  '[FINE] brewline.menu: menu served, 5 drinks',
  '[INFO] brewline.orders: order BL-1038 placed, 2 drinks, ready in 5 min',
  '[FINE] brewline.menu: menu served, 5 drinks',
  '[INFO] brewline.orders: order BL-1039 placed, 1 drink, ready in 4 min',
  '[INFO] brewline.orders: order BL-1040 placed, 1 drink, ready in 4 min',
  '[FINE] brewline.menu: menu served, 5 drinks',
  '[INFO] brewline.orders: order BL-1041 placed, 3 drinks, ready in 6 min',
  '[FINE] brewline.menu: menu served, 5 drinks',
  '[INFO] brewline.orders: order BL-1042 placed, 1 drink, ready in 4 min',
  '[WARNING] brewline.orders: listing 5 orders took 41ms',
  '[WARNING] brewline.reports: daily report took 1.5s; no index on placed_at',
  '[SEVERE] brewline.orders: order refused: unknown drink espresso',
  '[FINE] brewline.menu: menu served, 5 drinks',
];
