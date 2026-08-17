# Quattrolitaire

Klondike solitaire as a native Omarchy shell plugin. A drag-and-drop card
table with an illustrated art-deco deck, on felt coloured from the active
Omarchy theme. No external process, nothing to install.

![The table mid-game](screenshots/table.jpg)

- Draw 1 or draw 3, switchable mid-game
- Drag a card or a run; double-click sends a card straight to a foundation
- Unlimited undo, standard Klondike scoring with a time bonus
- **Auto** finishes the game once every card is face up
- The game in progress is saved, so it survives closing the panel *and*
  restarting the shell

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

## Keys

| Key | Action |
| --- | --- |
| `space` / `d` | Turn a card from the stock |
| `n` | New game |
| `u` / `z` | Undo |
| `a` | Auto-finish (once nothing is face down) |
| `1` / `3` | Draw one / draw three |
| `esc` / `q` | Close |

## Scoring

Standard Klondike: +10 onto a foundation, +5 for waste-to-tableau, +5 for
turning a tableau card face up, −15 for taking a card back off a foundation,
and a recycle penalty of −100 in draw-1 (−20 in draw-3). Finishing in over
30 seconds adds a time bonus; finishing faster is worth more.

## Where things live

| Path | What |
| --- | --- |
| `manifest.json` | Plugin manifest — `panel` + `bar-widget`, `keepLoaded` |
| `Panel.qml` | The whole game: model, layout, cards, drag, cascade |
| `cards/` | The deck: 52 faces, a shared back, and the table tile |
| `BarWidget.qml` | Bar icon; toggles the panel over shell IPC |
| `~/.local/state/omarchy-quattrolitaire/state.json` | Saved game, draw mode, win record |

## Card art

The 52 faces are an original art-deco series, one famous car per card, bundled
in `cards/`. The card back is a rally-car scene by **vulturetone**, used with
credit — see [cards/CREDITS.md](cards/CREDITS.md), which covers what is
licensed how, and swapping in a deck of your own. The table around the cards
is drawn from the active theme, so the felt, the pile outlines and the panel
chrome recolour with the desktop while the deck stays as painted.

## Licence

MIT, including the card faces and the table tile. **Not** the card back, which
is vulturetone's artwork used with credit — rights in it stay with the artist.
Klondike itself is a public-domain card game.
