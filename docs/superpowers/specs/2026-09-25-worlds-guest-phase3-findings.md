# Worlds guest experiment — phase 3: the studio as the platform

**Date:** 2026-09-25
**Plan:** `2026-09-25-worlds-guest-experiment-plan.md`, phase 3. Before it:
`2026-09-25-worlds-guest-phase2-findings.md`.
**Result:** phase 3 passes, well inside its thresholds. With the studio
answering, the lab app runs its plugins' own Dart halves unchanged — the ones
`flutter run` would register — and all ten of its checks pass, for two people
at once, each isolated without the app's help. The six plugins cost **18 to
60 lines each, 35 on average**, against a threshold of about 150; the
platform core and all six took about 20 minutes of an agent's time together,
against a threshold of half a day each. And the studio can
now do what the fakes never could: see each notification an app posts and
tap it, open a link in an app, catch every URL it opens, give it its cursor.
So candidate 2 does not narrow to candidate 1; the case for the guest rests
on it.

## What was built

- **Forwarding in the host.** Started with `FW_FORWARD_PLATFORM=1`, the host
  sends every platform message it does not answer itself — the clipboard it
  does, the keyboard it leaves alone (phase 2, finding 1) — to the studio with
  an id, and the studio answers by that id. Three new protocol messages: a
  platform message, its reply, and a message from the studio into the app.
  Without the variable nothing changes, so Previews is untouched; its tests
  and the input probe pass.
- **The plugins registered as `flutter run` registers them.**
  `app/lib/src/world/plugin_registrant.dart` walks the app's dependency
  closure from the package graph `pub get` leaves, and registers every Dart
  half its pubspecs declare — for the platform of the *look*, not of the Mac:
  a guest drawn as an iPhone registers the iOS halves (finding 3).
- **The studio's answers.** `app/lib/src/world/guest_platform.dart` — method
  channels, Pigeon APIs, events and calls into the app, with the standard
  codecs written against `package:standard_message_codec`, so the headless
  harness answers with the same code the studio does — and one file per
  plugin in `platform/`, so each one's cost can be counted.
- **The pane shows it.** Beside each phone, *World lab (dev)* with
  `studioAnswers` lists the notifications the app posted with a *Tap* for
  each, the URLs it opened, a field to open a link in it; and the phone takes
  the cursor its app asks for.

## Per plugin

| plugin | its native half on the Mac / iOS | studio lines | the plugin's Dart ran unchanged | what the studio can now show or do |
|---|---|---|---|---|
| `path_provider` | **none to answer** — a direct call into Foundation, which runs in the guest | 0 | yes | a directory per person, by `CFFIXED_USER_HOME` (finding 2) |
| `shared_preferences` | two Pigeon APIs | 45 | yes | a person's preferences, as a JSON file in their home |
| `flutter_secure_storage` | a method channel | 27 | yes | a keychain per person — and no signing team, which a macOS window needs (phase 0, finding 3) |
| `app_links` | a method channel and an event channel | 30 | yes | **open a link in the app**, on the plugin's own event channel |
| `flutter_local_notifications` | a method channel both ways | 60 | yes | **every notification the app posts, and tapping it** — the app received the tap and opened the order it carried |
| `url_launcher` | a Pigeon API on each platform, different on each | 27 | yes | **every URL the app opens**, caught rather than sent to the Mac's browser |
| `package_info_plus` | a method channel | 18 | yes | the app's true version, from its pubspec (phase 1, finding 8) |
| the clipboard | the framework's own | in the host, phase 2 | — | the Mac's clipboard, both ways |
| cursor, lifecycle | the framework's own | 19 | — | the cursor the app asks for, over its phone; moving it to the background (built, not yet exercised) |

Shared once by all of them: the platform core, 115 lines; the registrant
generator, 61; forwarding in the host, about 96 lines of C; the wiring in the
engine and the harness, a few dozen. Time: the core and the six plugins took
about 20 minutes of an agent's time together — measured between commits — so
the half-day threshold, set with a person in mind, holds either way.

A platform call now crosses to the studio and back: `shared_preferences`
answered in 8–12 ms at boot, against 1 ms for an in-process fake and 29–43 ms
for the real `UserDefaults` in a macOS window.

## Findings

### 1. The answers belong to flutterware, not to the project

A candidate 1 fake is the project's: written for its app, in its repository,
and written again by the next project. A candidate 2 answer is to a *plugin*
— `shared_preferences` speaks the same Pigeon API in every app that uses it —
so it is written once, in flutterware, and every project using that plugin
has it. Phase 1's consumer needed 89 lines of fakes it would own; the same
coverage here is code no project writes. What a project would still write is
the per-world part — which link to open, which answer to give — and that is
the world script's job, not a fake's.

### 2. Isolation came from the environment, even for the plugin nobody answers

`path_provider` has no channel on macOS: its Swift half became a direct call
into Foundation, which runs inside the guest. The guest's environment sets
`CFFIXED_USER_HOME` to the person's home — the variable the iOS simulator
gives each device — and Foundation's directories follow it: each person's
database landed under their own `Library/Application Support`. Everything
the studio answers is kept in the same home. Two people, no shared state, and
nothing asked of the app.

### 3. A guest with the iOS look must register the iOS halves

The first pane run registered the macOS halves, because the guest runs on a
Mac, while drawing the app as an iPhone. The notifications plugin chooses its
implementation by the *target* platform, found none for iOS, and every call
silently did nothing — `initialized: null`. The registrant now follows the
look, and the studio answers the iOS protocols too: `url_launcher`'s iOS API
is a different Pigeon API from its macOS one, with enums for results where
the macOS one has a class.

### 4. Candidate 1 was a guess about the platform; candidate 2 watches it

With fakes, a notification the app posted went nowhere and a URL it opened
was a print. With the studio answering, the notification appeared beside the
phone the moment the order was ready, a tap on it came back to the app on the
plugin's own channel and opened the order — the design's *tap a push*
delivery — and a link typed in the studio reached the app where one routed by
the OS arrives. This is what the canvas needs from a device, and only
candidate 2 gives it.

### 5. What a real app would add

The consumer's app reaches 21 plugins with a native half on iOS; the lab's
work already answers 7. Of the other 14, most are ordinary channel answers
like the six here — device info, Firebase core and messaging, time zone,
permissions, the photo gallery, opening files, a shake gesture, a support
chat. Three are not:

- **sqflite**, which an image cache opens a database through: the answer is
  the studio running SQLite itself behind sqflite's protocol — the largest
  single answer, and still one flutterware writes once.
- **The camera**: a barcode scanner and a native capture SDK. Nothing can
  answer these honestly but the world saying what the camera sees — the
  design's *device as an input*.
- **Firebase core** blocks at boot on its first unanswered call; nothing else
  runs until it is answered.

So the consumer's first screen under candidate 2 is roughly a dozen more
answers of the kind measured here, plus one design question — the camera —
that no candidate escapes: a macOS window has no phone camera either.

## Open

- The lifecycle, built and not exercised.
- The consumer's app under candidate 2 — the answers in finding 5.
- The plan's phase 4: parity and scale. Drive already reaches a guest
  (phase 2); what is left is the rest of Run's tabs, and four guests at rest.
