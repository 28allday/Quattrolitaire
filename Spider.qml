import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// Spider solitaire, as a sibling kind inside the Quattrolitaire panel. It
// follows the same design notes as the Klondike board in Panel.qml, restated
// for this model because the shapes differ:
//
// **The model is 104 integers.** Spider plays with two decks, and card
// identity is by *instance*: inst 0-103. The deck is eight 13-card blocks:
//   block = inst / 13, rank = inst % 13 + 1.
// The difficulty maps blocks to suits — 1-suit is eight spade blocks, 2-suit
// is four spade + four heart, 4-suit is two of each. Everything the rules
// care about is derivable from that mapping (artSuit/artRank), because two
// identical cards are interchangeable in Spider: moving either has the same
// effect. The mapping is difficulty-dependent, so a saved game records its
// own suits value next to the cards.
//
//   suit = artSuit(inst)  rank = artRank(inst)  art = rank+letter → cards/*.png
//   up = one flat array of 104 booleans; a pile is an array of instances.
//
// One layout function owns geometry, cards animate themselves from the model
// mutation, drops resolve by overlap area — the same three load-bearing
// properties as the Klondike board. Spider-only wrinkles:
//   - a draggable run must be a same-suit descending sequence, so unlike the
//     Klondike board runs DO need validation at pickup, but never after —
//     placement rules keep runs valid by construction, and moves always carry
//     full runs.
//   - a completed K→A suit run is removed from the column the moment it
//     forms (Microsoft rules). The removal happens inside the same user
//     action as the move or deal that created it, so one undo step reverses
//     the whole thing. Completed sets are not cards any more: they become an
//     entry in `completed` (a suit), so their instances fall out of layout
//     and release their delegates.
//   - no foundations: eight completed sets is the whole goal, and they are
//     shown stacked where Klondike keeps its foundations.
//
// Stats and the in-progress game live in their own file, spider.json, keyed
// per difficulty, so Klondike's state.json stays exactly as it was.

