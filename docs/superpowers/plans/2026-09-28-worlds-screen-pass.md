# The Worlds screen, redrawn — Implementation Plan

**Goal:** the open world as the five frames of the 2026-09-28 UI proposal
draw it: one toolbar, phones in their device body on the stage grey, a person
in focus beside an inspector, mail read inside that inspector, a person on a
desktop in a browser the studio draws, and the world log as the first tab of
a bottom dock.

**Reference:** the proposal's frames 1–5 and their numbered pins, 1–18. Each
slice below says which pins it builds. Where this plan and a frame disagree,
the frame wins unless the plan says why.

**Starting point:** the stripped screen on this branch — phones side by side,
a name opens a focus, nothing of the system drawn — plus the stage experiment
(`world_stage.dart`), which answers the crowded world.

## Global constraints

- Tokens only (`context.colors`, `context.type`, `FwSpacing`,
  `context.radii`, `FwIconSize`); controls from `app/lib/src/ui/`. A control
  the frames need that does not exist is built there, previewed in
  `app/tool/catalog/demos/`, light and dark.
- Every slice is looked at before it is called done: drive the studio on
  *Rush hour* (twelve people) and *Pickup order* (the desktop person), and
  `previews screenshot` any new control.
- No hard-coded colour from the frames. The frames' greys are the studio
  tokens already (`panel`, `line`, `mut`, `ink2`, `accent`); the lab app's
  browns are the app's own and appear only inside the guest.
- One PR for the screen. Commits per slice.

## What the studio already has, and what gets built

Reused as they are:

- **The dock** — `InspectDock` (`app/lib/src/inspect/inspect_dock.dart:60`):
  caller's tabs, host-held `current` and `collapsed`, its own resizable
  height, mounted under a canvas in a `Column` exactly as Previews
  (`previews/inspect_panel.dart:141`), Scenarios (`scenarios/step_page.dart:555`)
  and Run (`plugins/native/run_plugin.dart:1280`) do.
- **Top-of-pane tabs with counts** — `InspectTabStrip` (same file, `:196`)
  with `CountBadge`; the focus already uses it.
- **The iPhone body** — `deviceFrameFor(Device)`
  (`previews/catalog_devices.dart:45`) and the vendored `DeviceFrame(device:,
  screen:)`, which lays the screen out at the device's logical size inside a
  `FittedBox`: `WorldPhone` goes in as the `screen`. Null for a desktop device,
  which gets the browser instead.
- **The ground** — `StageGround` / `stageGroundColor` (`ui/stage.dart`).
- **Zoom** — `ZoomButtons` floated in a `Positioned(right: md, bottom: md)`,
  as `scenarios/flow_view.dart:259` already does.
- **Run's panes** — `NetworkTab`, `PanelsTab`, `LogsTab`, public and already
  hosted by the focus.
- **The `⋯` menu** — `Menu` with `MenuItem(icon:, shortcut:)` (the count goes
  in `shortcut`, as `scenarios_plugin.dart:2033` does), triggered the way
  `run/logs_tab.dart:591` triggers its own.

Built in `app/lib/src/ui/`, each with a catalog demo, light and dark:

- **`FwSegmented`** — the tray with the chosen option raised on white.
  Generalised from the private `_LensSwitch` (`inspect/semantics_view.dart:267`),
  whose chosen option is tinted rather than raised; options carry an optional
  leading widget (the dot, the grid icon).
- **`FwChip`** — a small bordered chip with a leading icon and a text style,
  generalised from `dependencies/detail.dart:944`'s `_Chip`; the cause is
  `FwChip(icon: subdirectory_arrow_right, style: type.mono)`.
- **A plain button with an icon** — the header's Reload and Restart. The
  themed `TextButton.icon` if it matches the frames' height and type;
  otherwise a `plain:` look on `FwActionButton`, which today is always
  outlined.
- **`BrowserFrame`** — slice 5.

## Before this

- **The trackpad fix ships with the screen** (decided 2026-09-29):
  `app/native/input.c`, `app/lib/src/embedder/input_region.dart` and its
  test are part of the same PR, and its description says Previews gets it
  too.
