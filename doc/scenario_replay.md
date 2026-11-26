# Scenario replay

A web page that runs your scenarios and stops at any step you ask for. It shows
the real app, in the language you pick, with a translator's drafts in place of
the catalog's words. Embed it in a page of your own, such as a translation
editor, and a translator sees each string where it appears, at its real length.

Replay needs your [scenarios](scenarios.md) and the translation hook described
in [Translations](translations.md#connect-your-strings-to-the-screen).

## Build the page

```sh
fw run scenarios replay --package=app
```

This takes about a minute and does three things:

1. It runs your scenarios once with `flutter test` and writes the index: which
   translation keys each step shows, and which assets each scenario reads.
2. It writes an entry point that declares your scenario files, each wrapped in
   its `flutter_test_config.dart`, the way `flutter test` wraps them.
3. It builds that entry point for the web, as WebAssembly, into
   `build/scenario_replay/` under the package.

`--file` limits the page to some files. `--matrix=declared` runs the index at
every device and language your folders declare, instead of the first of each.
Use it when a language reads its own assets or fonts. `--index-from` builds
from an index a CI run already wrote:

```sh
FW_REPLAY_INDEX=build/replay_index flutter test test/scenarios
fw run scenarios replay --package=app --index-from=app/build/replay_index
```

Every option is in the
[capabilities reference](../docs/capabilities.md#flutterwarescenarios).

## Serve it

Serve the directory over HTTP with these two headers, so WebAssembly can use
threads:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

A page that embeds it in an iframe needs the same headers.

## Ask for a step

A step is named by its file, its scenario and its position. The position is
`#` and the step's number, counted from the start: `#3` is the third step. In
a scenario that splits, the branches taken come first: `1#2` is the second step
of the second branch, and `0.1#1` is the first step after the first branch of
one split and the second branch of the split inside it. The index lists every
position.

Open the page with the step in its address:

```
build/scenario_replay/?file=test/scenarios/shop_test.dart&scenario=Order%20a%20cappuccino&position=%235&language=fr&draft=shop/total=Montant%20total
```

From a page that embeds it, post a message to the iframe:

```js
frame.contentWindow.postMessage({
  type: 'flutterware.replay.run',
  id: 'r1',
  file: 'test/scenarios/shop_test.dart',
  scenario: 'Order a cappuccino',
  position: '#5',
  language: 'fr',
  device: 'iphone-16',
  drafts: {'shop/total': 'Montant total'},
  locate: ['shop/total'],
}, '*');
```

The page answers each request with a `flutterware.replay.result` message
carrying the same `id`. When it opens, it sends `flutterware.replay.ready` with
every scenario it can run, and the devices and languages each one was declared
for. Requests run one after the other, and each takes a fraction of a second
once the page is open.

The answer says:

| Field | Meaning |
|:---|:---|
| `reached` | The step is on screen. |
| `ok` | It got there with nothing failing on the way. A step can be reached and not ok: the picture is then of an app that had already failed, or of [another screen](#when-the-page-draws-another-screen). |
| `failures` | What failed, in words. |
| `missedAssets` | Assets the app read that the index did not list. The page fetched them while the scenario waited. Rebuild with `--matrix=declared` to list them. |
| `width`, `height` | The device's size, so you can give the iframe its shape. |
| `boxes` | Where each key in `locate` is drawn: `key`, `left`, `top`, `width`, `height`, one per place it shows. |
| `unlocated` | The keys in `locate` drawn nowhere on the step. |
| `ms` | How long the step took to show. |
| `drawn` | The step was on the page when the answer was sent. |

When `drawn` is false, the page still shows an earlier step. This happens when
the page is hidden, since a hidden page draws nothing. The page then sends
`flutterware.replay.drawn` with the same `id` once the step is on screen. If
another request runs first, that message never comes.

The phone is scaled to fit the iframe and centered. The page never takes the
focus, so a translator can keep typing in the page around it.

## Draw where a key is

Name the keys in `locate`, and the answer gives a box for each place they are
drawn, in the device's pixels, from its top left. To draw a box over the
iframe, scale it the way the page scales the phone. For an iframe of `w` by
`h` pixels:

```js
const scale = Math.min(w / result.width, h / result.height);
const left = (w - result.width * scale) / 2;
const top = (h - result.height * scale) / 2;
// For each box:
//   x = left + box.left * scale, y = top + box.top * scale,
//   width = box.width * scale, height = box.height * scale
```

The page finds each key at the address the index recorded for it, so the
box follows the text as a draft or another language changes its length.
Placeholders are found too. An address counts only while the text there is
still the key's. A key the index did not see at that step is looked for by
its words: the draft, else the catalog's text. A key on a screen hidden
under another one is not found, and is listed in `unlocated`.

### When the page draws another screen

The page runs the same scenario as `flutter test`, but the app can still draw
another screen at the same step, when it reads something the page has
another way. `kIsWeb` is one. The text at a key's address is then another
key's, or none, and the key gets no box rather than a box on the wrong line.
If the step shows none of the keys the index saw there, `failures` says so
and `ok` is false. Fix the app, so the step is the same in both, rather than
trusting the picture.

The page also offers
`flutterwareReplay.run(request)` and `flutterwareReplay.scenarios()` in its
console.

## Find where a key appears

`replay_index.json`, beside the page, lists every key with the steps that show
it:

```json
"shop/total": [
  {"file": "test/scenarios/shop_test.dart", "scenario": "Order a cappuccino", "position": "#5"}
]
```

Each entry is a request, ready to send. Its `scenarios` list each step with
the keys it shows and where each one was drawn:

```json
{"position": "#5", "point": "iPhone 16 · en", "boxes": [
  ["shop/total", "p11.0", 24.1, 730.2, 36.8, 18.8]
]}
```

A box is `[key, address, left, top, width, height]`, in the device's pixels,
measured on the device and in the language `point` names. It covers text the
app builds from a placeholder too, like `Thanks {name}`: the run that writes
the index traces every string to its key. So an editor can outline a key from
the index alone, before anything replays.

The index is measured by `flutter test`, and the page lays text out in the
browser. The two can differ by a few pixels, and more when a line breaks in a
different place, which moves everything below it. To draw over what the page
shows, use the answer's `boxes`.

## What does not work in a page

- **`kIsWeb`.** It is true in the page, and no platform override reaches it.
  The device's platform is applied, so `defaultTargetPlatform` and
  `Theme.of(context).platform` answer as on the device, but code that branches
  on `kIsWeb` takes its web branch. Flutter's own widgets do too:
  `BackButtonIcon` draws the web arrow on an iPhone. A branch that changes the
  screen is [reported](#when-the-page-draws-another-screen).

- **The disk.** A scenario that reads a file, starts a process or reads an
  environment variable fails, and the answer says so. Give it the data another
  way: an asset, or data written in the test.
- **Taps by words a draft changes.** A scenario that taps `'Add to cart'`
  misses once a draft rewords it, and the answer says what it could not find.
  Tap by key instead.
- **Overflow warnings.** The page is built without asserts, and Flutter reports
  an overflow only through one. Text that is too long still looks too long.
- **Fonts no step uses.** The page leaves out every font family no step drew
  text in, so it does not download them when it opens. The build lists them.
  `--keep-font=<family>` keeps one.
