# Dev stack

The services your app needs while you work (a database, Docker containers, a
local API server), each with its state and a start and stop button. You, the
command line and a coding agent all drive the same list, and the studio shows
who started and stopped what.

![The dev stack panel: the demo's orders server, up, and the log its command
printed](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.7.0/dev-stack.webp)

## Turn it on

```dart
// tool/flutterware.dart
fw.use(
  DevStack(
    services: [
      StackService.delegated(
        'db',
        name: 'Database',
        probe: Probe.exitCode(
          StackRun.command([
            'sh',
            '-c',
            r'test -n "$(docker compose ps --quiet --status running)"',
          ]),
        ),
        start: StackRun.command(['docker', 'compose', 'up', '--wait']),
        stop: StackRun.command(['docker', 'compose', 'down']),
      ),
      StackService.owned(
        'server',
        name: 'API server',
        workingDirectory: 'packages/server',
        needs: ['db'],
        start: StackRun.script('bin/server.dart'),
        ready: Ready.http(8080, path: '/health', timeout: Duration(seconds: 30)),
      ),
    ],
  ),
);
```

Each service has an `id`, used in its action names and in `needs`, and an
optional `name` for the panel. Commands run from the root of the checkout
unless you set `workingDirectory:`.

For a single service started by your own commands, `DevStack.background(...)`
is a shorter way to write the same thing.

## Two kinds of service

**`StackService.delegated`** is for something your own commands start and stop,
where the start command returns and leaves it running: `docker compose up`,
your project's own CLI. flutterware runs `probe` to find out whether it's up,
and `start` and `stop` when you press **Bring up** and **Tear down**. Leave
`start` and `stop` out for a service you only watch, like a shared server. Make
`start` wait until the service is ready (`docker compose up --wait`), so what
comes next can use it.

**`StackService.owned`** is for something you would stop with Ctrl-C: a dev
server, `firebase emulators:start`, a worker. flutterware starts the process
itself and keeps it running when you close the studio. It keeps the log, which
**Logs** shows, and **Tear down** stops the process with everything it started.
A studio, `fw` or an agent opened later finds the same process instead of
starting a second one. Owned services work on macOS and Linux.

## When an owned service is ready

`ready:` says when the service can be used, and **Bring up** waits for it:

- `Ready.http(8080, path: '/health', timeout: ...)`: a request to that path
  gets an answer below 400.
- `Ready.port(8080, timeout: ...)`: something accepts connections on the port.
- `Ready.processAlive()`: the process is running. Use it for a worker with no
  port.

If the service isn't ready within the timeout, it's left running and the panel
says what didn't answer. Its log is right below.

### A port from your own tools

When each checkout gets its own port, let a script in your project say which:

```dart
ready: Ready.httpFrom(
  ValueSource.script('tool/ports.dart', args: ['server']),
  path: '/health',
  timeout: Duration(seconds: 30),
),
```

flutterware runs the script before each start, from the root of the checkout,
and uses the number it prints. The script must exit with an error when it
doesn't know the port, for example when the stack that hands out ports isn't up
yet. The start is then refused with what the script printed, and nothing is
started.

### Environment

`env:` sets variables with fixed values. `envFrom:` sets variables to what a
script prints, worked out before each start the same way as a port:

```dart
env: {'LOG_LEVEL': 'debug'},
envFrom: {'DATABASE_URL': ValueSource.script('tool/db_url.dart')},
```

Everything flutterware starts gets the environment a new terminal window has,
whether the studio was opened from the Dock, from a terminal or by an agent. A
command that works when you type it works here. On CI it's the environment `fw`
itself was started with.

## Three ways to run something

`StackRun.command([...])` runs an executable directly. There's no shell, so
pipes and `$(...)` need `sh -c`, as in the probe above.

`StackRun.script('tool/stack.dart', args: ['up'])` runs a Dart script from your
project with `dart run`, using the same Dart SDK flutterware runs on. The path
is relative to the service's `workingDirectory`. A delegated service's probe
runs often, so it skips build hooks: a probe script can't import packages with
native code.

`StackRun.tool('uv', args: ['run', 'app.py'])` runs an executable from the PATH
a new terminal window has, and refuses to start, naming it, when it isn't
installed.

## Two kinds of probe

A delegated service's `probe` is one of:

`Probe.exitCode(...)`: exit code 0 means up, anything else means down. The last
line of output is shown as the detail. Make sure the command fails when the
service is down: `docker compose ps --quiet` succeeds and prints nothing, which
would read as "up" forever.

`Probe.json(...)`: the command prints one JSON object, which can say more:

```json
{
  "state": "up",
  "detail": "4 containers",
  "services": [{"name": "postgres", "port": 5432, "state": "up"}]
}
```

`state` is `down`, `starting`, `up`, `stopping` or `unavailable` (the probe
couldn't tell). With `services`, a stack that's partly up shows as `up 3/4`
instead of a single colour.

The probe runs every few seconds while the panel is on screen (`poll:` sets the
pace). `fw` and agents don't poll: they show the last reading, from whichever
process took it, and `fw run dev_stack status` takes a new one.

## Commands

`commands:` adds buttons to a service: logs, restart, reset.

```dart
commands: [
  StackCommand('logs', 'Logs', StackRun.command(['docker', 'compose', 'logs', '--tail=40'])),
],
```

Mark a command `danger: true` if it destroys data, and set
`stopIsDestructive: true` on a delegated service whose stop drops your
database. The studio asks before running those. An owned service already has
**Logs** and **Restart**.

## Services that need other services

A service can name the services it needs, and `ensure` brings those up first.
With the example at the top:

```shell
fw run dev_stack ensure --services=server
```

starts `db`, waits until it's up, then starts `server`. A service that's
already up is left alone. If `db` doesn't come up, `server` isn't started, and
the result says why and shows what `db` printed. Without `--services`, it brings
up every service. Each service in the result has its port and URL when
flutterware knows them.

**Bring up** on one service starts only that service.

## History

The panel's **History** lists the latest starts and stops, newest first, with
who asked: you in the studio, `fw` in a terminal, or an agent. A start or stop
that failed shows why. An owned service whose process stopped with nobody
stopping it shows as **exited**.

The history is shared: a start an agent makes from its own session shows in
the studio a moment later.

## From the command line or an agent

```shell
fw run dev_stack ensure            # brings every service up, in order
fw run dev_stack history           # the latest starts and stops, and who asked
fw run dev_stack server.status     # checks one service now
fw run dev_stack server.start
fw run dev_stack server.logs
```

With several services, each service's actions start with its id. With one,
they don't: `fw run dev_stack start`.

## Reference

[`flutterware.dev_stack` in the capabilities reference](../docs/capabilities.md#flutterwaredev_stack).
