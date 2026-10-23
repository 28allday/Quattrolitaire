# Quattrolitaire

Klondike **and Spider** solitaire as a native Omarchy shell plugin. A
drag-and-drop card table with an illustrated art-deco deck, on felt coloured
from the active Omarchy theme. The deck ships in the repo, so there is
nothing to fetch and nothing to build.

![The table mid-game](screenshots/table.jpg)

- Two kinds, switched in the panel header; each keeps its own game and stats
- **Klondike**: draw 1 or draw 3, switchable mid-game; drag a card or a run;
  double-click sends a card straight to a foundation; unlimited undo,
  standard scoring with a time bonus; **Auto** finishes the game once every
  card is face up
- **Spider**: two decks on ten columns, at 1, 2 or 4 suits; drag any
  same-suit descending run; completed K→A suit runs come off the table (+100)
  and eight of them win; space deals a row of ten (blocked while a column is
  empty); undo, 500-point start, −1 per move
- Wins are tracked separately — Klondike's tally, and Spider's per
  difficulty
- The in-progress game of each kind is saved separately, so both survive
  closing the panel *and* restarting the shell, in either mode

## Install

```bash
omarchy plugin add https://github.com/28allday/Quattrolitaire --enable
```

Or with the installer, which does the same thing and places the bar icon:

```bash
./install.sh
```

Then click the ♠ in the bar, or bind a key to:

```bash
omarchy-shell shell toggle nosignal.quattrolitaire
```

`install.sh` takes two optional overrides: `QUATTROLITAIRE_SECTION` picks the
bar section (`left`, `center` or `right`, default `right`), and
`QUATTROLITAIRE_REPO` registers the plugin from a fork instead.

## Removal

```bash
omarchy plugin remove nosignal.quattrolitaire
```

That unregisters the plugin and drops its bar icon. The saved game is left
behind; delete it too with:

```bash
rm -rf ~/.local/state/omarchy-quattrolitaire
```

## Dependencies

Omarchy 4 and its shell — no other runtime dependency for play itself. One
piece of plumbing needs **`jq`**, which Omarchy already installs: see below.

## What it writes, and what it does not

- `~/.local/state/omarchy-quattrolitaire/state.json` — the Klondike game in
  progress, which kind is showing, the draw mode and the win record. Written
  after each move.
- `~/.local/state/omarchy-quattrolitaire/spider.json` — the Spider game in
  progress, the chosen difficulty and the win record per difficulty. Written
  after each move.
- `~/.config/omarchy/shell.json` — **on first open**, the plugin appends its
  own `{"id": "nosignal.quattrolitaire"}` entry to `plugins[]` if one is not
  already there, using `jq`. This is a workaround: `omarchy plugin enable`
  writes only the bar-layout entry for a plugin that is both a panel and a
  bar widget, so without that entry the keybinding stops working the moment
  the bar icon is removed. The edit is idempotent, appends only, changes no
  other setting, and goes away once upstream
  [PR #6510](https://github.com/basecamp/omarchy/pull/6510) lands. The code
  is at the top of `Panel.qml` if you would rather read it than take my word.

Nothing else on the system is touched. The plugin makes **no network
requests**, needs no credentials, runs nothing privileged, and starts no
process beyond the `jq` edit above and a `mkdir -p` for its own state
directory.

## Scoring

**Klondike** — standard: +10 onto a foundation, +5 for waste-to-tableau, +5
for turning a tableau card face up, −15 for taking a card back off a
foundation, and a recycle penalty of −100 in draw-1 (−20 in draw-3).
Finishing in over 30 seconds adds a time bonus; finishing faster is worth
more.

**Spider** — starts at 500, −1 per move, +100 for every completed K→A suit
run, and eight sets end the game. Deal keys: Klondike `1`/`3` pick draw
modes; Spider `1`/`2`/`4` pick suits (re-deal, asks first mid-game).

## Where things live

| Path | What |
| --- | --- |
| `manifest.json` | Plugin manifest — `panel` + `bar-widget`, `keepLoaded` |
| `Panel.qml` | The Klondike game: model, layout, cards, drag, cascade. Also the panel chrome and the kind switch both boards share |
| `Spider.qml` | The Spider game: model, layout, drag, completions, cascade — mounted on the panel's felt |
| `cards/` | The deck: 52 faces, a shared back, and the table tile |
| `BarWidget.qml` | Bar icon; toggles the panel over shell IPC |
| `~/.local/state/omarchy-quattrolitaire/state.json` | Klondike game, draw mode, win record, which kind |
| `~/.local/state/omarchy-quattrolitaire/spider.json` | Spider game, difficulty, win records per difficulty |

## Card art

The 52 faces are an original art-deco series, one famous car per card, bundled
in `cards/`. The back is reframed from **vulturetone**'s `1-quattro.jpg`, the
rally-car wallpaper in Omarchy's stock `tokyo-night` theme — with thanks, and
the reason this thing is called Quattrolitaire. See
[cards/CREDITS.md](cards/CREDITS.md), which also covers swapping in a deck of
your own. The table around the cards is
drawn from the active theme, so the felt, the pile outlines and the panel
chrome recolour with the desktop while the deck stays as painted.

## Licence

MIT, artwork included. The card back comes from vulturetone's `tokyo-night`
wallpaper, credited in [cards/CREDITS.md](cards/CREDITS.md). Klondike itself
is a public-domain card game.