- **The stage experiment's verdict** (decided 2026-09-29): *Fit with zoom*,
  scrolls to the phone under the pointer. *Row*, *Rows*, the *Clicked phone*
  rule, their pills and the readout go.

## Slices

### 1. The shell: header, toolbar, dock — pins 1, 5, 9

- **Header.** `FwPanelHeader` as today, with `badge:` a state dot and word
  (`● Open`, green; moving states muted, failed red) instead of the phase in
  the subtitle; the subtitle is the path alone. Reload and Restart become
  plain buttons with a leading icon (`refresh`, `restart_alt`); Close stays
  outlined.
- **Toolbar** (`FwPanelHeader.toolbar`, a 44px band between two rules): the
  world's actions on the left, each a play button; on the right the switch —
  *Everyone*, then each person with their dot. The switch *is* the focus:
  picking a person opens them, *Everyone* goes back (pin 9). It replaces the
  OPENED WITH / ACTIONS rows, the *All phones* back link and the row of
  *World log* and zoom.
- **Dock.** The dock Previews, Scenarios and Run share, with *World log* its
  first tab: collapsed to its strip by default, open to a resizable height.
  The log reads in three columns — time since opening, source, text — so
  `OpenWorld` keeps lines as `(elapsed, source, text)` rather than
  pre-joined strings; `worlds status` and the MCP keep today's text.
- Removes: the experiment's *Try* and *Scrolls go to* pills and the
  `_Said` readout.

### 2. The stage — pins 2, 3, 4, 10, 12, 13

- **Stage grey** under everything (`stageGroundColor`, already the
  experiment's).
- **Device bodies.** A phone stands in the iPhone body Previews draws; a
  desktop device in the browser of slice 5. The body is part of the size the
  stage lays out, so every device is drawn at one scale (pin 10) — the
  stage's `sizeOf` returns the framed size.
- **Person tag** above each device, centred: a white pill with the colour
  dot, the name, and a count per kind of message received (`mail`, `push`,
  `sms` icons with a number; only the kinds they got). The tag opens the
  focus, as the name does today. Identity and entry point leave the stage —
  they are in the focus header.
- **Someone with no app** is a small card at the tag's width, not a
  phone-sized placeholder (pin 13). Building / starting / failed stay inside
  the device body, on its screen.
- **Zoom** floats on the stage's bottom-right corner, over the stage, and
  only on the overview (pin 4).
- **Crowds**: whichever layout the experiment settles on (see *Decisions*).

### 3. One person in focus — pins 6, 7, 8

- **Left:** the device on the stage grey, as large as the height allows.
- **Right:** the inspector.
  - **Person header:** dot and name; beneath, identity · `<entry point> on
    <device label>` (`Lab on iPhone 16`, `Lab in a browser, 1280 × 800`).
    A `⋯` button opens a menu: *Open a link in Leo's app…* (a small dialog
    with the field), *Notifications posted* with its count (a submenu or a
    popover listing them, each tappable), a rule, *Send to the background* /
    *Bring to the front*. This is the platform panel, retired (pin 6).
  - **Tabs:** Messages *n*, Network *n*, App, Logs — a count where there is
    one to give.
  - **A message row:** a round kind icon; the title bold and the time at the
    right; the body under it; a footer with where it came from (*Push from
    lab*, *Mail from newsletter*), the **cause** as a mono chip, marks, and
    the row's buttons at the right.
    - The cause is the step's own words, not its id: `action "The regulars
      order"` for a world action, `Leo: tap "Order a flat white"` for a
      gesture (pin 7). Needs a public step lookup on the trace
      (`WorldTrace.step(id)`); today only `_steps` holds them.
    - **Shown** (pin 8): a push is marked `✓ shown` when the app posted a
      notification with the push's title within a few seconds of it; that
      notification is then not listed again under *Notifications posted*.
    - **Matched by time** (pin 15): a mail whose step was joined by time says
      so as a muted mark, not inside the cause.

### 4. Mail inside the inspector — pins 14, 17, 18

