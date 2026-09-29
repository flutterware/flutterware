import 'dart:async';
import 'dart:math';

import 'package:flutterware/server.dart';

import 'edges.dart';
import 'orders.dart';

/// The kitchen: what a busy shop has that the counter alone does not. Every
/// order placed queues a brew job, and one barista works the queue in
/// order — a job marks itself running, moves its order to preparing, brews
/// for a moment, moves it to ready, stamps the customer's loyalty card and,
/// every fifth stamp, gives them a free coffee.
///
/// A queue in the shape real ones have: the job is picked up by a worker
/// that has nothing to do with the request that queued it, so the step that
/// caused it travels with the job ([FlutterwareServer.step]) and the worker
/// runs under it again ([FlutterwareServer.job]). Its own rows — the jobs
/// table — are plumbing, in a layer of their own.
class Kitchen {
  Kitchen({required this.advance, required this.push});

  /// Moves an order to a status, as the shop moves any: stored, reported,
  /// told to the apps, pushed when ready.
  final Future<void> Function(String order, String status) advance;
  final PushService push;

  final _queue = <_Job>[];
  final _stamps = <String, int>{};
  final _random = Random();
  Timer? _worker;
  var _next = 1;
  var _brewing = false;

  /// Starts the barista. Called where the server starts, outside any
  /// request: what the worker does, it does on no step of its own.
  void start() => _worker ??= Timer.periodic(
    const Duration(milliseconds: 250),
    (_) => unawaited(_poll()),
  );

  Future<void> close() async {
    _worker?.cancel();
    _worker = null;
  }

  /// Queues [order], keeping the step of the request that placed it.
  void queue(Order order) {
    var job = _Job(
      id: 'brew-${_next++}',
      order: order.id,
      customer: order.customerId,
      item: order.item,
      step: FlutterwareServer.step,
      due: DateTime.now().add(
        Duration(milliseconds: 400 + _random.nextInt(1200)),
      ),
    );
    _queue.add(job);
    _report(job, 'insert', 'queued');
  }

  /// One barista: the next job that is due, when not already brewing.
  Future<void> _poll() async {
    if (_brewing) return;
    var now = DateTime.now();
    var due = _queue.where((job) => !job.due.isAfter(now)).firstOrNull;
    if (due == null) return;
    _queue.remove(due);
    _brewing = true;
    try {
      await FlutterwareServer.job(
        'brew',
        () => _brew(due),
        step: due.step,
        id: due.id,
        queue: 'jobs',
      );
    } on Object {
      // Reported by the job's own end; the barista takes the next one.
    } finally {
      _brewing = false;
    }
  }

  Future<void> _brew(_Job job) async {
    _report(job, 'update', 'running');
    await advance(job.order, 'preparing');
    await Future<void>.delayed(
      Duration(milliseconds: 500 + _random.nextInt(900)),
    );
    await advance(job.order, 'ready');
    var stamps = (_stamps[job.customer] ?? 0) + 1;
    _stamps[job.customer] = stamps;
    FlutterwareServer.event('write', {
      'table': 'stamps',
      'key': job.customer,
      'op': stamps == 1 ? 'insert' : 'update',
      'stamps': stamps,
      'customer': job.customer,
    });
    if (stamps % 5 == 0) {
      FlutterwareServer.event('write', {
        'table': 'rewards',
        'key': '${job.customer}-${stamps ~/ 5}',
        'op': 'insert',
        'reward': 'free coffee',
        'customer': job.customer,
      });
      await push.send(
        job.customer,
        title: 'A free coffee',
        body: 'Five stamps: the next one is on us.',
        link: 'worldlab://orders',
      );
    }
    _report(job, 'update', 'done');
  }

  void _report(_Job job, String op, String status) =>
      FlutterwareServer.event('write', {
        'table': 'jobs',
        'key': job.id,
        'op': op,
        'status': status,
        'kind': 'brew ${job.item.toLowerCase()}',
        'layer': 'jobs',
      });
}

class _Job {
  _Job({
    required this.id,
    required this.order,
    required this.customer,
    required this.item,
    required this.step,
    required this.due,
  });

  final String id;
  final String order;
  final String customer;
  final String item;

  /// The step of the request that placed the order, which the job runs
  /// under.
  final String? step;
  final DateTime due;
}
