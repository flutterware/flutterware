# Worlds guest experiment — phase 2: can a human use it

**Date:** 2026-09-25
**Plan:** `2026-09-25-worlds-guest-experiment-plan.md`, phase 2. Before it:
`2026-09-25-worlds-guest-phase1-findings.md`.
**Result:** phase 2 passes — the second kill point is cleared. Every row of
the checklist works from the studio into either of two guests: clicking,
selecting by dragging, the wheel and the trackpad, typing, dead keys, editing
keys, Tab, ⌘A/⌘C/⌘V, and the keyboard going to whichever guest was clicked;
the clipboard crosses between a guest and the Mac both ways. The owner
checked dead keys and the trackpad by hand, the two rows only a real
keyboard and trackpad exercise.

The first run of the key rows failed, and the cause was this experiment's
own host, not an old bug (finding 1).

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
| type an email address | — | **works** — characters and editing keys; ⌘A and Backspace clear the field first |
| type é and ü through dead keys | — | **works**, checked by hand: only a real keyboard goes through the Mac's key translation |
| paste a code with ⌘V | **works** — the Mac's clipboard lands in the field | **works** |
| copy text out | **works** — ⌘C reaches the Mac's clipboard | **works**, by the same shortcut |
| select text with the mouse | — | **works** — a drag selected `na@exa`, and ⌘C copied exactly that |
| scroll with a wheel | — | **works** |
| scroll with a trackpad | — | **works**, checked by hand: drive has no trackpad verb |
| move between fields with Tab | — | **works** — focus moved to the next control in the app's traversal order, and Enter activated it |
| two guests side by side | — | **works** — clicks land in the guest clicked, at the point clicked, and typing goes to that guest only |
| the app's shortcuts reach the app | ⌘A, ⌘C, ⌘V work | **work**. The pane reserves no chord, by design; a studio with shortcuts of its own has to keep the list to those it binds |

Drive's synthetic keys carry the key's label as their character, so typed
letters arrived upper-case; a real keyboard sends the character its layout
resolves.

## Findings

### 1. Answering the keyboard's question cost a guest every key

The first run of the key rows found every key from the studio lost —
characters and shortcuts alike — while clicks landed to the pixel. The cause,
found by the session fixing the input probe: at start the framework asks
`getKeyboardState` on `flutter/keyboard`, an optional channel, and the moment
*any* answer arrives it hands every key event to its own `KeyEventManager`,
overwriting the handler `GuestKeyboard` installed. Master's host never ran
platform tasks, so it never answered and the takeover never happened. Phase
1's host answers every message empty — and so it happened, on every start.

Phase 1 had recorded typing as broken *before* this work. It was not: the
probe's "master host" was a stale binary the catalog compiler daemon kept
serving after `host.c` was reverted. With a fresh daemon, master passes.

For now the host leaves `flutter/keyboard` alone and every key row passes.
The lasting fix is the guest keyboard taking its handler back once its own
`syncKeyboardState` is answered, which is being made separately; once it is
in, the exception goes, so the probe is again what proves the handler
survives.

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

- The cursor (finding 3), with phase 3.
- The `flutter/keyboard` exception in `host.c`, once the guest keyboard's own
  fix is on master (finding 1).