- Mail rows carry **Read it**, and **Open** for the link they carry (pin 14).
- *Read it* replaces the Messages list with the reader, in the inspector,
  while the device stays in view (pin 17): `← Messages`, the subject, `From
  lab to ana@… · time`, the cause chip, the mail as drawn today
  (`MailView`'s WebKit picture, links clickable), and under it one line per
  link opened: `✓ Opened in Ana's app worldlab://orders/o3 · 23:41:30` (pin
  18). `OpenWorld` keeps each delivery with its time, by message, so the line
  survives leaving and coming back. Esc goes back to the list; the 640px
  sheet over the canvas goes.

### 5. A person on a desktop — pins 10, 11, 16

- **The browser** the studio draws around a desktop guest: a tab strip with
  the traffic lights and one tab (the app's title and an initial), a bar with
  back, forward, reload and the address field. Built as a control in
  `app/lib/src/ui/` with a catalog demo.
- **The address** is the route the app reports: the guest platform answers
  `flutter/navigation` (`routeInformationUpdated`, `selectSingleEntryHistory`,
  `selectMultiEntryHistory`), which Flutter's Router and root Navigator send
  on every platform. Shown as `<entry point>.localhost` (muted) + the path.
- **Typing a URL** there and pressing Enter opens it in the app the way a
  delivered link does (`platform.links.open`); **back** sends `popRoute` on
  `flutter/navigation`; forward and reload are drawn only, greyed.
- **The lab**: *Pickup order* declares Ana on `Studio(Devices.window)` and
  Mia as a person with no app. The lab app, wide and staff, shows the
  counter board of the frames (Placed · Preparing · Ready columns, a card
  outlined when a link picks it) and routes with `MaterialApp.router`, so it
  reports `/orders` and `/orders/o3` as a routed app does.

## Decisions the frames do not make

Each has a default this plan builds unless told otherwise.

1. **Crowded worlds** — decided 2026-09-29: *Fit* with zoom and pan
   (everyone in view on opening; zooming in lets the stage pan — Canvas
   folded into Fit), and a scroll over a phone goes to that phone; over the
   ground, or with ⌘, to the stage.
2. **Knobs** (*Regulars 10*) are not in the frames. Default: at the toolbar's
   left, before the actions, as `Regulars 10 ▾`, a rule between them; a
   change still restarts the world.
3. **Twelve people in the switch.** Default: as many as fit, the rest in a
   trailing `+4 ▾` menu.
4. **Which phone has the keyboard.** The rounded border that turned accent
   goes with the device body. Default: an accent ring following the body's
   outline.
5. **Sync state** of a synced app lived in the platform panel. Default: the
   person header's second line — `Synced at 12:03:04 · nothing to upload`.
6. **Who the actions act for**, on a card of someone with no app. Default:
   the actions whose name contains the person's name, bold; none named, the
   card says only that the world's actions act for them.

## Built — and where it differs from the frames

All five slices are built (2026-09-29) and were looked at live on *Rush hour*
with twelve people and on *Pickup order*. Where the result is not the frame:

- **Network carries no count.** Its requests are read from the app's VM
  service only while the tab is open; a count would need a connection per
  person the whole time, and a count that disagreed with the list would be
  worse than none.
- **Buttons are the studio's own**, at its button size rather than the
  frames' 13px, and the zoom is `ZoomButtons` with its magnifiers.
- **The panel's tabs are Run's strip**, on the panel grey, as in Run.
- **The mail reader grows a `Mail | Page` switch** once a web link the app
  does not claim has taken it to the page — the way back. At rest it is the
  frame. The list of links under the mail is gone: a link in the picture now
  goes where a phone would send it, so the list had nothing left to add.
- **`⋯` adds *Pages it opened*** when the app has opened any — what the
  platform panel listed as *Opened*.
- **The browser's tab shows the title's initial** on the title's colour, not
  an app icon; forward and reload are drawn only. Back pops the app's route;
  a typed path is pushed to it, a typed link with a scheme is delivered as a
  link.
- **The address's host is the entry point's name** (`lab.localhost`): a
  desktop app has none of its own.