Item {
  id: root

  // The Loader resizes its item at creation, which can be a transient moment
  // in the parent chain — this board once came up −8×−8 and stayed that size,
  // rendering nothing. Anchoring to the Loader directly makes the size a live
  // binding instead of a one-shot copy.
  anchors.fill: parent

  // The panel root, for the shared theme tokens and the opened flag. Bound by
  // the Loader's inline sourceComponent.
  property var host: null

  // Degrade to neutral tokens if evaluated before the host lands; every real
  // render happens once host is set.
  readonly property color fgColor: root.host ? root.host.foreground : "black"
  readonly property color accentColor: root.host ? root.host.accent : "black"
  readonly property color bgColor: root.host ? root.host.background : "white"
  readonly property color feltLineColor: root.host ? root.host.feltLine : "gray"
  readonly property string fontFam: root.host ? root.host.fontFamily : ""
  // "Ready to be played": the panel is open AND Spider is the kind on the
  // felt. Both boards stay instantiated behind each other, so timers key off
  // this rather than host.opened alone — neither game's clock may run while
  // the other kind is showing.
  readonly property bool isOpen: root.host
    ? (root.host.opened === true && root.host.gameKind === "spider")
    : false

  // ------------------------------------------------------------- game model

  property int suits: 2                         // 1 | 2 | 4, per game
  property var stock: []                        // face down, last element = next deal
  // Which of the five top-row slots have had their pile dealt already. Piles
  // never slide: a dealt pile empties its own slot and the others keep
  // theirs, so a pile you click is always the pile you see there.
  property var stockDealt: [false, false, false, false, false]
  property var tabl: [[], [], [], [], [], [], [], [], [], []]   // ten columns
  property var faceUp: []                       // 104 booleans, indexed by inst
  property var completed: []                    // suits of the sets taken off, in order

  property int score: 500
  property int moves: 0
  property int seconds: 0
  property int deals: 0                         // times the stock was dealt out
  property bool started: false
  property bool won: false
  property var history: []                      // JSON snapshots, newest last
  property var stats: ({
    easy:   { played: 0, won: 0, best: 0, bestTime: 0 },
    medium: { played: 0, won: 0, best: 0, bestTime: 0 },
    hard:   { played: 0, won: 0, best: 0, bestTime: 0 }
  })

  // Bumped by touch() after every model mutation; `layout` binds to it.
  property int rev: 0
  function touch() { root.rev++ }

  // The suit/rank the instance plays as, under the current difficulty.
  function artSuit(inst) {
    var block = Math.floor(inst / 13)
    if (root.suits === 1) return 0
    if (root.suits === 2) return block < 4 ? 0 : 1
    return block % 4
  }
  function artRank(inst) { return (inst % 13) + 1 }
  function artCode(inst) {
    return root.rankNames[root.artRank(inst) - 1] + root.suitLetters[root.artSuit(inst)]
  }

  readonly property var suitLetters: ["S", "H", "D", "C"]
  readonly property var rankNames: ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
  readonly property url backImage: Qt.resolvedUrl("cards/back.png")

  // ----------------------------------------------------------------- undo

  function snapshot() {
    return JSON.stringify({
      s: root.stock, t: root.tabl, u: root.faceUp, f: root.completed,
      td: root.stockDealt, sc: root.score, mv: root.moves, ps: root.deals
    })
  }

  function pushHistory() {
    var h = root.history.slice()
    h.push(root.snapshot())
    if (h.length > 400) h.shift()
    root.history = h
  }

  property bool canUndo: root.history.length > 0 && !root.won

  function undo() {
    if (!root.canUndo) return
    root.cancelFlip()
    var h = root.history.slice()
    var st = JSON.parse(h.pop())
    root.history = h
    root.stock = st.s
    root.stockDealt = Array.isArray(st.td) && st.td.length === 5 ? st.td : root.stockDealt
    root.tabl = st.t
    root.faceUp = st.u
    root.completed = st.f
    root.score = st.sc
    root.moves = st.mv
    root.deals = st.ps
    root.dragInsts = []
    root.touch()
    root.save()
  }

  // ------------------------------------------------------------ new game

  function newGame() {
    var deck = []
    var i
    for (i = 0; i < 104; i++) deck.push(i)
    for (i = 103; i > 0; i--) {                 // Fisher-Yates
      var k = Math.floor(Math.random() * (i + 1))
      var swap = deck[i]; deck[i] = deck[k]; deck[k] = swap
    }

    var up = []
    for (i = 0; i < 104; i++) up.push(false)

    // Four columns of six, six of five; only the last card of each is up.
    var tab = [[], [], [], [], [], [], [], [], [], []]
    var p = 0
    for (var c = 0; c < 10; c++) {
      var n = c < 4 ? 6 : 5
      for (var r = 0; r < n; r++) {
        tab[c].push(deck[p])
        if (r === n - 1) up[deck[p]] = true
        p++
      }
    }

    root.tabl = tab
    root.stock = deck.slice(p)                  // fifty cards, five deals of ten
    root.stockDealt = [false, false, false, false, false]
    root.faceUp = up
    root.completed = []
    root.score = 500
    root.moves = 0
    root.seconds = 0
    root.deals = 0
    root.won = false
    root.started = true
    root.history = []
    root.dragInsts = []
    root.pendingSuits = 0
    root.cancelFlip()
    root.stats = root.bumpStats(root.stats, root.suits, "played")
    stopCascade()
    root.touch()
    root.save()
  }

  // Entering Spider mode when no game is on disk deals immediately, the way
  // the panel deals Klondike on open. A saved in-progress game is restored
  // by the spider file's own load instead.
  function ensure() {
    if (!root.stateLoaded || root.started) return
    root.newGame()
  }

  // -------------------------------------------------------- reveal flips
  // Borrowed wholesale from the Klondike board: lifting a run doesn't turn
  // the card under it face-up right away — the flip waits for the leaving
  // card to land (its 130ms animation plus a beat), then turns the exposed
  // card over on its vertical axis, swapping back for face at the moment it
  // is edge-on and neither side shows.
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
    root.touch()
    root.save()
  }

  function scheduleFlip(ci) {
    if (ci < 0 || ci > 9) return
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

  // Leaving Spider mode: drop transient UI so returning shows a clean board
  // (or the win banner the player already read, which close() resets).
  function deactivate() {
    root.flushFlip()                    // an owed reveal settles before hiding
    root.cancelDrag()
    root.pendingSuits = 0
    root.touch()
  }

  // ------------------------------------------------------------ difficulty

  // Switching suits re-deals — the deal shape and the suit mapping both
  // change. Mid-game it asks first; with nothing going on it just switches.
  property int pendingSuits: 0                   // 0 = none, else awaiting confirm

  function requestSuits(n) {
    if (!root.started || root.won || root.pendingSuits === n) {
      root.applySuits(n)
      return
    }
    root.pendingSuits = n
  }

  // Entering with no game going deals right away at the chosen difficulty;
  // the suits-equal guard passes through so a plain click always has an
  // effect on an idle board.
  function applySuits(n) {
    root.pendingSuits = 0
    if (root.suits === n && root.started) return
    root.suits = n
    root.save()
    root.newGame()
  }

  // ---------------------------------------------------------- legal moves

  function canPlaceOnColumn(ci, inst) {
    var col = root.tabl[ci]
    if (col.length === 0) return true            // any card, any rank
    var t = col[col.length - 1]
    if (root.faceUp[t] !== true) return false
    return root.artRank(inst) === root.artRank(t) - 1
  }

  // A run is draggable only if it is itself a same-suit descending sequence
  // (down to the bottom of the column). Mixed runs stay put — that is the
  // point of Spider, and the reason this pickup validates where Klondike's
  // does not.
  function beginDrag(inst) {
    if (root.won) return false
    var info = root.layout.cards[inst]
    if (!info || info.pile === "none" || info.pile.charAt(0) !== "t") return false
    if (root.faceUp[inst] !== true) return false

    var ci = parseInt(info.pile.substring(1))
    var col = root.tabl[ci]
    var suit = root.artSuit(inst)
    var rank = root.artRank(inst)
    for (var i = info.idx; i < col.length; i++) {
      var c = col[i]
      if (root.faceUp[c] !== true) return false
      if (root.artSuit(c) !== suit) return false
      if (root.artRank(c) !== rank - (i - info.idx)) return false
    }

    var run = col.slice(info.idx)
    var base = []
    for (i = 0; i < run.length; i++) {
      var ri = root.layout.cards[run[i]]
      base.push({ x: ri.x, y: ri.y })
    }

    root.dragInsts = run
    root.dragBase = base
    root.dragFrom = info.pile
    root.dragDX = 0
    root.dragDY = 0
    root.dragMoved = false
    return true
  }

  // ------------------------------------------------------------ dealing

  // Standard rule: the stock deals a row only while every column has a card,
  // so an empty column is never skipped. Five deals in a game.
  readonly property bool canDeal: {
    root.rev                                     // depend on the model clock
    if (!root.started || root.won || root.stock.length === 0) return false
    for (var t = 0; t < 10; t++) if (root.tabl[t].length === 0) return false
    return true
  }

  // A deal lifts the clicked stock pile's round of ten out of the stock and
  // feeds it across the tableau, column i taking the round's i-th card. The
  // remaining piles stay on their own slots, so the cards living in stock
  // window w belong to the w-th pile whose slot has not been dealt yet.
  // Without a slot (keyboard, Deal button) the leftmost live pile is dealt,
  // same as clicking it.
  function deal(slot) {
    if (!root.canDeal || root.dragging) return
    root.flushFlip()          // an owed reveal settles before the row lands
    root.pushHistory()

    var from = slot
    if (from === undefined || from === null || from < 0 || from > 4) {
      from = -1                               // no slot: the leftmost live pile
      for (var p2 = 0; p2 < 5; p2++) {
        if (root.stockDealt[p2] !== true) { from = p2; break }
      }
      if (from < 0) return                    // nothing left in the stock
    } else if (root.stockDealt[from] === true) {
      return                                  // an already-dealt slot is not a deal
    }
    // The clicked slot's cards are the window of the live piles ordered
    // before it — the slots under any dead piles are simply skipped.
    var win = 0
    for (var p = 0; p < from; p++) {
      if (root.stockDealt[p] !== true) win++
    }
    var round = root.stock.slice(win * 10, win * 10 + 10)

    var sd = root.stockDealt.slice()
    sd[from] = true
    var st = root.stock.slice(0, win * 10)
                    .concat(root.stock.slice(win * 10 + 10))
    var t = root.cloneT()
    var u = root.faceUp.slice()
    for (var i = 0; i < 10; i++) {
      t[i].push(round[i])
      u[round[i]] = true
    }
    root.stock = st
    root.stockDealt = sd
    root.tabl = t
    root.faceUp = u
    root.deals++
    root.score = Math.max(0, root.score - 1)
    root.moves++
    root.checkCompleted()
    root.checkWin()
    root.touch()
    root.save()
  }

  // ----------------------------------------------------------------- moves

  function cloneT() {
    var o = []
    for (var i = 0; i < 10; i++) o.push(root.tabl[i].slice())
    return o
  }

  function takeFrom(src, count) {
    var i = parseInt(src.substring(1))
    var t = root.cloneT()
    t[i].splice(t[i].length - count, count)
    root.tabl = t
  }

  // The single mutation path for moving a run.
  function doMove(insts, src, dst) {
    root.flushFlip()          // settle anything the previous move still owes
    root.pushHistory()
    root.takeFrom(src, insts.length)

    var ti = parseInt(dst.substring(1))
    var t = root.cloneT()
    for (var i = 0; i < insts.length; i++) t[ti].push(insts[i])
    root.tabl = t

    root.score = Math.max(0, root.score - 1)
    root.moves++
    root.checkCompleted()
    root.checkWin()
    if (src.charAt(0) === "t") root.scheduleFlip(parseInt(src.substring(1)))
    root.touch()
    root.save()
  }

  // --------------------------------------------------- completed suit runs

  // The tail K→A of one suit leaves the table the moment it forms, +100.
  // A deal can complete several columns at once, and one completion can
  // expose another (identical runs stacked), so this loops until a pass
  // removes nothing. A snapshot is always in history at this point — the
  // move or deal that fed the completion pushed it first — so one undo step
  // reverses both the move and everything the completion took off.
  function checkCompleted() {
    var again = true
    while (again) {
      again = false
      for (var t = 0; t < 10; t++) {
        var col = root.tabl[t]
        if (col.length < 13) continue
        var suit = root.artSuit(col[col.length - 1])
        var full = true
        for (var i = 0; i < 13; i++) {
          var c = col[col.length - 13 + i]
          if (root.faceUp[c] !== true || root.artSuit(c) !== suit
              || root.artRank(c) !== 13 - i) { full = false; break }
        }
        if (!full) continue

        root.takeFrom("t" + t, 13)
        root.completed = root.completed.concat([suit])
        root.score += 100
        again = true

        // Whatever the removal exposed turns over right away. No flip
        // animation here — the exposed card was already buried mid-move and
        // Spider flippers read as noise; a straight reveal is calmer.
        var rest = root.tabl[t]
        if (rest.length > 0 && root.faceUp[rest[rest.length - 1]] !== true) {
          var u = root.faceUp.slice()
          u[rest[rest.length - 1]] = true
          root.faceUp = u
        }
      }
    }
  }

  // --------------------------------------------------------------- finishing

  function checkWin() {
    if (root.completed.length !== 8) return
    root.won = true
    root.stats = root.bumpStats(root.stats, root.suits, "won")
    root.stats = root.bestOf(root.stats, root.suits, root.score, root.seconds)
    root.startCascade()
  }

  // Stats are bucketed by difficulty; helpers so the shape is written once.
  // Both rebuild the whole object rather than mutating the original — the
  // active bucket is rewritten from scratch, the others copied verbatim.
  function bumpStats(st, suits, key) {
    var k = root.suitsKey(suits)
    var v = st[k]
    var nv = { played: v.played, won: v.won, best: v.best, bestTime: v.bestTime }
    nv[key]++
    var next = {}
    for (var other in st) next[other] = st[other]
    next[k] = nv
    return next
  }

  function bestOf(st, suits, score, seconds) {
    var k = root.suitsKey(suits)
    var v = st[k]
    var next = {}
    for (var other in st) next[other] = st[other]
    next[k] = {
      played: v.played,
      won: v.won,
      best: Math.max(v.best, score),
      bestTime: (v.bestTime === 0 || seconds < v.bestTime) ? seconds : v.bestTime
    }
    return next
  }

  function suitsKey(suits) {
    return suits === 1 ? "easy" : suits === 2 ? "medium" : "hard"
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.isOpen && root.started && !root.won
    onTriggered: root.seconds++
  }

  function timeText() {
    var m = Math.floor(root.seconds / 60)
    var s = root.seconds % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  // The panel's status row shows the active kind's line. QML captures the
  // property reads made inside a called function, so this stays live.
  readonly property string suitsLabel: root.suits === 1 ? "1 suit"
                                       : root.suits === 2 ? "2 suits"
                                       : "4 suits"

  function statusText() {
    var st = root.stats[root.suitsKey(root.suits)]
    return "Score " + root.score + "   ·   Moves " + root.moves + "   ·   " + root.timeText()
      + (st.won > 0 ? "   ·   Won " + st.won + "/" + st.played : "")
      + "   ·   Sets " + root.completed.length + "/8"
  }

  // ------------------------------------------------------------- dropping

  property var dragInsts: []     // run being carried, bottom card first
  property var dragBase: []      // where each of them started, board coords
  property string dragFrom: ""
  property real dragDX: 0
  property real dragDY: 0
  property bool dragMoved: false
  readonly property bool dragging: root.dragInsts.length > 0

  function dragIndexOf(insts, inst) {
    for (var i = 0; i < insts.length; i++) if (insts[i] === inst) return i
    return -1
  }

  function cancelDrag() {
    root.dragInsts = []
    root.dragBase = []
    root.dragFrom = ""
    root.dragDX = 0
    root.dragDY = 0
    root.dragMoved = false
  }

  function overlap(ax, ay, aw, ah, bx, by, bw, bh) {
    var w = Math.min(ax + aw, bx + bw) - Math.max(ax, bx)
    var h = Math.min(ay + ah, by + bh) - Math.max(ay, by)
    return (w > 0 && h > 0) ? w * h : 0
  }

  // Drop by overlap area, as on the Klondike board — but with only the ten
  // tableau targets, since Spider has no foundations.
  function dropDrag() {
    if (!root.dragging) { root.cancelDrag(); return }

    var lead = root.dragInsts[0]
    var rx = root.dragBase[0].x + root.dragDX
    var ry = root.dragBase[0].y + root.dragDY
    var L = root.layout

    var bestScore = 0
    var bestDst = ""
    for (var i = 0; i < 10; i++) {
      if ("t" + i === root.dragFrom) continue
      if (!root.canPlaceOnColumn(i, lead)) continue
      var area = root.overlap(rx, ry, root.cardW, root.cardH,
                              L.colX[i], L.tabY, root.cardW, L.colH[i])
      if (area > bestScore) { bestScore = area; bestDst = "t" + i }
    }

    var insts = root.dragInsts.slice()
    var from = root.dragFrom

    // Same ordering as the Klondike board: clear the drag first so the run
    // rebinds to where it came from, then land the move so the card animates
    // from the drop point, not from home.
    if (bestDst !== "") {
      root.doMove(insts, from, bestDst)
      root.cancelDrag()
    } else {
      root.cancelDrag()           // illegal drop: one animation, back home
      root.touch()
    }
  }

  // ----------------------------------------------------------------- layout

  // Ten columns across, and room for the top row plus a tableau that can run
  // deep. Whichever axis is tighter wins.
  readonly property int cardW: {
    var byWidth = root.width / 10.74
    var byHeight = (root.height / 4.35) / 1.4
    return Math.max(18, Math.floor(Math.min(byWidth, byHeight)))
  }
  // 5:7, the aspect the bundled deck is drawn at.
  readonly property int cardH: Math.round(root.cardW * 1.4)

  readonly property var layout: root.computeLayout(root.rev, root.cardW, root.cardH)

  function computeLayout(rev, cw, ch) {
    var cards = []
    for (var z = 0; z < 104; z++)
      cards.push({ x: 0, y: 0, z: 0, up: false, pile: "none", idx: -1 })

    var gap = Math.max(2, Math.round(cw * 0.08))
    var gridW = 10 * cw + 9 * gap
    var mx = Math.max(0, Math.round((root.width - gridW) / 2))
    var colX = []
    for (var i = 0; i < 10; i++) colX.push(mx + i * (cw + gap))

    var topY = 0
    var tabY = Math.round(ch * 1.34)

    // Stock, piles of ten spread across the top row. Each pile lives on its
    // own slot for the whole game: the cards in stock window w belong to the
    // w-th slot whose pile has not been dealt yet, and a click on slot k
    // deals exactly that pile (deal() walks the same slot->window mapping).
    var live = []
    for (var s = 0; s < 5; s++) {
      if (root.stockDealt[s] !== true) live.push(s)
    }
    for (var w = 0; w < live.length; w++) {
      for (var j = 0; j < 10; j++) {
        var i2 = w * 10 + j
        if (i2 >= root.stock.length) break
        var sc = root.stock[i2]
        cards[sc] = { x: colX[live[w]], y: topY, z: 10 + i2, up: false,
                      pile: "s" + live[w], idx: i2 }
      }
    }

    // Tableau. The same fan-with-shrink logic as the Klondike board: face-up
    // rows stay readable while a deep pile still fits.
    var availH = Math.max(ch, root.height - tabY)
    var colH = []
    for (var t = 0; t < 10; t++) {
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
        var inst = col[i]
        var isUp = root.faceUp[inst] === true
        cards[inst] = { x: colX[t], y: y, z: 300 + t * 34 + i, up: isUp,
                        pile: "t" + t, idx: i }
        lastY = y
        y += isUp ? uStep : dStep
      }
      colH.push(Math.max(ch, lastY - tabY + ch))
    }

    // Completed sets stack from the second-to-last top-row slot rightwards,
    // nudged sideways so stacked sets of one suit still read as two.
    var compStep = Math.max(3, Math.round(cw * 0.10))
    return { cards: cards, colX: colX, colH: colH, topY: topY, tabY: tabY,
             gap: gap, cw: cw, ch: ch, compX: colX[8], compStep: compStep }
  }

  // ------------------------------------------------------------- win cascade
  //
  // The same never-cleared Canvas as the Klondike board. Cards launch from
  // where the completed sets were stacked, newest set first.

  property bool cascading: false
  property var cascadeQueue: []
  property var faller: null

  function startCascade() {
    var q = []
    var L = root.layout
    for (var c = root.completed.length - 1; c >= 0; c--)
      for (var r = 12; r >= 0; r--) {
        q.push({
          code: root.rankNames[r] + root.suitLetters[root.completed[c]],
          lx: L.compX + c * L.compStep,
          ly: L.topY
        })
      }
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
      var job = q.shift()
      root.cascadeQueue = q
      var dir = Math.random() < 0.5 ? -1 : 1
      root.faller = {
        code: job.code,
        x: job.lx,
        y: job.ly,
        vx: dir * root.cardW * (0.04 + Math.random() * 0.06),
        vy: -root.cardH * 0.02
      }
    }

    var fl = root.faller
    fl.x += fl.vx
    fl.y += fl.vy
    fl.vy += root.cardH * 0.013

    var floor = root.height - root.cardH
    if (fl.y > floor) {
      fl.y = floor
      fl.vy = -fl.vy * 0.78
      if (Math.abs(fl.vy) < root.cardH * 0.02) fl.vy = -root.cardH * 0.02
    }

    cascade.paintCard(fl.code, fl.x, fl.y)

    if (fl.x + root.cardW < -root.cardW || fl.x > root.width + root.cardW)
      root.faller = null
    else
      root.faller = fl
  }

  Timer {
    id: cascadeTimer
    interval: 16
    repeat: true
    running: root.cascading && root.isOpen && root.won
    onTriggered: root.stepCascade()
  }

  // -------------------------------------------------------------- board UI

  // ---------------------------------------------------- empty slots
  // Outlines under the cards. Slots 0-4 are the five deal rounds, 5 is the
  // completed-sets stack, 6-15 are the ten tableau columns.
  Repeater {
    model: 16
    delegate: Item {
      id: slotItem
      required property int index
      readonly property int slot: index
      readonly property var lay: root.layout
      width: root.cardW
      height: root.cardH
      z: 0

      x: slot < 5 ? lay.colX[slot]
         : slot === 5 ? lay.compX
         : lay.colX[slot - 6]
      y: slot < 6 ? lay.topY : lay.tabY

      Rectangle {
        anchors.fill: parent
        radius: Math.max(2, root.cardW * 0.09)
        color: "transparent"
        border.width: 1
        border.color: root.feltLineColor
        opacity: 0.55
      }

      MouseArea {
        anchors.fill: parent
        // Only a pile that has not been dealt yet takes clicks, and it deals
        // itself: clicking slot k's pile deals that pile, wherever live piles
        // happen to sit.
        enabled: slotItem.slot < 5 && root.stockDealt[slotItem.slot] !== true
        cursorShape: slotItem.slot < 5 && root.canDeal ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.deal(slotItem.slot)
      }
    }
  }

  // Completed sets are not cards any more; the slots layer paints one King
  // per taken set, nudged sideways per set so same-suit stacks read apart.
  Repeater {
    model: root.completed.length
    delegate: Image {
      required property int index
      readonly property var lay: root.layout
      source: Qt.resolvedUrl("cards/K" + root.suitLetters[root.completed[index]] + ".png")
      width: root.cardW
      height: root.cardH
      x: lay.compX + index * lay.compStep
      y: lay.topY
      z: 8 + index
      fillMode: Image.PreserveAspectFit
      sourceSize.width: Math.max(64, Math.round(root.cardW * 2))
      smooth: true
      mipmap: true
      asynchronous: true
      cache: true
    }
  }

  // ---------------------------------------------------------- cards
  Repeater {
    model: 104
    delegate: Item {
      id: cardItem

      required property int index
      readonly property int inst: index
      readonly property var info: root.layout.cards[inst]
      readonly property int heldIdx: root.dragIndexOf(root.dragInsts, inst)
      readonly property bool held: heldIdx >= 0
      // Only the drag-run's own fan matters while carried; base positions
      // already carry the source pile's spacing.
      readonly property real baseX: held && root.dragBase.length > heldIdx
                                      ? root.dragBase[heldIdx].x : 0
      readonly property real baseY: held && root.dragBase.length > heldIdx
                                      ? root.dragBase[heldIdx].y : 0

      // Completed sets release their instances: no pile, no delegate.
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

      Rectangle {
        id: body
        anchors.fill: parent
        radius: Math.max(2, root.cardW * 0.09)
        // The artwork carries its own frame and rounded corners, so this is
        // a positioning shell only — the same as the Klondike delegates.
        color: "transparent"
        border.width: 0

        scale: cardItem.held ? 1.04 : 1.0
        Behavior on scale { NumberAnimation { duration: 90 } }

        // Turning over: squeeze to edge-on and back out again. Only one card
        // is ever mid-flip, so a single root-level driver is enough — the
        // same arrangement as the Klondike board.
        transform: Scale {
          origin.x: body.width / 2
          origin.y: body.height / 2
          xScale: cardItem.inst === root.flipCard ? root.flipScale : 1
        }

        Image {
          anchors.fill: parent
          source: cardItem.info.up ? root.cardImage(cardItem.inst) : root.backImage
          fillMode: Image.PreserveAspectFit
          sourceSize.width: Math.max(64, Math.round(root.cardW * 2))
          smooth: true
          mipmap: true
          asynchronous: true
          cache: true
        }
      }

      // One MouseArea per card; the topmost one under the cursor gets the
      // press, which is the card the player means to grab.
      MouseArea {
        id: grab
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: (cardItem.info.up && cardItem.info.pile.charAt(0) === "t")
                       || cardItem.info.pile.charAt(0) === "s"
                     ? Qt.PointingHandCursor : Qt.ArrowCursor
        property point pressPt: Qt.point(0, 0)
        property bool armed: false

        onPressed: function(mouse) {
          grab.armed = false
          if (cardItem.info.pile.charAt(0) === "s") return   // stock: click to deal
          if (root.beginDrag(cardItem.inst)) {
            grab.armed = true
            grab.pressPt = grab.mapToItem(root, mouse.x, mouse.y)
          }
        }

        onPositionChanged: function(mouse) {
          if (!grab.armed || !root.dragging) return
          var p = grab.mapToItem(root, mouse.x, mouse.y)
          root.dragDX = p.x - grab.pressPt.x
          root.dragDY = p.y - grab.pressPt.y
          if (!root.dragMoved
              && Math.abs(root.dragDX) + Math.abs(root.dragDY) > 4)
            root.dragMoved = true
        }

        onReleased: function(mouse) {
          if (cardItem.info.pile.charAt(0) === "s") {
            // The pile the card belongs to is the pile that gets dealt —
            // its slot rides along in the pile code.
            root.deal(parseInt(cardItem.info.pile.substring(1)))
            return
          }
          if (!grab.armed) return
          grab.armed = false
          if (root.dragMoved) root.dropDrag()
          else { root.cancelDrag(); root.touch() }
        }

        // No double-click shortcut: with no foundations there is nowhere to
        // send a single card that a drag would not do better.
        onDoubleClicked: { grab.armed = false; root.cancelDrag(); root.touch() }

        onCanceled: {
          grab.armed = false
          root.cancelDrag()
          root.touch()
        }
      }
    }
  }

  // The card art, from the deck mapping rather than the bare instance: the
  // same shared code as the Klondike board resolves the on-disk PNG.
  function cardImage(inst) {
    return Qt.resolvedUrl("cards/" + root.artCode(inst) + ".png")
  }

  // --------------------------------------------------- win cascade (canvas)
  Canvas {
    id: cascade
    anchors.fill: parent
    visible: root.won
    z: 800
    renderStrategy: Canvas.Immediate

    property var pending: null

    function clear() {
      if (!cascade.available) return
      var ctx = cascade.getContext("2d")
      ctx.clearRect(0, 0, cascade.width, cascade.height)
      cascade.markDirty(Qt.rect(0, 0, cascade.width, cascade.height))
    }

    // First tick for a card asks for the image; by the next tick it is there.
    // One load per card, cached after.
    function paintCard(code, x, y) {
      var url = Qt.resolvedUrl("cards/" + code + ".png")
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
    z: 950
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: root.cardH * 0.35
    width: winCol.implicitWidth + Style.spacing.huge * 2
    height: winCol.implicitHeight + Style.spacing.xl * 2
    radius: Math.max(2, root.host ? root.host.cornerRadius : 4)
    color: Qt.rgba(root.bgColor.r, root.bgColor.g, root.bgColor.b, 0.92)
    border.width: 1
    border.color: root.accentColor

    Column {
      id: winCol
      anchors.centerIn: parent
      spacing: Style.spacing.sm

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "All eight sets down."
        color: root.accentColor
        font.family: root.fontFam
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.score + " points in " + root.timeText() + " and " + root.moves
              + " moves — " + root.suitsLabel + "."
        color: root.fgColor
        opacity: 0.8
        font.family: root.fontFam
        font.pixelSize: Style.font.body
      }
      Button {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Deal again"
        bordered: true
        fontFamily: root.fontFam
        onClicked: root.newGame()
      }
    }
  }

  // ------------------------------------------------ difficulty confirm box
  // Switching suits mid-game abandons the current deal; ask before dealing.
  Rectangle {
    visible: root.pendingSuits > 0 && !root.won
    z: 960
    anchors.centerIn: parent
    width: confirmCol.implicitWidth + Style.spacing.huge * 2
    height: confirmCol.implicitHeight + Style.spacing.xl * 2
    radius: Math.max(2, root.host ? root.host.cornerRadius : 4)
    color: Qt.rgba(root.bgColor.r, root.bgColor.g, root.bgColor.b, 0.92)
    border.width: 1
    border.color: root.accentColor

    Column {
      id: confirmCol
      anchors.centerIn: parent
      spacing: Style.spacing.sm

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Deal at " + (root.pendingSuits === 1 ? "1 suit"
                             : root.pendingSuits === 2 ? "2 suits" : "4 suits") + "?"
        color: root.accentColor
        font.family: root.fontFam
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "The game in progress is abandoned."
        color: root.fgColor
        opacity: 0.8
        font.family: root.fontFam
        font.pixelSize: Style.font.body
      }
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.sm

        Button {
          text: "Deal it"
          bordered: true
          fontFamily: root.fontFam
          onClicked: root.applySuits(root.pendingSuits)
        }
        Button {
          text: "Keep playing"
          bordered: true
          fontFamily: root.fontFam
          onClicked: root.cancelPendingSuits()
        }
      }
    }
  }

  // --------------------------------------------------------------- persistence

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: root.home + "/.local/state/omarchy-quattrolitaire"
  readonly property string statePath: root.stateDir + "/spider.json"
  property bool stateLoaded: false

  function save() {
    if (!root.stateLoaded) return
    saveTimer.restart()
  }

  // Debounced, exactly like the panel's state.json save.
  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: {
      var payload = JSON.stringify({
        version: 1,
        suits: root.suits,
        stats: root.stats,
        game: (root.started && !root.won) ? {
          suits: root.suits,
          s: root.stock, t: root.tabl, u: root.faceUp, f: root.completed,
          td: root.stockDealt, sc: root.score, mv: root.moves, ps: root.deals, sec: root.seconds
        } : null
      }, null, 2) + "\n"
      spiderFile.setText(payload)
    }
  }

  // A saved game restores only when it still holds a consistent deck —
  // every instance on the board or in one of the completed sets, the five
  // stock piles shared out in whole rounds — and its own suits value is a
  // real one. A truncated or hand-edited file deals nothing rather than
  // half a game.
  function restoreGame(g) {
    if (!g || typeof g !== "object") return false
    if (g.suits !== 1 && g.suits !== 2 && g.suits !== 4) return false

    var seen = []
    var i
    for (i = 0; i < 104; i++) seen.push(false)

    function claim(pile) {
      if (!Array.isArray(pile)) return false
      for (var j = 0; j < pile.length; j++) {
        var v = pile[j]
        if (typeof v !== "number" || v < 0 || v > 103 || seen[v]) return false
        seen[v] = true
      }
      return true
    }

    if (!claim(g.s)) return false
    if (!Array.isArray(g.t) || g.t.length !== 10) return false
    for (i = 0; i < 10; i++) if (!claim(g.t[i])) return false

    // Completed sets have left the board — each was one suit's 13-card
    // K→A — so exactly 13 × n instances may be missing from stock ∪
    // tableau. The suits in the list must be ones the difficulty's deck
    // actually contains, no more often than that deck contains them.
    root.suits = g.suits
    var ceiling = g.suits === 1 ? 1 : g.suits === 2 ? 2 : 4
    var perSuit = g.suits === 1 ? 8 : g.suits === 2 ? 4 : 2
    var fin = []
    if (Array.isArray(g.f)) {
      for (i = 0; i < g.f.length; i++) {
        var fv = g.f[i]
        if (typeof fv !== "number" || fv < 0 || fv >= ceiling
            || fv !== Math.floor(fv)) return false
        fin.push(fv)
      }
    }
    if (fin.length > 8) return false
    var perSuitCount = [0, 0, 0, 0]
    for (i = 0; i < fin.length; i++) {
      perSuitCount[fin[i]]++
      if (perSuitCount[fin[i]] > perSuit) return false
    }

    var missing = 0
    for (i = 0; i < 104; i++) if (!seen[i]) missing++
    if (missing !== fin.length * 13) return false

    if (!Array.isArray(g.u) || g.u.length !== 104) return false

    var up = []
    for (i = 0; i < 104; i++) up.push(g.u[i] === true)

    // The stock holds exactly the rounds of the piles not yet dealt: a td
    // marking more stayers than the stock has cards for would make deal()
    // slice past the stock's end.
    var td = Array.isArray(g.td) && g.td.length === 5
      ? [g.td[0] === true, g.td[1] === true, g.td[2] === true, g.td[3] === true, g.td[4] === true]
      : [false, false, false, false, false]
    var livePiles = 0
    for (i = 0; i < 5; i++) if (td[i] !== true) livePiles++
    if (g.s.length !== livePiles * 10) return false

    root.stock = g.s
    root.stockDealt = td
    root.tabl = g.t
    root.faceUp = up
    root.completed = fin
    root.score = Math.max(0, Number(g.sc) || 0)
    root.moves = Math.max(0, Number(g.mv) || 0)
    root.deals = Math.max(0, Number(g.ps) || 0)
    root.seconds = Math.max(0, Number(g.sec) || 0)
    root.won = false
    root.started = true
    root.history = []
    root.cancelDrag()
    root.cancelFlip()
    root.touch()
    return true
  }

  function applyState(raw) {
    var st = null
    try { st = JSON.parse(String(raw || "").trim()) } catch (e) {}

    if (st && typeof st === "object") {
      if (st.suits === 1 || st.suits === 2 || st.suits === 4) root.suits = st.suits
      if (st.stats && typeof st.stats === "object") {
        var known = ["easy", "medium", "hard"]
        var loaded = {}
        for (var k = 0; k < known.length; k++) {
          var sname = known[k]
          var src = st.stats[sname]
          loaded[sname] = {
            played: Math.max(0, Number(src ? src.played : 0) || 0),
            won: Math.max(0, Number(src ? src.won : 0) || 0),
            best: Math.max(0, Number(src ? src.best : 0) || 0),
            bestTime: Math.max(0, Number(src ? src.bestTime : 0) || 0)
          }
        }
        root.stats = loaded
      }
      if (root.restoreGame(st.game)) { root.stateLoaded = true; return }
    }

    root.stateLoaded = true
    // The state file often finishes loading after the first ensure() call
    // (the board's loader warms up while the file is still in flight), and
    // that call no-ops on an unloaded board. If Spider is what the player is
    // looking at right now, deal now that the load has settled.
    if (root.host && root.host.gameKind === "spider" && root.host.opened)
      root.ensure()
  }

  FileView {
    id: spiderFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyState(text())
    onLoadFailed: function(err) { root.applyState("") }
  }

  // Make sure the state dir exists, then (re)load the spider file. The panel
  // runs the same dance for state.json; both mkdirs are idempotent.
  Process {
    id: mkStateDir
    command: ["mkdir", "-p", root.stateDir]
    onExited: spiderFile.reload()
  }
  Component.onCompleted: mkStateDir.running = true
}
