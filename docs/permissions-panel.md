# A permissions panel in your app

A devbar panel that shows what the OS has granted, and asks for a permission
before you reach the screen that needs it, takes about sixty lines. This page
has them, to copy into your project.

flutterware has no permissions plugin of its own. Your app already reads
permissions through a package it chose, such as `permission_handler`, or
through platform channels of its own, and a panel written against that package
shows exactly what it reports. A generic panel would have to map those states
onto its own, and lose detail: [the traps](#the-traps-worth-knowing) below
show how `permission_handler`'s six states come down to two on Android.

What flutterware provides is `DevbarPanelSource`. Implement it, and your panel
appears on the run's **App** tab, in `fw` and over MCP, the same way the
feature flag and database panels do.

## The whole thing

```dart
import 'package:flutterware/channels.dart';
import 'package:flutterware/devbar.dart';
import 'package:permission_handler/permission_handler.dart';

/// The permissions this app cares about, by the name you want to see.
const _permissions = <String, Permission>{
  'camera': Permission.camera,
  'location': Permission.locationWhenInUse,
  'notifications': Permission.notification,
};

class PermissionsPlugin implements DevbarPlugin, DevbarPanelSource {
  static PermissionsPlugin Function(DevbarState) init() =>
      (_) => PermissionsPlugin();

  @override
  String get panelId => 'permissions';

  @override
  String get panelLabel => 'Permissions';

  @override
  void describePanel(Panel panel) {
    panel.state(
      'status',
      'Status',
      description: 'What this app believes about each permission, right now.',
      read: _status,
    );

    panel.action(
      PluginAction(
        'request',
        'Request',
        danger: true,
        description:
            'Asks the OS for one permission — the real dialog, on the real '
            'device. Answers with what came back.',
        parameters: [
          ActionParameter(
            'permission',
            'Permission',
            kind: ActionParameterKind.choice,
            description: 'Which one to ask for',
            options: [
              for (var name in _permissions.keys) ActionOption(name),
            ],
          ),
        ],
      ),
      _request,
    );

    panel.action(
      const PluginAction(
        'openSettings',
        'Open settings',
        description:
            "Opens this app's page in the OS settings — the only route back "
            'from a permanent denial.',
      ),
      (_) async => {'opened': await openAppSettings()},
    );
  }

  /// Every permission in one call, so filling the column costs one round trip
  /// to the phone instead of one per permission.
  Future<Map<String, Object?>> _status() async {
    var statuses = <String, Object?>{};
    for (var entry in _permissions.entries) {
      // A permission that fails to read must not hide the others.
      try {
        statuses[entry.key] = (await entry.value.status).name;
      } on Object {
        statuses[entry.key] = 'unknown';
      }
    }
    return {'permissions': statuses};
  }

  Future<Object?> _request(Map<String, Object?> arguments) async {
    var permission = _permissions['${arguments['permission'] ?? ''}'];
    if (permission == null) {
      return {'error': 'Which permission? One of ${_permissions.keys}.'};
    }
    // The status after the request, read back from the platform.
    return {'status': (await permission.request()).name};
  }

  @override
  void dispose() {}
}
```

Register it like any other plugin:

```dart
Devbar(
  plugins: [
    PermissionsPlugin.init(),
    // …
  ],
  child: const MyApp(),
)
```

## What you get

From that one declaration:

- the run's **App** tab shows the panel: each status, a **Request** button and
  **Open settings**;
- **`fw`** reaches the same three through the panel actions:
  `fw run run panelState --panel=permissions --state=status` and
  `fw run run panelInvoke --panel=permissions --action=request …`;
- an agent gets them over **MCP** with nothing more to write.

On a physical iPhone and on macOS, reading the status from inside the app is
the only way to read it at all: the system keeps no record that a tool outside
the app can read.

## What it cannot do

**You cannot revoke or reset a permission from inside the app.** Neither
platform allows it. The panel gets you into a granted state; it can't take you
down the denied path or back to a first install. To return an app to the state
where nothing has been asked yet, uninstall it, or run `adb shell pm
reset-permissions` or `xcrun simctl privacy … reset` from a terminal.

**On iOS, `request` shows a dialog once per install.** After the first answer,
the platform returns the stored answer without asking, so the button does
nothing. **Open settings** is then the only way to change it, and it sends the
app to the background, where iOS suspends it.

**On Android it works best**, but even there the status is coarser than it
looks: see [the traps](#the-traps-worth-knowing) below.

## A panel scoped to something that opens and closes

The plugin above is in the devbar's plugin list, which suits a panel the app
has the whole time. Some panels only exist for part of it. A database opened at
login and closed at logout isn't there yet when the devbar is built at
`runApp`, and the same goes for anything that belongs to a checkout, a document
or a selected workspace.

There are two ways to handle it, and the first is usually better.

**Keep the panel, and have it say why it is empty.** Give the panel a way to
look the thing up instead of the thing itself, look it up inside each handler,
and throw an error with a readable message when there is nothing to find.
`DatabaseAdapter`'s documentation has a full example, with
`DatabaseUnavailable`.

**Or limit the panel to a subtree** with `AddDevbarPanel`, which serves a
`DevbarPanelSource` for as long as it is mounted:

```dart
AddDevbarPanel(
  source: _session.databasePanel,
  child: signedInApp,
)
```

When the lifetime belongs to a service instead of a subtree, such as a session
opened at login and closed at logout, make the same call without the widget:

```dart
_panel = DevbarPanels.add(DatabasePanelSource(adapter));  // at login
_panel.remove();                                          // at logout
```

`AddDevbarPanel` makes that call and removes the panel in `dispose`, the way
`AddDevbarButton` wraps `UiService.addButton`. Use the widget when a subtree
already has the lifetime you want, and the handle when it doesn't: inserting a
widget above an existing subtree remounts that subtree.

The list of panels is sent again whenever it changes, so a panel added halfway
through a run shows up in the studio, in `fw` and over MCP.

Prefer the first way when you can, because a panel that isn't there can't say
why. Ask for `db:main` after it has been removed and the answer is that the app
declares no panel `db:main`, whether the app has no database at all or the
user is one tap away from opening one. Use `AddDevbarPanel` when the panel
itself makes no sense outside its scope. If only its data comes and goes, keep
the panel.

## The traps worth knowing

If you use `permission_handler`, two of its states don't mean what their names
suggest.

**`denied` doesn't only mean denied.** `permission_handler` has no
*undetermined* state: a permission that was never requested and one the user
turned down both arrive as `PermissionStatus.denied`. Show that word as it is
and a fresh install looks as if the user refused everything.

**On Android, `permanentlyDenied` means nothing before the first request.** It
comes from `shouldShowRequestPermissionRationale`, which is false both before
the first request and after "don't ask again". So a fresh install reports every
permission as permanently denied, and you can't tell that apart from a real
permanent denial.

Together, on Android, they leave you with *granted* or *don't know*, and little
in between. Show it that way, instead of a word that sounds more precise than
the data.

A package that asks the platform directly can do better, and so can your own
code if it records whether it has made the first request yet. Either change
goes in `_status` above, in your project.
