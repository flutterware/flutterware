# Brewline

A small coffee-shop app, wired up with [flutterware](https://github.com/flutterware/flutterware).
It exists to be cloned: one command opens the studio and every tool below is
already pointed at something real.

```sh
git clone https://github.com/flutterware/flutterware_example
cd flutterware_example
dart run flutterware
```

That is the whole setup. The first run is slow — it builds the studio — and it
needs no SDK of its own: the `dart` you type is the `dart` it uses, so
`fvm dart run flutterware` works the same way if that is how you pin.

## The stamp card

Every drink ordered is a stamp on the card behind the loyalty icon on the
menu; ten stamps and the next one is on the house. The card lives beside the
cart rather than in it — an order clears the cart and keeps the stamps — so
`lib/shop/loyalty.dart` is a scope of its own above the navigator, the same
shape as the cart.

## What to look at

**Previews** — `demo/shop.dart` has one entry per screen, annotated with
Flutter's own `@Preview`, plus one sheet of a component in all its states.
They open framed on a phone because `tool/flutterware.dart` says the app is
one; nothing is written on the annotations. `demo/brand.dart` is the launcher
icon: the icon files under `android/`, `ios/`, `macos/` and `web/` are
pictures of it, taken by `tool/brand_icons.dart`.

**Scenarios** — `test/scenarios/mobile/shop_test.dart` is a `flutter_test`
that screenshots itself. `flutter test` runs it like any other test; the
studio runs the same file and draws the flow, including the `split` that fans
out into every way through the menu. Every step leaves a picture, a widget
tree and the visible texts, in both languages. The folder next to it,
`desktop/`, replays the same shop in a window, and each folder's
`flutter_test_config.dart` says what it runs on. The other files show one
thing each: the keyboard coming up, a list scrolled to a row that is not
built yet, a screen caught mid-animation, a receipt attached to a step.

**Store screenshots** — `A morning order`, in the same file, tags the five
shots the listing uses, and `lib/store_frame.dart` draws each one: a phone, a
headline from `assets/store/`, and one of the app's own widgets held out of
the screen. `fw run store export` writes the App Store and Google Play sets in
both languages, in the layout fastlane reads.

**Translations** — the words are in `assets/i18n/`, and because the scenarios
record which key each screen asked for, the panel can say where a string
actually appears.

**Dependencies, Assets, Splash, Launcher icon** — what this project resolves to,
what it weighs, and what the platforms will actually show.

**Run** — launch the app on a device and drive it: by hand, from `fw`, or from
an agent over MCP. The second entry point, `lib/shop_devbar.dart`, puts a
devbar on the shop with a plugin that pushes a notification into it — the
sample for driving an app from outside itself.

## The command line and agents

Everything the window does is also a command, because they run the same code:

```sh
alias fw='dart run flutterware'

fw status                       # what every tool says about this project
fw actions                      # what can be invoked, and with what
fw run previews screenshot --entry='demo/shop.dart#shopMenu'
fw run scenarios run
```

`dart run flutterware` also wrote an MCP server into `.mcp.json`, so an agent
opening this repo finds the same tools without being told.

## Layout

```
lib/shop/        the app — welcome, menu, drink, cart, order status
lib/shop_devbar.dart    the app with a devbar, and the push plugin behind it
lib/store_frame.dart    the frame around every store image
demo/            @Preview entries: the screens, a component sheet, the icon
test/scenarios/  the scenarios, a folder per kind of device, each with the
                 config that says what it replays on
assets/i18n/     the words, English and French
assets/store/    the store listing's headlines, kept apart from the app's words
assets/brand/    the icon art, photographed from demo/brand.dart
assets/splash/   the splash art; flutter_native_splash.yaml places it
tool/flutterware.dart   which tools this project gets, and how they are aimed
tool/brand_icons.dart   writes the icon art into every platform's icon files
```
