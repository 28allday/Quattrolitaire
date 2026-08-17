# Deck artwork

The 52 card faces and the table tile in this folder are original artwork made
for this project — an art-deco series, one car per card, generated with an
image model and then indexed by hand so the rank and suit marks stay sharp and
correct at small sizes.

The card back started life as an Omarchy wallpaper by **vulturetone**:
`1-quattro.jpg` from the stock `tokyo-night` theme, which is where this plugin
got its name. Reframed for the card here, and credited with thanks.

## Files

`AH.png` … `KS.png` are the 52 faces. The filename is the standard card code:
ranks `A`, `2`–`10`, `J`, `Q`, `K`; suits `H` hearts, `D` diamonds, `C`
clubs, `S` spades. `Panel.qml` builds that code straight from its own rank
and suit tables, so a card's file is found by name alone.

`back.png` is the shared face-down back: a rally-car scene at sunset, from an
Omarchy wallpaper by **vulturetone** (`tokyo-night/backgrounds/1-quattro.jpg`,
5120 × 2880). The framing, extension and resizing described next are the only
part done here — the card works from a 2696 × 2880 crop of the wallpaper,
which keeps the car and drops the sun and the banner to its right.

The crop is nearly square, and the deck is a strict 5:7, so it was
extended rather than cropped — cropping to fit cut either the front bumper or
the rear wing. The top sky band and the bottom ground band were mirrored
outward, blurred and graded darker toward the edges, giving a 5:7 canvas with
the whole car intact. Source and a 530 × 742 master are archived with the
other deck originals, outside this repo.

Reproduce from a source render of any size, `TOP`/`BOT` being the extension
that brings it to 5:7:

```bash
magick src.jpg -crop ${W}x${TOP}+0+0 +repage -flip -blur 0x14 \
  \( -size ${W}x${TOP} gradient:'gray45'-'white' \) -compose multiply -composite top.png
magick src.jpg -crop ${W}x${BOT}+0+$((H-BOT)) +repage -flip -blur 0x14 \
  \( -size ${W}x${BOT} gradient:'white'-'gray40' \) -compose multiply -composite bot.png
magick top.png src.jpg bot.png -append 5x7.png
magick 5x7.png -resize 400x560! -strip \
  -fill none -stroke '#0d0a1a' -strokewidth 8 -draw "roundrectangle 4,4,395,555,15,15" \
  -stroke '#c9a24a' -strokewidth 1.5 -draw "roundrectangle 12,12,387,547,10,10" \
  \( -size 400x560 xc:black -fill white -draw "roundrectangle 0,0,399,559,17,17" -alpha off \) \
  -compose copy_opacity -composite back.png
```

Unlike the faces it stays truecolour — the sunset gradient bands badly when
quantised to 256 colours.

`table.png` is a seamless tile for the table surface, drawn over the theme
felt rather than instead of it, so the felt still shows at the edges and
stands in if the file is gone. One repeat lands at about a third of the
table's width — the multiplier is on `tableTile.tileSize` in `Panel.qml`.

## Format

400 × 560, an exact 5:7 ratio, RGBA PNG with transparent rounded corners.
`cardH` in `Panel.qml` is `cardW * 1.4` to match — change the aspect of the
art and that constant has to move with it.

The originals are 530 × 742 and live outside this repo in
`famous-cars-solitaire-deck`, along with the manifest, contact sheet and
generation notes. Shipping them as-is would put 39MB into every clone, so
each was resized once and quantised to 256 colours — painted art at card
size, so nothing visible is lost — bringing the set to ~5.3MB.

Reproduce with:

```bash
magick <original>.png -resize 400x560 -strip -colors 256 PNG8:<card>.png
```

## Replacing the deck

Drop in 54 files with these names and nothing else needs to change. If the
new art has its own aspect ratio, update `cardH`; if it does not carry its
own rank and suit indexes, they will need drawing back onto the card in
`Panel.qml` — the `SuitPip` component is still there, used for the ghosted
suits on the empty foundations.
