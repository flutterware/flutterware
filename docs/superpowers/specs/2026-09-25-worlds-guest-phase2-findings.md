# Worlds guest experiment — phase 2: can a human use it (interim)

**Date:** 2026-09-25
**Plan:** `2026-09-25-worlds-guest-experiment-plan.md`, phase 2. Before it:
`2026-09-25-worlds-guest-phase1-findings.md`.
**Result, so far:** everything a human does with the mouse works — clicking
into either of two guests, selecting text by dragging, the scroll wheel — and
the clipboard now crosses between a guest and the Mac in both directions.
Everything that travels by *key* from the studio into a guest does not, and
that is one break rather than five: characters, Tab, dead keys, shortcuts and
⌘V all ride the same path, and typing on it was already broken before this
work (`tool/embedder/input_probe.dart` fails on master). It is being fixed
separately. **The kill point cannot be called until it is**; nothing seen so
far says it will fail.

## What was built

- **The clipboard, in the host.** A guest is a real process on the machine,
  so `native/clipboard.m` answers the framework's `Clipboard.setData`,
  `getData` and `hasStrings` from the general pasteboard. Linux answers
  nothing yet (`clipboard_none.c`).
- **The world pane** — `app/lib/src/world/world_lab_screen.dart`, launched as
  *World lab (dev)*: a world's people side by side at a phone's size, each an
  embedded guest the studio shows live and hands its mouse and keyboard to
  when clicked, with the name above it saying who has the keyboard. It opens
  the lab's two people in **1.8 s** with the worktree warm.
- **A guest is a Run device.** Each guest is announced to Run as
  `studio-<person>` with a handle like any launch's, so `act` and `observe`
  reach inside it — which is how every result below was read, and what phase
  4 asked for ("parity needs nothing beyond registering the guest as a
  device"). Reload and restart stay Run's to refuse: a guest has no
  `flutter run`.
- **The build moved out of the tool.** `app/lib/src/world/app_guest.dart`
  (assets, the generated entry, the compiler, seeds) and `guest_process.dart`
  (one guest over its socket) are shared by the harness and the pane.

## The checklist

Each item was driven twice: inside the guest, through Run's drive against its
VM service; and through the studio, whose drive lands on the pane's input
region — which forwards over the socket exactly what a mouse and keyboard
would. The second is the human's path from the studio onward; only the Mac's
own key translation, which dead keys need, is outside it.

| | inside the guest | through the studio |
|---|---|---|
| type an email address | — | **blocked**: the key path |
| type é and ü through dead keys | — | **blocked**: the key path, and needs a real keyboard |
| paste a code with ⌘V | **works** — the Mac's clipboard lands in the field | **blocked**: the key path |
| copy text out | **works** — ⌘C reaches the Mac's clipboard | **blocked**: the key path |
| select text with the mouse | — | **works** — a drag selected `na@exa`, and ⌘C copied exactly that |
| scroll with a wheel | — | **works** |
| scroll with a trackpad | — | not measured: drive has no trackpad verb |
| move between fields with Tab | — | **blocked**: the key path |
| two guests side by side | — | clicks land in the guest clicked, at the point clicked, and the keyboard follows the click; whether *keys* then land is the key path |
| the app's shortcuts reach the app | ⌘A, ⌘C, ⌘V work | **blocked**: the key path. The pane reserves no chord, by design |

## Findings

### 1. The key path from the studio is broken, and it is not only typing

⌘V sent inside the guest pastes; the same ⌘V forwarded from the studio —
meta down, v, meta up, into the host's `FlutterEngineSendKeyEvent` and on to
`GuestKeyboard` — lands nowhere, in either guest, while clicks on the same
socket land to the pixel. Once, a paste that had gone nowhere appeared later,
doubled, when a key arrived by the other path. So keys are being lost or held
between the host and the framework, which is where the separate fix is
looking; the evidence was passed on.

### 2. A guest must be sized after it has announced its surfaces

The engine drops what it is asked to send until the guest has said where it
draws. The pane resized its guests immediately after starting them, so both
kept the ratio 1 they started with: a phone twice its size with no safe
areas, which every click then hit at double the coordinates. It now waits.

### 3. Guests ask for mouse cursors nobody gives them

Hovering a field sends `flutter/mousecursor`; nothing answers, so the Mac's
arrow never becomes an I-beam over a guest's text. A small thing a person
notices at once — and the first case of the platform messages phase 3 is
about: the studio holds the real cursor, so it is the studio that must
answer.

### 4. A studio that dies leaves its guests' handles behind

The guests exit with the studio — their socket closes and the host leaves
its loop — but their Run handles stay, and Run's report shows them as
*failed* until a later launch replaces them. The pane deletes them when it is
disposed; a killed studio is never disposed.

## Open

- **The key path**, then the six blocked rows above — dead keys by hand, since
  only a real keyboard exercises the Mac's key translation.
- The trackpad, by hand.
- The cursor (finding 3), with phase 3.
