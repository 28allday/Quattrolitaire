# NOTES — Quattrolitaire (nosignal.quattrolitaire)

Working notes for this repo. Read before changing anything in `Panel.qml`.

## Status

**0.1.0, untagged.** Playable and in daily use. Home is the **public**
`28allday/Quattrolitaire` on GitHub, `main`, pushed as a single squashed
commit. The `omarchy plugin add` line in the README works for anyone. No
release is tagged yet.

Installed here as a dev symlink
(`~/.config/omarchy/plugins/nosignal.quattrolitaire` → the repo), enabled in the
right bar section — so **no hot reload**: `omarchy-restart-shell` after every
QML edit, and never `omarchy-refresh-shell`, which resets `shell.json`.

Verified in the live shell: deals, renders, draws, drag-and-drop play, the
saved game surviving a shell restart, and the win cascade. Shell log clean.
The keyboard shortcuts are the one part never properly exercised — see "wtype
is useless here" below for why they could not be tested automatically.

Working state, open decisions and machine-specific notes are in
`NOTES.local.md`, which is not tracked.

## Design

**The model is 52 integers.** A card is `cid` 0-51: `suit = cid / 13`
(0 ♠, 1 ♥, 2 ♦, 3 ♣), `rank = cid % 13 + 1`. Piles are arrays of those,
bottom card first. `faceUp` is one flat array of 52 booleans. Nothing stores
a card's position.

**One layout function owns geometry.** `computeLayout()` turns the model into
52 `{x, y, z, pile, idx, up}` records plus the column heights used for drop
targeting. It is bound to `rev`, which `touch()` bumps after every mutation.
Card delegates bind their `x`/`y`/`z` to their record, with a `Behavior` that
is disabled while the card is being carried — so a legal move is applied to
the arrays and *animates itself*. There is no imperative card movement
anywhere, and the thing you can drop on is by construction the thing you can
see.

**Drops resolve by overlap area, not cursor position.** `dropDrag()` scores
the dragged card's rectangle against every legal target and takes the biggest
overlap, so a card released half over a column goes where it looks like it is
going. Illegal targets are never scored, so an illegal drop is a snap-back
rather than a rejection message.

**Runs need no validation.** Face-up cards in a tableau column are always a
descending alternating sequence by construction — the deal exposes one card
per column and every later card arrives through `canPlaceOnColumn`. So
`beginDrag` can take `col.slice(idx)` without checking it.

**The win cascade is a Canvas that is never cleared.** QML `Canvas` keeps its
buffer between paints, so painting one card per tick and never clearing is
the trail. `stepCascade()` is the whole physics: gravity, a floor bounce at
0.78 restitution, and a minimum bounce so a card can't die on the floor.

## Card art

**The deck is bundled artwork** — 52 faces plus a shared back in `cards/`,
named by card code, with the details and the swap-in procedure in
`cards/CREDITS.md`. The faces carry their own frame, rounded corners and
index, so the card delegate draws nothing over them: its `Rectangle` is a
transparent positioning shell, and every drawn face element was removed. Card
aspect is `cardW * 1.4` to match the art's 5:7.

It went through two earlier states worth knowing about, because both left
traces:

- **Drawn faces, then public-domain court images.** The faces were originally
  generated from the palette, then the twelve J/Q/K were swapped for the
  traditional French-pattern figures while the rest stayed drawn. That is
  where the "hide the drawn face and switch off the card's own border for
  cards that carry their own frame" logic came from — it now applies to all
  52 rather than twelve.
- **Pips are drawn, not typed.** They started as the Unicode suit characters
  and the heart came out visibly different from the other three: the glyphs
  resolve through font fallback and the four do not all land in the same
  font, which also means they would differ again on someone else's machine.
  `suitPaths` + the `SuitPip` component replaced them. The bundled deck has
  made them redundant on the cards, but `SuitPip` is still what draws the
  ghosted suits on the empty foundations, and it is what a deck without its
  own indexes would need.

**The win cascade paints the real cards.** A `Canvas` can only draw an image
it has already loaded, so `paintCard()` requests the card on its first tick
and paints nothing; the next tick has it. Cards fly one at a time, so that is
one load per card and cached after.

## Gotchas hit while building this

- **`cardW` binding loop.** The table `Item`'s `anchors.margins` originally
  read `root.cardW`, and `cardW` is measured off that same item's width.
  Margins now derive from the felt rectangle instead. Anything that sizes the
  table must not read a card dimension.
- **A hidden binding still evaluates.** The foundation ghost-suit `Text` had
  `visible: slot >= 2 && slot < 6` but an unguarded `suitGlyphs[slot - 2]`,
  which assigned `undefined` to a string on every layout change for the other
  nine slots. Guard the expression, not just the visibility.
- **QML property names cannot start with a capital.** `readonly property var L`
  will not parse.
- **wtype is useless here.** `wtype -k space` swaps the seat keymap, and the
  client resolves the keycode against whichever keymap it has at that moment —
  the presses arrived as different keys entirely (it set draw-3 and dealt new
  games). The kbd noise in the journal is that, not a shell bug. Test keys on
  a real keyboard.
- **Panel instances can be rebuilt.** State is written to disk after each move
  (debounced 400ms), and `restoreGame()` validates that the file still holds a
  full unduplicated deck before trusting it. A half-written or hand-edited
  file deals a fresh game instead of half of one.

## Plugin plumbing

- `panel` + `bar-widget`, so it carries the usual `ensureSelfReference()`
  workaround: `omarchy plugin enable` writes only the bar layout entry, and
  without a `plugins[]` entry the keybinding dies with the bar icon. Upstream
  fix is PR #6510 — drop this once that lands.
- `keepLoaded: true` is load-bearing. Without it the host's Loader destroys
  the panel on hide and the game in progress goes with it.
- Installed as a symlink for development, which means **no hot reload** —
  `omarchy-restart-shell` after every QML edit. Never `omarchy-refresh-shell`.

## Ideas, not committed to

- Vegas scoring as an alternative to standard.
- Right-click as "send to foundation" so left-click stays purely drag.
- Seeded deals ("deal #1234") so a hand can be replayed or shared.
- Spider / FreeCell as sibling kinds in the same panel.
