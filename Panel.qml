import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// Klondike solitaire for omarchy-shell. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle nosignal.quattrolitaire
// The host calls open(payloadJson) / close() and reads `opened`; it also
// injects `shell` right after the Loader resolves (see onShellChanged).
//
// The cards are bundled artwork in cards/ — one PNG per card plus a shared
// back, named by card code. Everything around them is drawn from the live
// theme palette, so the felt, the pile outlines and the panel chrome recolour
// with the desktop while the deck stays as painted.
//
// The model is deliberately dumb and flat. A card is an integer 0-51:
//   suit = cid / 13   (0 spades, 1 hearts, 2 diamonds, 3 clubs)
//   rank = cid % 13 + 1  (1 ace … 13 king)
// A pile is an array of those integers, bottom card first, and `faceUp` is one
// flat array of 52 booleans. Every pile mutation goes through a clone-then-
// assign helper and ends in touch(), which bumps `rev`; `layout` is a single
// binding on `rev` that turns the whole model into 52 {x,y,z,pile} records.
// Card delegates bind their geometry to that record, so a move is applied to
// the arrays and animates itself — nothing imperatively positions a card.
//
// `keepLoaded: true` in manifest.json matters here: without it the host's
// Loader destroys this instance on hide and the game in progress would be
// wiped on every close. State is also written to disk after each move, so a
// half-finished game survives omarchy-restart-shell as well.
Item {
  id: root

  property bool opened: false

  readonly property string selfId: "nosignal.quattrolitaire"

  // Injected by the shell host after the Loader resolves. Used to keep the
  // host's open-flag honest on close(), and to self-restore if the host's
  // panel Instantiator rebuild destroys a visibly-open instance.
  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  // ------------------------------------------------------------------ theme
  //
  // Shares the [menu] surface tokens so themes that style the menu style this
  // panel too — same approach as the sibling nosignal.* panels. The felt is
  // derived from the palette rather than pinned, so the table sits under the
  // deck rather than fighting it on a light theme or a dark one.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding

  function lum(c) { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t,
                   a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, 1)
  }
  readonly property bool darkSurface: root.lum(root.background) < 0.5
  readonly property color felt: root.mix(root.darkSurface ? Qt.darker(root.background, 1.45)
                                                          : Qt.darker(root.background, 1.10),
                                         root.accent, 0.10)
  readonly property color feltLine: root.mix(root.felt, root.foreground, 0.22)

  // ------------------------------------------------------- self-registration

  // `omarchy plugin enable` only writes the bar.layout entry for a
  // panel+bar-widget plugin, so the keybinding dies with the bar icon unless
  // the plugin claims its own plugins[] entry. Upstream fix is PR #6510; until
  // it lands, self-register on first open. Idempotent, jq-guarded.
  //
  // Harness: sh -c <script> plugin-selfref <id> — $0 is the label, $1 the id.
  // The id arrives as an argument rather than spliced into the script, so no
  // text is ever interpolated into shell code. The rewrite refuses to follow a
  // symlink, keeps the working copy private, and carries the original file's
  // mode across so a hand-tightened shell.json is not widened by the swap.
  property bool selfRefEnsured: false
  readonly property string ensureSelfRefScript: [
    'umask 077',
    'id="$1"',
    'f="$HOME/.config/omarchy/shell.json"',
    '[ -f "$f" ] || exit 0',
    '[ -L "$f" ] && exit 0',
    'jq -e --arg id "$id" \'any(.plugins[]?; (.id // empty) == $id)\' "$f" >/dev/null && exit 0',
    'tmp="$f.selfref.$$"',
    'jq --arg id "$id" \'.plugins = ((.plugins // []) + [{id: $id}])\' "$f" > "$tmp" || {',
    '  rm -f "$tmp"; exit 1;',
    '}',
    '[ -s "$tmp" ] || { rm -f "$tmp"; exit 1; }',
    'chmod --reference="$f" "$tmp" 2>/dev/null || chmod 600 "$tmp"',
    'mv "$tmp" "$f"'
  ].join("\n")

  function ensureSelfReference() {
    if (root.selfRefEnsured) return
    root.selfRefEnsured = true
    Quickshell.execDetached(["sh", "-c", root.ensureSelfRefScript, "plugin-selfref", root.selfId])
  }

  // ------------------------------------------------------------- game model

  property var stock: []                       // face down, last element = top
  property var waste: []                       // face up, last element = top
  property var found: [[], [], [], []]         // foundations, any suit per pile
  property var tabl: [[], [], [], [], [], [], []]
  property var faceUp: []                      // 52 booleans, indexed by cid
  property int drawCount: 1                    // 1 or 3
  property int score: 0
  property int moves: 0
  property int seconds: 0
  property int passes: 0                       // times the waste was recycled
  property int winBonus: 0
  property bool started: false
  property bool won: false
  property var history: []                     // JSON snapshots, newest last
  property var stats: ({ played: 0, won: 0, best: 0, bestTime: 0 })

  // Bumped by touch() after every model mutation; `layout` binds to it.
  property int rev: 0
  function touch() { root.rev++ }

  // Suits are drawn, not typed. The Unicode suit characters come from
  // whichever font in the fallback chain happens to own them, and that is not
  // the same font for all four — hearts arrived outlined while the other three
  // were solid — nor the same on anyone else's machine. These are outlines in
  // a 100x100 box, filled by Shape, so all four match at any size and take
  // their colour from the theme.
  readonly property var suitPaths: [
    // spade: inverted heart over a splayed stem
    "M 50 6 C 50 6 94 40 94 60 C 94 72 85 80 75 80 C 66 80 58 74 55 66"
    + " C 55 74 58 86 65 94 L 35 94 C 42 86 45 74 45 66 C 42 74 34 80 25 80"
    + " C 15 80 6 72 6 60 C 6 40 50 6 50 6 Z",
    // heart
    "M 50 92 C 50 92 6 61 6 33 C 6 18 18 8 30 8 C 40 8 47 14 50 21"
    + " C 53 14 60 8 70 8 C 82 8 94 18 94 33 C 94 61 50 92 50 92 Z",
    // diamond
    "M 50 5 L 91 50 L 50 95 L 9 50 Z",
    // club: three lobes over a stem
    "M 50 5 C 61 5 70 14 70 25 C 70 29 69 33 67 36 C 70 34 74 33 78 33"
    + " C 89 33 98 42 98 53 C 98 64 89 73 78 73 C 68 73 60 66 58 57"
    + " C 57 68 60 84 66 95 L 34 95 C 40 84 43 68 42 57 C 40 66 32 73 22 73"
    + " C 11 73 2 64 2 53 C 2 42 11 33 22 33 C 26 33 30 34 33 36"
    + " C 31 33 30 29 30 25 C 30 14 39 5 50 5 Z"
  ]

  // A suit, filled, scaled into whatever box it is given.
  component SuitPip: Item {
    id: pipRoot
    property int suit: 0
    property color pipColor: "#000000"
    Shape {
      width: 100
      height: 100
      transform: Scale {
        xScale: pipRoot.width / 100
        yScale: pipRoot.height / 100
      }
      ShapePath {
        fillColor: pipRoot.pipColor
        strokeWidth: 0
        strokeColor: "transparent"
        PathSvg { path: root.suitPaths[pipRoot.suit] }
      }
    }
  }
  readonly property var rankNames: ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]

  function suitOf(cid) { return Math.floor(cid / 13) }
  function rankOf(cid) { return (cid % 13) + 1 }
  function isRed(cid) { var s = root.suitOf(cid); return s === 1 || s === 2 }
  function topOf(pile) { return (pile && pile.length) ? pile[pile.length - 1] : -1 }

  function cloneT() {
    var o = []
    for (var i = 0; i < 7; i++) o.push(root.tabl[i].slice())
    return o
  }
  function cloneF() {
    var o = []
    for (var i = 0; i < 4; i++) o.push(root.found[i].slice())
    return o
  }

  // --------------------------------------------------------------- new game

  function newGame() {
    var deck = []
    var i
    for (i = 0; i < 52; i++) deck.push(i)
    for (i = 51; i > 0; i--) {                 // Fisher-Yates
      var k = Math.floor(Math.random() * (i + 1))
      var swap = deck[i]; deck[i] = deck[k]; deck[k] = swap
    }

    var up = []
    for (i = 0; i < 52; i++) up.push(false)

    var tab = [[], [], [], [], [], [], []]
    var p = 0
    for (var c = 0; c < 7; c++) {
      for (var r = 0; r <= c; r++) {
        tab[c].push(deck[p])
        if (r === c) up[deck[p]] = true        // only the last card of each pile
        p++
      }
    }

    root.tabl = tab
    root.stock = deck.slice(p)
    root.waste = []
    root.found = [[], [], [], []]
    root.faceUp = up
    root.score = 0
    root.moves = 0
    root.seconds = 0
    root.passes = 0
    root.winBonus = 0
    root.won = false
    root.started = true
    root.history = []
    root.dragCids = []
    root.autoRunning = false
    root.cancelFlip()
    root.stats = { played: root.stats.played + 1, won: root.stats.won,
                   best: root.stats.best, bestTime: root.stats.bestTime }
    stopCascade()
    root.touch()
    root.save()
  }

  // ----------------------------------------------------------------- undo

  function snapshot() {
    return JSON.stringify({
      s: root.stock, w: root.waste, f: root.found, t: root.tabl, u: root.faceUp,
      sc: root.score, mv: root.moves, ps: root.passes
    })
  }

  function pushHistory() {
    var h = root.history.slice()
    h.push(root.snapshot())
    if (h.length > 400) h.shift()
    root.history = h
  }

  function undo() {
    if (root.won || root.autoRunning || root.history.length === 0) return
    root.cancelFlip()
    var h = root.history.slice()
    var st = JSON.parse(h.pop())
    root.history = h
    root.stock = st.s
    root.waste = st.w
    root.found = st.f
    root.tabl = st.t
    root.faceUp = st.u
    root.score = st.sc
    root.moves = st.mv
    root.passes = st.ps
    root.dragCids = []
    root.touch()
    root.save()
  }

  // ------------------------------------------------------------ legal moves

  function canPlaceOnFoundation(fi, cid) {
    var pile = root.found[fi]
    if (pile.length === 0) return root.rankOf(cid) === 1
    var t = root.topOf(pile)
    return root.suitOf(t) === root.suitOf(cid) && root.rankOf(cid) === root.rankOf(t) + 1
  }

  function canPlaceOnColumn(ci, cid) {
    var col = root.tabl[ci]
    if (col.length === 0) return root.rankOf(cid) === 13
    var t = root.topOf(col)
    if (root.faceUp[t] !== true) return false
    return root.isRed(t) !== root.isRed(cid) && root.rankOf(cid) === root.rankOf(t) - 1
  }

  // Scoring is the familiar standard-Klondike table: +10 onto a foundation,
  // +5 for waste-to-tableau, +5 for turning a tableau card face up, -15 for
  // taking a card back off a foundation, and a recycle penalty that is much
  // harsher in draw-1 because there is nothing to think about.
  function scoreFor(src, dst) {
    if (dst.charAt(0) === "f") return 10
    if (src === "w" && dst.charAt(0) === "t") return 5
    if (src.charAt(0) === "f" && dst.charAt(0) === "t") return -15
    return 0
  }

  function takeFrom(src, count) {
    if (src === "w") {
      var w = root.waste.slice()
      w.splice(w.length - count, count)
      root.waste = w
      return
    }
    var i = parseInt(src.substring(1))
    if (src.charAt(0) === "f") {
      var f = root.cloneF()
      f[i].splice(f[i].length - count, count)
      root.found = f
      return
    }
    var t = root.cloneT()
    t[i].splice(t[i].length - count, count)
    root.tabl = t
  }

  // ------------------------------------------------------------ turning over
  //
  // A move that empties a slot exposes a face-down card, and it turns over —
  // worth +5, same as the original. The timing is the point: the flip waits
  // for the moved card to land and then turns the card over on screen, rather
  // than snapping it face up the instant the mouse button comes up, which
  // reads as the card flipping while you are still holding the other one.
  property int flipCard: -1          // the card mid-turn, if any
  property int pendingFlipCol: -1    // column owed a flip once its card lands
  property real flipScale: 1

  function applyFlip(ci) {
    if (ci < 0) return
    var col = root.tabl[ci]
    if (col.length === 0) return
    var t = col[col.length - 1]
    if (root.faceUp[t] === true) return   // idempotent, so flushing is safe
    var u = root.faceUp.slice()
    u[t] = true
    root.faceUp = u
    root.score += 5
    root.touch()
    root.save()
  }

  function scheduleFlip(ci) {
    var col = root.tabl[ci]
    if (col.length === 0) return
    if (root.faceUp[col[col.length - 1]] === true) return
    root.pendingFlipCol = ci
    flipDelay.restart()
  }

  // Anything that moves the model on must resolve an owed flip first, so a
  // snapshot or a following move never sees a half-finished one.
  function flushFlip() {
    if (flipAnim.running) {
      var mid = flipAnim.column
      flipAnim.stop()
      root.flipScale = 1
      root.flipCard = -1
      root.applyFlip(mid)
    }
    if (root.pendingFlipCol >= 0) {
      flipDelay.stop()
      var ci = root.pendingFlipCol
      root.pendingFlipCol = -1
      root.applyFlip(ci)
    }
  }

  // Undo and a new deal drop the flip instead: the state they restore already
  // says whether that card is face up.
  function cancelFlip() {
    flipDelay.stop()
    flipAnim.stop()
    root.pendingFlipCol = -1
    root.flipCard = -1
    root.flipScale = 1
  }

  Timer {
    id: flipDelay
    interval: 150                       // just past the 130ms card-landing move
    onTriggered: {
      var ci = root.pendingFlipCol
      root.pendingFlipCol = -1
      if (ci < 0) return
      var col = root.tabl[ci]
      if (col.length === 0) return
      var t = col[col.length - 1]
      if (root.faceUp[t] === true) return
      root.flipCard = t
      flipAnim.column = ci
      flipAnim.restart()
    }
  }

  // Turn on the card's vertical axis, swapping back for face at the point
  // where the card is edge-on and nothing of either side is visible.
  SequentialAnimation {
    id: flipAnim
    property int column: -1
    NumberAnimation {
      target: root; property: "flipScale"; from: 1; to: 0
      duration: 90; easing.type: Easing.InQuad
    }
    ScriptAction { script: root.applyFlip(flipAnim.column) }
    NumberAnimation {
      target: root; property: "flipScale"; from: 0; to: 1
      duration: 110; easing.type: Easing.OutQuad
    }
    ScriptAction { script: root.flipCard = -1 }
  }

  // The single mutation path for moving cards. `cids` is a run in stacking
  // order (bottom first); foundations only ever receive a run of one.
  function doMove(cids, src, dst) {
    root.flushFlip()          // settle anything the previous move still owes
    root.pushHistory()
    root.takeFrom(src, cids.length)

    var i
    if (dst.charAt(0) === "f") {
      var f = root.cloneF()
      f[parseInt(dst.substring(1))].push(cids[0])
      root.found = f
    } else {
      var ti = parseInt(dst.substring(1))
      var t = root.cloneT()
      for (i = 0; i < cids.length; i++) t[ti].push(cids[i])
      root.tabl = t
    }

    var u = root.faceUp.slice()
    for (i = 0; i < cids.length; i++) u[cids[i]] = true
    root.faceUp = u

    root.score = Math.max(0, root.score + root.scoreFor(src, dst))
    if (src.charAt(0) === "t") root.scheduleFlip(parseInt(src.substring(1)))
    root.moves++
    root.checkWin()
    root.touch()
    root.save()
  }

  function tryFoundation(cid, src) {
    for (var f = 0; f < 4; f++) {
      if (root.canPlaceOnFoundation(f, cid)) { root.doMove([cid], src, "f" + f); return true }
    }
    return false
  }

  // A tap on a card is a shortcut for "send this to a foundation if it fits" —
  // the one move nobody ever wants to drag.
  function tapCard(cid, pile) {
    if (root.won || root.autoRunning) return
    if (pile.charAt(0) === "f") return
    if (pile.charAt(0) === "t") {
      var col = root.tabl[parseInt(pile.substring(1))]
      if (root.topOf(col) !== cid) return      // only the exposed card
    } else if (pile === "w") {
      if (root.topOf(root.waste) !== cid) return
    } else return
    root.tryFoundation(cid, pile)
  }

  function draw() {
    if (root.won || root.autoRunning) return
    root.flushFlip()

    if (root.stock.length === 0) {
      if (root.waste.length === 0) return
      root.pushHistory()
      root.stock = root.waste.slice().reverse()
      root.waste = []
      root.passes++
      root.score = Math.max(0, root.score - (root.drawCount === 1 ? 100 : 20))
      root.moves++
      root.touch()
      root.save()
      return
    }

    root.pushHistory()
    var n = Math.min(root.drawCount, root.stock.length)
    var st = root.stock.slice()
    var w = root.waste.slice()
    var u = root.faceUp.slice()
    for (var i = 0; i < n; i++) {
      var c = st.pop()                          // flipping reverses the order,
      w.push(c)                                 // exactly as it does on a table
      u[c] = true
    }
    root.stock = st
    root.waste = w
    root.faceUp = u
    root.moves++
    root.touch()
    root.save()
  }

  function setDrawCount(n) {
    if (root.drawCount === n) return
    root.drawCount = n
    root.save()
    root.touch()
  }

  // --------------------------------------------------------------- finishing

  // Offered once every card is face up: from there the game is decided and
  // clicking it out card by card is busywork.
  readonly property bool canAuto: {
    root.rev
    if (!root.started || root.won) return false
    for (var t = 0; t < 7; t++) {
      var col = root.tabl[t]
      for (var i = 0; i < col.length; i++) if (root.faceUp[col[i]] !== true) return false
    }
    return true
  }

  property bool autoRunning: false
  property int autoIdle: 0

  function startAuto() {
    if (!root.canAuto || root.won) return
    root.autoIdle = 0
    root.autoRunning = true
  }

  function autoStep() {
    if (root.won) { root.autoRunning = false; return }

    var c = root.topOf(root.waste)
    if (c >= 0 && root.tryFoundation(c, "w")) { root.autoIdle = 0; return }

    for (var t = 0; t < 7; t++) {
      var col = root.tabl[t]
      if (col.length && root.tryFoundation(col[col.length - 1], "t" + t)) { root.autoIdle = 0; return }
    }

    // Nothing playable from the tops: turn the stock over and look again. The
    // idle counter is the stop condition — one full cycle of the stock with no
    // foundation move means the rest of the deal is genuinely stuck.
    if (root.stock.length > 0 || root.waste.length > 0) {
      if (root.autoIdle > root.stock.length + root.waste.length + 2) { root.autoRunning = false; return }
      root.autoIdle++
      root.draw()
      return
    }
    root.autoRunning = false
  }

  Timer {
    id: autoTimer
    interval: 90
    repeat: true
    running: root.autoRunning && root.opened
    onTriggered: root.autoStep()
  }

  function checkWin() {
    for (var f = 0; f < 4; f++) if (root.found[f].length !== 13) return
    root.won = true
    root.autoRunning = false
    root.winBonus = root.seconds > 30 ? Math.floor(700000 / root.seconds) : 0
    root.score += root.winBonus
    root.stats = {
      played: root.stats.played,
      won: root.stats.won + 1,
      best: Math.max(root.stats.best, root.score),
      bestTime: (root.stats.bestTime === 0 || root.seconds < root.stats.bestTime)
                  ? root.seconds : root.stats.bestTime
    }
    root.startCascade()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.started && !root.won
    onTriggered: root.seconds++
  }

  function timeText() {
    var m = Math.floor(root.seconds / 60)
    var s = root.seconds % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  // ------------------------------------------------------------- persistence

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: root.home + "/.local/state/omarchy-quattrolitaire"
  readonly property string statePath: root.stateDir + "/state.json"
  property bool stateLoaded: false

  function save() {
    if (!root.stateLoaded) return
    saveTimer.restart()
  }

  // Debounced: autocomplete fires a move every 90ms and each one would
  // otherwise be its own atomic file write.
  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: {
      var payload = JSON.stringify({
        version: 1,
        drawCount: root.drawCount,
        stats: root.stats,
        game: (root.started && !root.won) ? {
          s: root.stock, w: root.waste, f: root.found, t: root.tabl, u: root.faceUp,
          sc: root.score, mv: root.moves, ps: root.passes, sec: root.seconds
        } : null
      }, null, 2) + "\n"
      stateFile.setText(payload)
    }
  }

  // A saved game is only restored if it still holds a full, unduplicated deck —
  // a truncated or hand-edited file deals a fresh game instead of half a one.
  function restoreGame(g) {
    if (!g || typeof g !== "object") return false
    var seen = []
    var i
    for (i = 0; i < 52; i++) seen.push(false)

    function claim(pile) {
      if (!Array.isArray(pile)) return false
      for (var j = 0; j < pile.length; j++) {
        var v = pile[j]
        if (typeof v !== "number" || v < 0 || v > 51 || seen[v]) return false
        seen[v] = true
      }
      return true
    }

    if (!claim(g.s) || !claim(g.w)) return false
    if (!Array.isArray(g.f) || g.f.length !== 4) return false
    if (!Array.isArray(g.t) || g.t.length !== 7) return false
    for (i = 0; i < 4; i++) if (!claim(g.f[i])) return false
    for (i = 0; i < 7; i++) if (!claim(g.t[i])) return false
    for (i = 0; i < 52; i++) if (!seen[i]) return false
    if (!Array.isArray(g.u) || g.u.length !== 52) return false

    var up = []
    for (i = 0; i < 52; i++) up.push(g.u[i] === true)

    root.stock = g.s
    root.waste = g.w
    root.found = [g.f[0], g.f[1], g.f[2], g.f[3]]
    root.tabl = [g.t[0], g.t[1], g.t[2], g.t[3], g.t[4], g.t[5], g.t[6]]
    root.faceUp = up
    root.score = Math.max(0, Number(g.sc) || 0)
    root.moves = Math.max(0, Number(g.mv) || 0)
    root.passes = Math.max(0, Number(g.ps) || 0)
    root.seconds = Math.max(0, Number(g.sec) || 0)
    root.won = false
    root.started = true
    root.history = []
    root.cancelFlip()
    root.touch()
    return true
  }

  function applyState(raw) {
    var st = null
    try { st = JSON.parse(String(raw || "").trim()) } catch (e) {}

    if (st && typeof st === "object") {
      if (Number(st.drawCount) === 3) root.drawCount = 3
      if (st.stats && typeof st.stats === "object") {
        root.stats = {
          played: Math.max(0, Number(st.stats.played) || 0),
          won: Math.max(0, Number(st.stats.won) || 0),
          best: Math.max(0, Number(st.stats.best) || 0),
          bestTime: Math.max(0, Number(st.stats.bestTime) || 0)
        }
      }
      if (root.restoreGame(st.game)) { root.stateLoaded = true; return }
    }

    root.stateLoaded = true
    root.newGame()
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyState(text())
    onLoadFailed: function(err) { root.applyState("") }
  }

  // Make sure the state dir exists, then (re)load the state file.
  Process {
    id: mkStateDir
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.reload()
  }

  Component.onCompleted: mkStateDir.running = true

  // ------------------------------------------------------------- open/close

  function open(payloadJson) {
    root.opened = true
    root.ensureSelfReference()
    if (root.stateLoaded && !root.started) root.newGame()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    root.dragCids = []
    root.autoRunning = false
    root.flushFlip()
    // A finished game is history the moment you look away: the next open
    // deals rather than greeting you with the scoreboard you already read.
    if (root.won) root.newGame()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // ------------------------------------------------------------------ layout
  //
  // One pure function turns the model into 52 positioned records plus the drop
  // rectangles. Everything visual reads out of here, so the table stays
  // consistent between what you see, what you can grab and where a card lands.

  readonly property real tableW: table.width
  readonly property real tableH: table.height

  // Seven columns across, and enough height for the top row plus a tableau
  // deep enough to be worth looking at. Whichever axis is tighter wins.
  readonly property int cardW: {
    var byWidth = root.tableW / 7.84
    var byHeight = (root.tableH / 3.15) / 1.4
    return Math.max(20, Math.floor(Math.min(byWidth, byHeight)))
  }
  // 5:7, the aspect the bundled deck is drawn at.
  readonly property int cardH: Math.round(root.cardW * 1.4)

  readonly property var layout: root.computeLayout(root.rev, root.cardW, root.cardH,
                                                   root.tableW, root.tableH, root.drawCount)

  function computeLayout(rev, cw, ch, tw, th, draw) {
    var cards = []
    var i
    for (i = 0; i < 52; i++) cards.push({ x: 0, y: 0, z: 0, up: false, pile: "none", idx: -1 })

    var gap = Math.max(2, Math.round(cw * 0.14))
    var gridW = 7 * cw + 6 * gap
    var mx = Math.max(0, Math.round((tw - gridW) / 2))
    var colX = []
    for (i = 0; i < 7; i++) colX.push(mx + i * (cw + gap))

    var topY = 0
    var tabY = Math.round(ch * 1.34)

    // Stock, column 0. Face down, a shallow stack so the pile has depth.
    for (i = 0; i < root.stock.length; i++) {
      cards[root.stock[i]] = { x: colX[0], y: topY, z: 10 + i, up: false, pile: "s", idx: i }
    }

    // Waste, column 1. In draw-3 the last three fan right so you can see what
    // is buried under the playable card.
    var fanN = draw === 3 ? 3 : 1
    var wStep = Math.round(cw * 0.28)
    var wn = root.waste.length
    for (i = 0; i < wn; i++) {
      var slot = Math.min(Math.max(0, i - (wn - fanN)), fanN - 1)
      cards[root.waste[i]] = { x: colX[1] + slot * wStep, y: topY, z: 100 + i, up: true, pile: "w", idx: i }
    }

    // Foundations, columns 3-6.
    for (var f = 0; f < 4; f++) {
      var fp = root.found[f]
      for (i = 0; i < fp.length; i++)
        cards[fp[i]] = { x: colX[3 + f], y: topY, z: 200 + f * 20 + i, up: true, pile: "f" + f, idx: i }
    }

    // Tableau. Fan offsets shrink per column so a deep pile still fits the
    // table instead of running off the bottom of the panel.
    var availH = Math.max(ch, th - tabY)
    var colH = []
    for (var t = 0; t < 7; t++) {
      var col = root.tabl[t]
      var downN = 0, upN = 0
      for (i = 0; i < col.length; i++) {
        if (root.faceUp[col[i]] === true) upN++
        else downN++
      }

      var dStep = Math.max(2, Math.round(ch * 0.11))
      var uStep = Math.max(3, Math.round(ch * 0.27))
      var need = downN * dStep + Math.max(0, upN - 1) * uStep + ch
      if (need > availH) {
        var slack = Math.max(1, need - ch)
        var shrink = Math.max(0.18, (availH - ch) / slack)
        dStep = Math.max(1, Math.floor(dStep * shrink))
        uStep = Math.max(2, Math.floor(uStep * shrink))
      }

      var y = tabY
      var lastY = tabY
      for (i = 0; i < col.length; i++) {
        var cid = col[i]
        var isUp = root.faceUp[cid] === true
        cards[cid] = { x: colX[t], y: y, z: 300 + t * 30 + i, up: isUp, pile: "t" + t, idx: i }
        lastY = y
        y += isUp ? uStep : dStep
      }
      colH.push(Math.max(ch, lastY - tabY + ch))
    }

    return { cards: cards, colX: colX, colH: colH, topY: topY, tabY: tabY,
             gap: gap, wStep: wStep, fanN: fanN, cw: cw, ch: ch }
  }

  // ---------------------------------------------------------------- dragging

  property var dragCids: []     // run being carried, bottom card first
  property var dragBase: []     // where each of them started, table coords
  property string dragFrom: ""
  property real dragDX: 0
  property real dragDY: 0
  property bool dragMoved: false
  readonly property bool dragging: root.dragCids.length > 0

  function dragIndexOf(cids, cid) {
    for (var i = 0; i < cids.length; i++) if (cids[i] === cid) return i
    return -1
  }

  // What can be picked up: the exposed waste card, the top of a foundation
  // (taking one back is legal and sometimes necessary), and any face-up
  // tableau card, which brings the ordered run below it along.
  function beginDrag(cid) {
    if (root.won || root.autoRunning) return false
    var info = root.layout.cards[cid]
    if (!info || info.pile === "none" || info.pile === "s") return false

    var run = []
    if (info.pile === "w") {
      if (root.topOf(root.waste) !== cid) return false
      run = [cid]
    } else if (info.pile.charAt(0) === "f") {
      var fp = root.found[parseInt(info.pile.substring(1))]
      if (root.topOf(fp) !== cid) return false
      run = [cid]
    } else {
      if (root.faceUp[cid] !== true) return false
      var col = root.tabl[parseInt(info.pile.substring(1))]
      run = col.slice(info.idx)
    }

    var base = []
    for (var i = 0; i < run.length; i++) {
      var ri = root.layout.cards[run[i]]
      base.push({ x: ri.x, y: ri.y })
    }

    root.dragCids = run
    root.dragBase = base
    root.dragFrom = info.pile
    root.dragDX = 0
    root.dragDY = 0
    root.dragMoved = false
    return true
  }

  function cancelDrag() {
    root.dragCids = []
    root.dragBase = []
    root.dragFrom = ""
    root.dragDX = 0
    root.dragDY = 0
  }

  function overlap(ax, ay, aw, ah, bx, by, bw, bh) {
    var w = Math.min(ax + aw, bx + bw) - Math.max(ax, bx)
    var h = Math.min(ay + ah, by + bh) - Math.max(ay, by)
    return (w > 0 && h > 0) ? w * h : 0
  }

  // Drop by overlap area rather than by cursor position: a card released half
  // over a column goes where it looks like it is going.
  function dropDrag() {
    if (!root.dragging) { root.cancelDrag(); return }

    var lead = root.dragCids[0]
    var rx = root.dragBase[0].x + root.dragDX
    var ry = root.dragBase[0].y + root.dragDY
    var L = root.layout

    var bestScore = 0
    var bestDst = ""

    var i, area
    if (root.dragCids.length === 1) {
      for (i = 0; i < 4; i++) {
        if (!root.canPlaceOnFoundation(i, lead)) continue
        if ("f" + i === root.dragFrom) continue
        area = root.overlap(rx, ry, root.cardW, root.cardH,
                            L.colX[3 + i], L.topY, root.cardW, root.cardH)
        if (area > bestScore) { bestScore = area; bestDst = "f" + i }
      }
    }

    for (i = 0; i < 7; i++) {
      if ("t" + i === root.dragFrom) continue
      if (!root.canPlaceOnColumn(i, lead)) continue
      area = root.overlap(rx, ry, root.cardW, root.cardH,
                          L.colX[i], L.tabY, root.cardW, L.colH[i])
      if (area > bestScore) { bestScore = area; bestDst = "t" + i }
    }

    var cids = root.dragCids.slice()
    var from = root.dragFrom

    // Order matters. A carried card is positioned by dragBase + delta and
    // only falls back to its layout slot when the drag clears — so clearing
    // first rebinds it to the slot it came FROM (the model is still
    // untouched), animating it home, and only then does the move land and
    // animate it out again. Move first, let go second: the card holds the
    // spot you dropped it on, and the single animation runs from there to
    // where it belongs.
    if (bestDst !== "") {
      root.doMove(cids, from, bestDst)
      root.cancelDrag()
    } else {
      root.cancelDrag()           // illegal drop: one animation, back home
      root.touch()
    }
  }

  // ------------------------------------------------------------- win cascade
  //
  // The traditional payoff: cards launch off the foundations, bounce, and
  // leave a trail. The trail is free — a QML Canvas keeps its buffer between
  // paints, so simply never clearing it paints the streak.

  property bool cascading: false
  property var cascadeQueue: []
  property var faller: null

  function startCascade() {
    var q = []
    for (var r = 12; r >= 0; r--)
      for (var f = 0; f < 4; f++)
        if (root.found[f].length > r) q.push(root.found[f][r])
    root.cascadeQueue = q
    root.faller = null
    root.cascading = true
    cascade.clear()
  }

  function stopCascade() {
    root.cascading = false
    root.cascadeQueue = []
    root.faller = null
    cascade.clear()
  }

  function stepCascade() {
    if (!root.faller) {
      if (root.cascadeQueue.length === 0) { root.cascading = false; return }
      var q = root.cascadeQueue.slice()
      var cid = q.shift()
      root.cascadeQueue = q
      var info = root.layout.cards[cid]
      var dir = Math.random() < 0.5 ? -1 : 1
      root.faller = {
        cid: cid,
        x: info ? info.x : root.tableW / 2,
        y: info ? info.y : 0,
        vx: dir * root.cardW * (0.04 + Math.random() * 0.06),
        vy: -root.cardH * 0.02
      }
    }

    var fl = root.faller
    fl.x += fl.vx
    fl.y += fl.vy
    fl.vy += root.cardH * 0.013

    var floor = root.tableH - root.cardH
    if (fl.y > floor) {
      fl.y = floor
      fl.vy = -fl.vy * 0.78
      if (Math.abs(fl.vy) < root.cardH * 0.02) fl.vy = -root.cardH * 0.02
    }

    cascade.paintCard(fl.cid, fl.x, fl.y)

    if (fl.x + root.cardW < -root.cardW || fl.x > root.tableW + root.cardW)
      root.faller = null
    else
      root.faller = fl
  }

  Timer {
    id: cascadeTimer
    interval: 16
    repeat: true
    running: root.cascading && root.opened && root.won
    onTriggered: root.stepCascade()
  }

  // --------------------------------------------------------------- card face
  //
  // Shared by the live delegates and the cascade canvas so a flying card looks
  // like the one it left behind.

  // The deck is bundled artwork in cards/, one PNG per card plus a shared
  // back — see cards/CREDITS.md. Files are named by the standard card code,
  // e.g. AH, 10D, QC, KS, which is exactly rankNames + suitLetters. The felt,
  // the pile outlines and the panel chrome are still generated from the
  // theme, so the table around the cards recolours with the desktop.
  readonly property var suitLetters: ["S", "H", "D", "C"]
  readonly property url backImage: Qt.resolvedUrl("cards/back.png")
  // Seamless tile for the table itself. Drawn over the theme felt rather than
  // instead of it, so the felt still shows at the edges and stands in if the
  // file is ever missing.
  readonly property url tableImage: Qt.resolvedUrl("cards/table.png")
  function cardCode(cid) {
    return root.rankNames[root.rankOf(cid) - 1] + root.suitLetters[root.suitOf(cid)]
  }
  function cardImage(cid) {
    return Qt.resolvedUrl("cards/" + root.cardCode(cid) + ".png")
  }

  // ------------------------------------------------------------------- panel

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-quattrolitaire"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: surface
      width: Math.min(Style.space(1060), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(760),
                       panel.height - Style.bar.sizeHorizontal - Style.gapsOut * 2)
      anchors.centerIn: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

      // Swallow clicks so the felt doesn't fall through to the close-on-click
      // backdrop.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
            root.close()
          } else if (event.key === Qt.Key_N) {
            root.newGame()
          } else if (event.key === Qt.Key_U || event.key === Qt.Key_Z) {
            root.undo()
          } else if (event.key === Qt.Key_A) {
            root.startAuto()
          } else if (event.key === Qt.Key_Space || event.key === Qt.Key_D) {
            root.draw()
          } else if (event.key === Qt.Key_1) {
            root.setDrawCount(1)
          } else if (event.key === Qt.Key_3) {
            root.setDrawCount(3)
          } else {
            return
          }
          event.accepted = true
        }
      }

      // ------------------------------------------------------------- header
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: surface.contentTopInset
        anchors.leftMargin: surface.contentLeftInset
        anchors.rightMargin: surface.contentRightInset
        height: Math.max(title.implicitHeight, controls.implicitHeight)

        Text {
          id: title
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "♠  Quattrolitaire"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Row {
          id: controls
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          Button {
            text: "New"
            bordered: true
            fontFamily: root.fontFamily
            tooltipText: "Deal a new game  (n)"
            onClicked: root.newGame()
          }
          Button {
            text: "Undo"
            bordered: true
            fontFamily: root.fontFamily
            tooltipText: "Take back the last move  (u)"
            enabled: root.history.length > 0 && !root.won && !root.autoRunning
            opacity: enabled ? 1 : 0.4
            onClicked: root.undo()
          }
          Button {
            text: root.autoRunning ? "Finishing…" : "Auto"
            bordered: true
            fontFamily: root.fontFamily
            tooltipText: "Play the rest out automatically  (a)"
            enabled: root.canAuto && !root.autoRunning
            opacity: enabled ? 1 : 0.4
            onClicked: root.startAuto()
          }
          Button {
            text: "Draw 1"
            bordered: true
            selected: root.drawCount === 1
            fontFamily: root.fontFamily
            tooltipText: "Turn one card at a time  (1)"
            onClicked: root.setDrawCount(1)
          }
          Button {
            text: "Draw 3"
            bordered: true
            selected: root.drawCount === 3
            fontFamily: root.fontFamily
            tooltipText: "Turn three at a time  (3)"
            onClicked: root.setDrawCount(3)
          }
        }
      }

      Item {
        id: statusRow
        anchors.top: header.bottom
        anchors.left: header.left
        anchors.right: header.right
        anchors.topMargin: Style.spacing.xs
        height: statusLeft.implicitHeight + Style.spacing.sm

        Text {
          id: statusLeft
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Score " + root.score + "   ·   Moves " + root.moves + "   ·   " + root.timeText()
            + (root.stats.won > 0 ? "   ·   Won " + root.stats.won + "/" + root.stats.played : "")
          color: root.foreground
          opacity: 0.65
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "drag to play · double-click sends a card up · esc close"
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator {
        id: sep
        anchors.top: statusRow.bottom
        anchors.left: header.left
        anchors.right: header.right
        anchors.topMargin: Style.spacing.sm
      }

      // -------------------------------------------------------------- table
      Rectangle {
        id: feltSurface
        anchors.top: sep.bottom
        anchors.left: header.left
        anchors.right: header.right
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.spacing.md
        anchors.bottomMargin: surface.contentBottomInset
        radius: Math.max(2, root.cornerRadius)
        color: root.felt
        clip: true

        // The table tile. sourceSize sets how big one repeat lands, since
        // Image.Tile repeats at the resolved source size rather than scaling
        // to fit — leaving it at the file's own 512 would put barely two
        // repeats across the table and read as a picture rather than a
        // surface.
        Image {
          id: tableTile
          // Held separately: pointing sourceSize.height at sourceSize.width
          // is a binding loop, the two being the same grouped property.
          readonly property int tileSize: Math.max(160, Math.round(feltSurface.width * 0.34))

          anchors.fill: parent
          source: root.tableImage
          fillMode: Image.Tile
          sourceSize.width: tableTile.tileSize
          sourceSize.height: tableTile.tileSize
          smooth: true
          cache: true
        }

        Item {
          id: table
          anchors.fill: parent
          // Derived from the felt, never from cardW: cardW is measured off
          // this item, so a margin that reads it back is a binding loop.
          anchors.margins: Math.max(Style.spacing.sm, Math.round(feltSurface.width * 0.013))

          // ---------------------------------------------------- empty slots
          // Outlines for every pile position, painted under the cards. The
          // stock outline doubles as the recycle target once it runs dry.
          Repeater {
            model: 13
            delegate: Item {
              readonly property int slot: index          // 0 stock, 1 waste, 2-5 foundations, 6-12 columns
              readonly property var lay: root.layout
              width: root.cardW
              height: root.cardH
              z: 0
              x: slot === 0 ? lay.colX[0]
                 : slot === 1 ? lay.colX[1]
                 : slot < 6 ? lay.colX[3 + (slot - 2)]
                 : lay.colX[slot - 6]
              y: slot < 6 ? lay.topY : lay.tabY

              Rectangle {
                anchors.fill: parent
                radius: Math.max(2, root.cardW * 0.09)
                color: "transparent"
                border.width: 1
                border.color: root.feltLine
                opacity: 0.55
              }

              Text {
                anchors.centerIn: parent
                visible: slot === 0
                text: root.stock.length === 0 && root.waste.length > 0 ? "↻" : ""
                color: root.feltLine
                font.family: root.fontFamily
                font.pixelSize: Math.max(10, root.cardH * 0.34)
              }

              // Foundations show a ghosted suit so an empty table reads as
              // four places to build, not four holes.
              SuitPip {
                anchors.centerIn: parent
                visible: slot >= 2 && slot < 6
                width: Math.max(8, Math.round(root.cardH * 0.30))
                height: width
                // Clamped rather than relying on `visible`: a hidden binding
                // still evaluates, and an out-of-range index would resolve to
                // undefined every time the layout changed.
                suit: (slot >= 2 && slot < 6) ? slot - 2 : 0
                pipColor: root.feltLine
                opacity: 0.5
              }

              MouseArea {
                anchors.fill: parent
                enabled: slot === 0
                onClicked: root.draw()
              }
            }
          }

          // ---------------------------------------------------------- cards
          Repeater {
            model: 52
            delegate: Item {
              id: cardItem

              readonly property int cid: index
              readonly property var info: root.layout.cards[cid]
              readonly property int heldIdx: root.dragIndexOf(root.dragCids, cid)
              readonly property bool held: heldIdx >= 0
              // Only the drag-run's own fan matters while carried; base
              // positions already carry the source pile's spacing.
              readonly property real baseX: held && root.dragBase.length > heldIdx
                                              ? root.dragBase[heldIdx].x : 0
              readonly property real baseY: held && root.dragBase.length > heldIdx
                                              ? root.dragBase[heldIdx].y : 0

              visible: info.pile !== "none"
              width: root.cardW
              height: root.cardH
              x: held ? baseX + root.dragDX : info.x
              y: held ? baseY + root.dragDY : info.y
              z: held ? 900 + heldIdx : info.z

              Behavior on x {
                enabled: !cardItem.held
                NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
              }
              Behavior on y {
                enabled: !cardItem.held
                NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
              }

              // ------------------------------------------------- card body
              Rectangle {
                id: body
                anchors.fill: parent
                radius: Math.max(2, root.cardW * 0.09)
                // The artwork carries its own frame and rounded corners, so
                // this is a positioning shell only — a fill or a border here
                // would show as a second card behind the first.
                color: "transparent"
                border.width: 0

                // Lift the carried run so it reads as being off the table.
                scale: cardItem.held ? 1.04 : 1.0
                Behavior on scale { NumberAnimation { duration: 90 } }

                // Turning over: squeeze to edge-on and back out again. Only
                // one card is ever mid-flip, so a single root-level driver
                // is enough.
                transform: Scale {
                  origin.x: body.width / 2
                  origin.y: body.height / 2
                  xScale: cardItem.cid === root.flipCard ? root.flipScale : 1
                }

                // --------------------------------------------- the card art
                // Face and back are both bundled images that carry their own
                // frame, rounded corners and index, so nothing is drawn over
                // them. sourceSize keeps a 400px file from being decoded at
                // full size 52 times — it is resolved at twice the on-screen
                // card width, which is enough for a HiDPI panel.
                Image {
                  anchors.fill: parent
                  source: cardItem.info.up ? root.cardImage(cardItem.cid) : root.backImage
                  fillMode: Image.PreserveAspectFit
                  sourceSize.width: Math.max(64, Math.round(root.cardW * 2))
                  smooth: true
                  mipmap: true
                  asynchronous: true
                  cache: true
                }
              }

              // --------------------------------------------------- pointer
              // One MouseArea per card; Qt delivers the press to the topmost
              // one under the cursor, which is exactly the card a player
              // means to grab. Positions are mapped into `table` so the
              // pointer's own coordinates never drift as the card follows it.
              MouseArea {
                id: grab
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                cursorShape: cardItem.info.up || cardItem.info.pile === "s"
                               ? Qt.PointingHandCursor : Qt.ArrowCursor
                property point pressPt: Qt.point(0, 0)
                property bool armed: false

                onPressed: function(mouse) {
                  grab.armed = false
                  if (cardItem.info.pile === "s") return   // stock: click to draw
                  if (root.beginDrag(cardItem.cid)) {
                    grab.armed = true
                    grab.pressPt = grab.mapToItem(table, mouse.x, mouse.y)
                  }
                }

                onPositionChanged: function(mouse) {
                  if (!grab.armed || !root.dragging) return
                  var p = grab.mapToItem(table, mouse.x, mouse.y)
                  root.dragDX = p.x - grab.pressPt.x
                  root.dragDY = p.y - grab.pressPt.y
                  if (!root.dragMoved
                      && Math.abs(root.dragDX) + Math.abs(root.dragDY) > 4)
                    root.dragMoved = true
                }

                onReleased: function(mouse) {
                  if (cardItem.info.pile === "s") { root.draw(); return }
                  if (!grab.armed) return
                  grab.armed = false
                  // A click that went nowhere puts the card back and does
                  // nothing else. Sending it to a foundation on a single
                  // click made every slightly-too-short drag look like the
                  // card had teleported — and like the card underneath had
                  // turned over mid-drag. That is what double-click is for.
                  if (root.dragMoved) root.dropDrag()
                  else { root.cancelDrag(); root.touch() }
                }

                // Double-click sends a card to a foundation if it fits, the
                // same shortcut the original has.
                onDoubleClicked: function(mouse) {
                  if (cardItem.info.pile === "s") return   // the clicks drew
                  var pile = cardItem.info.pile
                  grab.armed = false
                  root.cancelDrag()
                  root.tapCard(cardItem.cid, pile)
                }

                onCanceled: {
                  grab.armed = false
                  root.cancelDrag()
                  root.touch()
                }
              }
            }
          }

          // ------------------------------------------------- win cascade
          Canvas {
            id: cascade
            anchors.fill: parent
            visible: root.won
            z: 800
            renderStrategy: Canvas.Immediate

            // Painted incrementally: each tick asks for one card and the
            // buffer keeps everything drawn before it, which is the trail.
            property var pending: null

            function clear() {
              if (!cascade.available) return
              var ctx = cascade.getContext("2d")
              ctx.clearRect(0, 0, cascade.width, cascade.height)
              cascade.markDirty(Qt.rect(0, 0, cascade.width, cascade.height))
            }

            // The flying card is the real card, so the trail is made of the
            // artwork rather than a stand-in. A Canvas can only draw an image
            // it has already loaded, so the first tick for a card asks for it
            // and paints nothing; by the next tick it is there. Cards fly one
            // at a time, so this is one load per card, cached after that.
            function paintCard(cid, x, y) {
              var url = root.cardImage(cid)
              if (!cascade.isImageLoaded(url)) {
                if (!cascade.isImageLoading(url)) cascade.loadImage(url)
                return
              }
              cascade.pending = { url: url, x: x, y: y }
              cascade.markDirty(Qt.rect(x - 2, y - 2, root.cardW + 4, root.cardH + 4))
            }

            onPaint: {
              var job = cascade.pending
              if (!job) return
              cascade.pending = null
              var ctx = cascade.getContext("2d")
              ctx.drawImage(job.url, job.x, job.y, root.cardW, root.cardH)
            }
          }

          // ---------------------------------------------------- win banner
          Rectangle {
            visible: root.won
            z: 900
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: root.cardH * 0.35
            width: winCol.implicitWidth + Style.spacing.huge * 2
            height: winCol.implicitHeight + Style.spacing.xl * 2
            radius: Math.max(2, root.cornerRadius)
            color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.92)
            border.width: 1
            border.color: root.accent

            Column {
              id: winCol
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "That's the lot."
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.score + " points in " + root.timeText() + " and " + root.moves + " moves"
                  + (root.winBonus > 0 ? "   (+" + root.winBonus + " time bonus)" : "")
                color: root.foreground
                opacity: 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Deal again"
                bordered: true
                fontFamily: root.fontFamily
                onClicked: root.newGame()
              }
            }
          }
        }
      }
    }
  }
}
