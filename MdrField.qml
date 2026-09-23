import QtQuick
import QtQuick.Shapes
import "MdrNoise.js" as Noise

// A Macrodata Refinement field, as seen on the Lumon terminals in Severance.
//
// Self-contained and geometry-agnostic: it renders into whatever size it is
// given and takes its palette from properties, so it works equally as a
// background layer or inside an ordinary window.
//
// The mechanic: digits 0-9 fill the screen. Some of them are "scary" -- they
// swell and twitch. Scariness is not random; it is a noise field thresholded
// per cell, so scary digits form coherent clusters that drift slowly. You lasso
// a cluster, and if most of what you caught was scary, it flies into one of the
// five bins at the bottom.

Item {
  id: field

  // ---- palette -------------------------------------------------------------
  // Defaults are the terminal's own colors. Background.qml overrides them with
  // the active Omarchy theme so this never fights the rest of the desktop.
  property color colorBg: "#010A13"
  property color colorFg: "#ABFFE9"
  property color colorSelect: "#EEFFFF"
  property color colorWO: "#05C3A8"
  property color colorFC: "#1EEFFF"
  property color colorDR: "#DF81D5"
  property color colorMA: "#F9ECBB"

  property string fontFamily: "monospace"
  // The mark is set in a grotesque, not the terminal monospace.
  property string wordmarkFamily: "sans-serif"
  // The terminal sets its digits in a sans, not a monospace.
  property string digitFamily: "sans-serif"

  // ---- behaviour -----------------------------------------------------------
  // running=false stops the frame driver entirely. The last frame stays on
  // screen. This is how occlusion suspension works -- see Background.qml.
  property bool running: true
  property bool interactive: true
  property bool scanlines: true

  // Fraction of the noise range that counts as scary. Higher = sparser
  // clusters. 0.66 puts roughly a third of the field in play, which matches
  // the density the show tends to display.
  property real scaryThreshold: 0.66
  property real noiseStep: 0.2        // noise distance between adjacent cells
  property real driftSpeed: 0.004     // how fast clusters migrate, per tick
  property int tickMs: 33             // ~30fps; the field does not need 60

  // ---- signals -------------------------------------------------------------
  signal doubleClicked(int button)    // forwarded so the host keeps its gesture
  signal fileCompleted()

  // ---- derived geometry ----------------------------------------------------
  readonly property real buffer: Math.max(48, Math.min(width, height) * 0.0926)
  readonly property real cell: Math.max(24, (Math.min(width, height) - buffer * 2) / 10)
  readonly property real baseSize: cell * 0.30   // chrome text
  // The field's digits are far larger than the chrome, roughly half the
  // cell pitch, as on the terminal.
  readonly property real digitSize: cell * 0.46
  readonly property int cols: Math.max(1, Math.floor(width / cell))
  readonly property int rows: Math.max(1, Math.floor((height - buffer * 2) / cell))
  readonly property int cellCount: cols * rows
  readonly property real gridOriginX: (width - cols * cell) * 0.5
  readonly property real gridOriginY: buffer

  // ---- file state ----------------------------------------------------------
  readonly property var fileNames: [
    "Siena", "Nanning", "Narva", "Ocula", "Kingsport", "Labrador",
    "Le Mars", "Longbranch", "Moonbeam", "Minsk", "Dranesville"
  ]
  property string fileName: "Siena"
  property string coordinates: "0x000000 : 0x000000"
  property int goal: 500
  readonly property int binGoal: Math.round(goal / 5)

  property real progress: 0           // 0..1 across all bins
  property string statusMessage: ""
  property real statusOpacity: 0

  // ---- internals -----------------------------------------------------------
  property var cells: []              // per-digit state, parallel to the Repeater
  property var bins: []               // five bin records
  property real zoff: 0
  property int seed: 1
  property var itemCache: []
  property int frame: 0

  property bool selecting: false
  property real selX0: 0
  property real selY0: 0
  property real selX1: 0
  property real selY1: 0

  property real cursorX: -1
  property real cursorY: -1
  readonly property real cursorReach: Math.min(width, height) * 0.18

  clip: true

  // --------------------------------------------------------------------------
  // Construction
  // --------------------------------------------------------------------------
  function randHexByte() {
    return Math.floor(Math.random() * 256).toString(16).toUpperCase().padStart(2, "0")
  }

  function newCoordinates() {
    var a = randHexByte() + randHexByte() + randHexByte()
    var b = randHexByte() + randHexByte() + randHexByte()
    return "0x" + a + " : 0x" + b
  }

  function buildField() {
    if (width <= 0 || height <= 0) return

    seed = Math.floor(Math.random() * 100000)
    fileName = fileNames[Math.floor(Math.random() * fileNames.length)]
    coordinates = newCoordinates()

    var list = []
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        list.push({
          digit: Math.floor(Math.random() * 10),
          col: c,
          row: r,
          hx: gridOriginX + c * cell,     // cell top-left; Text centres itself
          hy: gridOriginY + r * cell,
          ox: 0, oy: 0,                   // jitter offset from home
          mul: 1,                         // size multiplier
          heat: 0,                        // 0 calm .. 1 centre of a cluster
          shownDigit: -1,                 // last values actually written to the item
          shownBright: false,
          wx: -1, wy: -1, ws: -1, wo: -1,
          scary: false,
          selected: false,
          binning: false,
          binIndex: -1,
          bx: 0, by: 0,
          alpha: 1,
          delay: 0
        })
      }
    }
    cells = list
    itemCache = []

    if (bins.length !== 5) {
      resetBins()
    } else {
      // A rebuild throws away any digit still in flight, so their reservations
      // have to go with them or the lids stay open forever.
      for (var b = 0; b < bins.length; b++) bins[b].incoming = 0
      bumpBins()
    }

    // Lay the digits out immediately. Positions and sizes are otherwise only
    // assigned inside step(), which does not run while the field is suspended
    // under a window -- and a field built in that state would render every
    // digit stacked at the origin until something uncovered it.
    //
    // Several steps rather than one: sizes ease toward their target by 18% per
    // tick, so a single pass leaves every digit at nearly base size and the
    // clusters invisible. This settles them without waiting for the driver.
    Qt.callLater(function() {
      for (var i = 0; i < 16; i++) field.step()
    })
  }

  function resetBins() {
    var b = []
    for (var i = 0; i < 5; i++) {
      b.push({ WO: 0, FC: 0, DR: 0, MA: 0, open: false, lastRefined: 0, lidAngle: 180, incoming: 0 })
    }
    bins = b
    progress = 0
  }

  function binTotal(b) {
    return b.WO + b.FC + b.DR + b.MA
  }

  function recomputeProgress() {
    var sum = 0
    for (var i = 0; i < bins.length; i++) sum += binTotal(bins[i])
    var p = Math.min(1, sum / goal)
    if (p !== progress) progress = p
    if (p >= 1) field.fileCompleted()
  }

  function cacheItems() {
    var arr = []
    for (var i = 0; i < rep.count; i++) arr.push(rep.itemAt(i))
    itemCache = arr
  }

  // --------------------------------------------------------------------------
  // Per-frame step
  // --------------------------------------------------------------------------
  function step() {
    if (!cells.length) return
    if (itemCache.length !== rep.count) cacheItems()
    if (itemCache.length !== cells.length) return

    zoff += driftSpeed
    frame++
    var now = Date.now()
    var halfCell = cell * 0.5
    var reach = cursorReach
    var haveCursor = cursorX >= 0 && cursorY >= 0

    for (var i = 0; i < cells.length; i++) {
      var s = cells[i]
      var it = itemCache[i]
      if (!it) continue

      if (s.binning) {
        stepBinning(s, i)
        it.x = s.hx + s.ox
        it.y = s.hy + s.oy
        it.label.scale = s.mul
        it.label.opacity = s.alpha
        s.ws = s.mul
        s.wo = s.alpha
        s.wx = it.x
        s.wy = it.y
        if (s.shownDigit !== s.digit) {
          it.label.text = s.digit
          s.shownDigit = s.digit
        }
        if (!s.shownBright) {
          it.label.color = colorSelect
          it.label.styleColor = colorSelect
          s.shownBright = true
        }
        continue
      }

      // Scariness: one noise lookup per cell. The z term is shared, so the
      // whole field breathes together rather than each digit doing its own
      // thing -- that coherence is what makes clusters legible.
      // Scariness is re-sampled for a third of the field each frame rather
      // than all of it. The cluster field drifts slowly, so a cell's value is
      // indistinguishable across three frames, and the noise is by far the
      // most expensive thing here -- two octaves of trilinear value noise is
      // sixteen hashes per lookup.
      if ((i + frame) % 3 === 0) {
        var v = Noise.fbm3(s.col * noiseStep, s.row * noiseStep, zoff, seed)
        s.scary = v > scaryThreshold
        s.heat = s.scary ? (v - scaryThreshold) / (1 - scaryThreshold) : 0
      }
      var scary = s.scary
      var n = s.heat

      var targetMul = 1
      if (scary) {
        targetMul = 1 + n * 1.1
        // Bounded random walk. The decay keeps it from drifting off its home
        // cell the way a pure walk would.
        s.ox = (s.ox + (Math.random() * 2 - 1) * 0.9) * 0.9
        s.oy = (s.oy + (Math.random() * 2 - 1) * 0.9) * 0.9
      } else {
        s.ox *= 0.8
        s.oy *= 0.8
      }

      // Cursor proximity: swell and unsettle nearby digits.
      if (haveCursor) {
        var dx = (s.hx + halfCell) - cursorX
        var dy = (s.hy + halfCell) - cursorY
        var d = Math.sqrt(dx * dx + dy * dy)
        if (d < reach) {
          var prox = 1 - d / reach
          targetMul += prox * prox * 0.55
          s.ox += (Math.random() * 2 - 1) * prox * 0.8
          s.oy += (Math.random() * 2 - 1) * prox * 0.8
        }
      }

      s.mul += (targetMul - s.mul) * 0.18
      if (s.ox > 4) s.ox = 4; else if (s.ox < -4) s.ox = -4
      if (s.oy > 4) s.oy = 4; else if (s.oy < -4) s.oy = -4

      s.selected = selecting && scary && insideSelection(s.hx + halfCell, s.hy + halfCell)

      // Most of the field is calm and motionless at any moment. Writing its
      // geometry every frame costs four property writes per digit for no
      // visible change, so settled cells are skipped entirely.
      //
      // scale rather than font.pixelSize: writing a font property rebuilds and
      // re-resolves the QFont every frame, where scale is just a node
      // transform. Distance-field text stays crisp under it.
      var nx = s.hx + s.ox
      var ny = s.hy + s.oy
      var nop = s.selected ? 1 : 0.82 + s.heat * 0.18
      if (Math.abs(nx - s.wx) > 0.05 || Math.abs(ny - s.wy) > 0.05
          || Math.abs(s.mul - s.ws) > 0.002 || Math.abs(nop - s.wo) > 0.004) {
        it.x = nx
        it.y = ny
        it.label.scale = s.mul
        it.label.opacity = nop
        s.wx = nx
        s.wy = ny
        s.ws = s.mul
        s.wo = nop
      }
      // Text and colour change rarely; writing them every frame costs a string
      // conversion and a colour parse for nothing.
      if (s.shownDigit !== s.digit) {
        it.label.text = s.digit
        s.shownDigit = s.digit
      }
      var bright = s.selected || s.heat > 0.45
      if (s.shownBright !== bright) {
        var ink = bright ? colorSelect : colorFg
        it.label.color = ink
        it.label.styleColor = ink
        s.shownBright = bright
      }
    }

    stepBinLids(now)
  }

  function insideSelection(x, y) {
    return x > Math.min(selX0, selX1) && x < Math.max(selX0, selX1)
        && y > Math.min(selY0, selY1) && y < Math.max(selY0, selY1)
  }

  function stepBinning(s, i) {
    if (s.delay > 0) {
      // Brief hold at full size before the digit leaves, so the eye can follow
      // which digits were actually taken.
      s.delay--
      s.mul += (2.4 - s.mul) * 0.25
      return
    }
    var dx = s.bx - (s.hx + s.ox)
    var dy = s.by - (s.hy + s.oy)
    var dist = Math.sqrt(dx * dx + dy * dy)
    if (dist < 6) {
      depositInBin(s.binIndex)
      s.binning = false
      s.binIndex = -1
      s.ox = 0
      s.oy = 0
      s.mul = 1
      s.alpha = 1
      s.digit = Math.floor(Math.random() * 10)
      return
    }
    var ease = 0.12
    s.ox += dx * ease
    s.oy += dy * ease
    s.mul += (0.55 - s.mul) * 0.1
    // Fade over the last couple of cells so the digit disappears into the
    // mouth rather than sliding behind the bin chrome.
    s.alpha = Math.max(0, Math.min(1, dist / (cell * 2.0)))
  }

  function depositInBin(index) {
    if (index < 0 || index >= bins.length) return
    var b = bins[index]
    var levelGoal = binGoal / 4
    var options = []
    var keys = ["WO", "FC", "DR", "MA"]
    for (var k = 0; k < keys.length; k++) {
      if (b[keys[k]] < levelGoal) options.push(keys[k])
    }
    if (!options.length) return
    var key = options[Math.floor(Math.random() * options.length)]
    b[key]++
    b.open = true
    b.incoming = Math.max(0, b.incoming - 1)
    b.lastRefined = Date.now()
    bumpBins()
    recomputeProgress()
  }

  function bumpBins() {
    // QML does not observe mutation of objects inside a var array, so nudge the
    // bin repeater explicitly rather than reassigning the whole array.
    binRepeater.bump++
  }

  // Doors hinge at the bin's outer edges and swing up and outward: 180 lies
  // flat across the mouth, 45 is fully open. They snap open and close lazily,
  // which is how they read on screen.
  function stepBinLids(now) {
    var changed = false
    for (var i = 0; i < bins.length; i++) {
      var b = bins[i]
      // Driven by digits still in flight, not a fixed timer. A timer cannot
      // work here: the flight takes ~1420ms (an 8-frame hold plus ~35 frames
      // of easing), so any timeout shorter than that shuts the lid before the
      // digits land and they visibly reopen it on arrival.
      var wantOpen = b.incoming > 0 || (now - b.lastRefined) < 600
      if (b.open !== wantOpen) {
        b.open = wantOpen
        changed = true
      }
      var target = wantOpen ? 45 : 180
      if (Math.abs(b.lidAngle - target) > 0.4) {
        b.lidAngle += (target - b.lidAngle) * (wantOpen ? 0.32 : 0.10)
        changed = true
      }
    }
    if (changed) bumpBins()
  }

  // --------------------------------------------------------------------------
  // Selection
  // --------------------------------------------------------------------------
  function commitSelection() {
    var total = 0
    var scaryHits = []
    var halfCell = cell * 0.5

    for (var i = 0; i < cells.length; i++) {
      var s = cells[i]
      if (s.binning) continue
      if (!insideSelection(s.hx + halfCell, s.hy + halfCell)) continue
      total++
      if (s.scary) scaryHits.push(s)
    }

    // The show's refiners are judged on catching clusters, not stray digits.
    // Requiring a majority of the lasso to be scary reproduces that: sloppy
    // boxes are rejected even if they contain a few good digits.
    if (total > 0 && scaryHits.length > total * 0.5) {
      var open = []
      for (var b = 0; b < bins.length; b++) {
        if (binTotal(bins[b]) < binGoal) open.push(b)
      }
      if (!open.length) {
        flash("FILE COMPLETE")
        return
      }
      var target = open[Math.floor(Math.random() * open.length)]
      // Open the receiving bin now, so the doors are waiting when they land.
      bins[target].lastRefined = Date.now()
      bins[target].open = true
      bins[target].incoming += scaryHits.length
      bumpBins()
      var bx = binCentreX(target)
      var by = binMouthY()
      for (var h = 0; h < scaryHits.length; h++) {
        var hit = scaryHits[h]
        hit.binning = true
        hit.binIndex = target
        hit.bx = bx
        hit.by = by
        hit.delay = 8
        hit.selected = false
      }
    } else if (total > 0) {
      flash("REFINEMENT REJECTED")
    }
  }

  function binCentreX(i) {
    var w = width / 5
    return i * w + w * 0.5
  }

  // The lid line: digits should vanish where the doors open, not behind the
  // plate below it.
  function binMouthY() {
    return height - buffer * 0.75 - buffer * 0.14
  }

  function flash(msg) {
    statusMessage = msg
    statusOpacity = 1
    statusFade.restart()
  }

  // --------------------------------------------------------------------------
  // Lifecycle
  // --------------------------------------------------------------------------
  onWidthChanged: rebuild.restart()
  onHeightChanged: rebuild.restart()
  Component.onCompleted: buildField()

  Timer {
    id: rebuild
    interval: 120
    onTriggered: field.buildField()
  }

  Timer {
    id: driver
    interval: field.tickMs
    repeat: true
    running: field.running && field.visible && field.cellCount > 0
    onTriggered: field.step()
  }

  NumberAnimation {
    id: statusFade
    target: field
    property: "statusOpacity"
    from: 1
    to: 0
    duration: 1100
    easing.type: Easing.InQuad
  }

  // --------------------------------------------------------------------------
  // Visuals
  // --------------------------------------------------------------------------
  Rectangle {
    anchors.fill: parent
    color: field.colorBg
  }

  // Field boundary rules. The terminal draws these as close-set pairs.
  Repeater {
    model: [
      { y: field.buffer,                 o: 0.85 },
      { y: field.buffer + 3,             o: 0.35 },
      { y: field.height - field.buffer,     o: 0.85 },
      { y: field.height - field.buffer + 3, o: 0.35 }
    ]
    delegate: Rectangle {
      required property var modelData
      x: 0
      width: field.width
      y: modelData.y
      height: 1
      color: field.colorFg
      opacity: modelData.o
    }
  }

  // ---- the digits ----
  Repeater {
    id: rep
    model: field.cellCount

    delegate: Item {
      required property int index
      property alias label: digitText
      width: field.cell
      height: field.cell

      Text {
        id: digitText
        anchors.centerIn: parent
        font.family: field.digitFamily
        font.pixelSize: field.digitSize
        color: field.colorFg
        // Filled and outlined in the same colour, which thickens the glyph to
        // the weight the terminal shows -- between regular and bold.
        style: Text.Outline
        styleColor: field.colorFg
        text: "0"
        renderType: Text.QtRendering
      }
    }

    onCountChanged: field.cacheItems()
  }

  // ---- selection rectangle ----
  Rectangle {
    visible: field.selecting
    color: "transparent"
    border.color: field.colorSelect
    border.width: 1
    x: Math.min(field.selX0, field.selX1)
    y: Math.min(field.selY0, field.selY1)
    width: Math.abs(field.selX1 - field.selX0)
    height: Math.abs(field.selY1 - field.selY0)
  }

  // ---- header ----
  // One outlined box holding a tick track that lights from the left, with the
  // file name in a knocked-out panel over it and the completion figure at the
  // right. The Lumon mark sits outside the box, at the screen edge.
  Item {
    id: header
    x: 0
    y: field.buffer * 0.12
    width: field.width
    height: field.buffer * 0.76

    readonly property real boxX: field.width * 0.05
    readonly property real boxW: field.width * 0.9
    readonly property real logoH: height * 1.3
    readonly property real logoW: logoH * 2.05
    readonly property real logoX: field.width - logoW - 12
    readonly property real trackX1: logoX - 24
    readonly property real inset: 3

    Rectangle {
      x: header.boxX
      y: 0
      width: header.boxW
      height: header.height
      color: "transparent"
      border.color: field.colorFg
      border.width: 2
    }

    // Only lit ticks are drawn; the terminal shows bare track at 0%.
    Item {
      id: meter
      x: header.boxX + header.inset
      y: header.inset
      width: header.trackX1 - x
      height: header.height - header.inset * 2
      clip: true

      readonly property real tickW: Math.max(2, header.height * 0.085)
      readonly property real pitch: tickW * 2.25
      readonly property int count: Math.max(1, Math.floor(width / pitch))
      readonly property int lit: Math.round(count * field.progress)

      Repeater {
        model: meter.lit
        delegate: Rectangle {
          required property int index
          x: index * meter.pitch
          width: meter.tickW
          height: meter.height
          color: field.colorFg
        }
      }
    }

    // File name, knocked out of the track so it stays readable once lit.
    Rectangle {
      id: namePanel
      x: header.boxX + header.inset + 2
      y: header.inset + 2
      width: nameText.implicitWidth + header.height * 0.62
      height: header.height - (header.inset + 2) * 2
      color: field.colorBg
      border.color: field.colorFg
      border.width: 1.5

      Text {
        id: nameText
        anchors.centerIn: parent
        font.family: field.wordmarkFamily
        font.pixelSize: header.height * 0.42
        font.bold: true
        color: field.colorFg
        text: field.fileName
      }
    }

    Text {
      id: pctLabel
      x: header.trackX1 - width - 10
      anchors.verticalCenter: parent.verticalCenter
      font.family: field.wordmarkFamily
      font.pixelSize: header.height * 0.42
      font.bold: true
      color: field.colorFg
      style: Text.Outline
      styleColor: field.colorBg
      text: Math.floor(field.progress * 100) + "% Complete"
    }

    // The Lumon mark: the oval IS the globe -- meridians and latitudes, with
    // the wordmark across its middle.
    Item {
      id: logo
      x: header.logoX
      y: (header.height - header.logoH) / 2
      width: header.logoW
      height: header.logoH

      Canvas {
        id: globe
        anchors.fill: parent
        antialiasing: true

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()

          var lw = Math.max(1, height * 0.045)
          var cx = width / 2
          var cy = height / 2
          var a = cx - lw
          var b = cy - lw

          ctx.lineWidth = lw
          ctx.strokeStyle = field.colorFg
          ctx.fillStyle = field.colorBg

          ctx.beginPath()
          ctx.ellipse(cx - a, cy - b, a * 2, b * 2)
          ctx.fill()
          ctx.stroke()

          var mer = [0.62, 0.24]
          for (var m = 0; m < mer.length; m++) {
            var rx = a * mer[m]
            ctx.beginPath()
            ctx.ellipse(cx - rx, cy - b, rx * 2, b * 2)
            ctx.stroke()
          }

          ctx.beginPath()
          ctx.moveTo(cx, cy - b)
          ctx.lineTo(cx, cy + b)
          ctx.stroke()

          var lat = [-0.46, 0.46]
          for (var i = 0; i < lat.length; i++) {
            var f = lat[i]
            var y = cy + b * f
            var half = a * Math.sqrt(Math.max(0, 1 - f * f))
            ctx.beginPath()
            ctx.moveTo(cx - half, y)
            ctx.lineTo(cx + half, y)
            ctx.stroke()
          }
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
          target: field
          function onColorFgChanged() { globe.requestPaint() }
          function onColorBgChanged() { globe.requestPaint() }
        }
      }

      Rectangle {
        anchors.centerIn: parent
        width: wordmark.implicitWidth + logo.height * 0.18
        height: wordmark.implicitHeight * 0.92
        color: field.colorBg
      }

      Text {
        id: wordmark
        anchors.centerIn: parent
        font.family: field.wordmarkFamily
        font.pixelSize: logo.height * 0.40
        font.bold: true
        font.letterSpacing: logo.height * 0.015
        color: field.colorFg
        text: "LUMON"
      }
    }
  }

  // ---- bins ----
  Repeater {
    id: binRepeater
    property int bump: 0
    model: 5

    delegate: Item {
      required property int index
      readonly property real binW: field.width / 5
      readonly property var record: {
        binRepeater.bump      // dependency: forces re-eval when bins mutate
        return field.bins.length > index ? field.bins[index] : null
      }
      // These must name binRepeater.bump themselves. Reading it only inside
      // `record` is not enough: that binding returns the same object every
      // time, so QML sees no change and nothing downstream recomputes.
      readonly property int filled: {
        binRepeater.bump
        return record ? field.binTotal(record) : 0
      }
      readonly property real pct: field.binGoal > 0 ? Math.min(1, filled / field.binGoal) : 0
      readonly property real lidAngle: {
        binRepeater.bump
        return record ? record.lidAngle : 180
      }
      readonly property real plateW: binW * 0.75

      x: index * binW
      y: 0
      width: binW
      height: field.height

      // Level readout, revealed while the bin is receiving digits.
      Item {
        id: levels
        width: parent.plateW
        x: (parent.binW - width) * 0.5
        y: field.binMouthY() - field.buffer * 1.76
        height: field.buffer * 1.4
        opacity: record && record.open ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 260 } }

        Rectangle {
          anchors.fill: parent
          color: field.colorBg
          border.color: field.colorFg
          border.width: 1
        }

        Column {
          anchors.fill: parent
          anchors.margins: field.buffer * 0.12
          spacing: field.buffer * 0.06

          Repeater {
            model: ["WO", "FC", "DR", "MA"]
            delegate: Row {
              required property string modelData
              required property int index
              spacing: field.buffer * 0.08
              readonly property color levelColor: index === 0 ? field.colorWO
                                                : index === 1 ? field.colorFC
                                                : index === 2 ? field.colorDR
                                                              : field.colorMA
              readonly property real levelGoal: field.binGoal / 4
              readonly property real levelPct: {
                binRepeater.bump
                if (!record) return 0
                return Math.min(1, record[modelData] / levelGoal)
              }

              Text {
                text: modelData
                font.family: field.fontFamily
                font.pixelSize: field.baseSize * 0.5
                color: parent.levelColor
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: levels.width * 0.55
                height: field.baseSize * 0.42
                color: "transparent"
                border.color: parent.levelColor
                border.width: 1
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                  x: 0; y: 0
                  height: parent.height
                  width: parent.width * parent.parent.levelPct
                  color: parent.parent.levelColor
                }
              }
            }
          }
        }
      }

      // Lids: two doors hinged at the bin's outer edges, shut across the mouth
      // and swung up and outward while receiving.
      //
      // Each door is a quadrilateral whose thickness runs straight down the
      // screen rather than square to the door. That skew is what reads as a
      // solid slab seen at an angle -- a rotated rectangle keeps its thickness
      // perpendicular and just looks flat.
      Item {
        id: lids
        // The doors swing outward past the bin's own edges, so this has to be
        // wider than the plate or the shapes get clipped at the hinges.
        readonly property real doorW: parent.plateW * 0.5
        readonly property real hingeY: field.buffer * 1.15
        readonly property real thick: Math.max(4, parent.plateW * 0.05)
        readonly property real hl: doorW                    // left hinge
        readonly property real hr: doorW + parent.plateW    // right hinge

        x: (parent.binW - parent.plateW) * 0.5 - doorW
        y: field.binMouthY() - hingeY
        width: parent.plateW + doorW * 2
        height: hingeY + thick + 2

        readonly property real aL: (180 + lidAngle) * Math.PI / 180
        readonly property real aR: (-lidAngle) * Math.PI / 180
        readonly property real lx: doorW * Math.cos(aL)
        readonly property real ly: doorW * Math.sin(aL)
        readonly property real rx: doorW * Math.cos(aR)
        readonly property real ry: doorW * Math.sin(aR)

        Shape {
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          antialiasing: true

          ShapePath {
            fillColor: field.colorBg
            strokeColor: field.colorFg
            strokeWidth: 1
            startX: lids.hl
            startY: lids.hingeY
            PathLine { x: lids.hl + lids.lx; y: lids.hingeY + lids.ly }
            PathLine { x: lids.hl + lids.lx; y: lids.hingeY + lids.ly + lids.thick }
            PathLine { x: lids.hl;           y: lids.hingeY + lids.thick }
            PathLine { x: lids.hl;           y: lids.hingeY }
          }

          ShapePath {
            fillColor: field.colorBg
            strokeColor: field.colorFg
            strokeWidth: 1
            startX: lids.hr
            startY: lids.hingeY
            PathLine { x: lids.hr + lids.rx; y: lids.hingeY + lids.ry }
            PathLine { x: lids.hr + lids.rx; y: lids.hingeY + lids.ry + lids.thick }
            PathLine { x: lids.hr;           y: lids.hingeY + lids.thick }
            PathLine { x: lids.hr;           y: lids.hingeY }
          }
        }
      }

      // Bin body: index plate and fill bar.
      Item {
        width: parent.plateW
        x: (parent.binW - width) * 0.5
        y: field.binMouthY()

        Rectangle {
          id: plate
          width: parent.width
          height: field.buffer * 0.26
          color: field.colorBg
          border.color: field.colorFg
          border.width: 1

          Text {
            anchors.centerIn: parent
            font.family: field.fontFamily
            font.pixelSize: field.baseSize * 0.62
            color: field.colorFg
            text: String(index + 1).padStart(2, "0")
          }
        }

        Rectangle {
          y: plate.height + field.buffer * 0.06
          width: parent.width
          height: field.buffer * 0.26
          color: field.colorBg
          border.color: field.colorFg
          border.width: 1

          Rectangle {
            x: 1; y: 1
            height: parent.height - 2
            width: Math.max(0, (parent.width - 2) * pct)
            color: field.colorFg
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            font.family: field.fontFamily
            font.pixelSize: field.baseSize * 0.5
            color: field.colorFg
            style: Text.Outline
            styleColor: field.colorBg
            text: Math.floor(pct * 100) + "%"
          }
        }
      }
    }
  }

  // ---- coordinates ----
  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height - field.baseSize * 1.05
    font.family: field.fontFamily
    font.pixelSize: field.baseSize * 0.62
    color: field.colorFg
    text: field.coordinates
  }

  // ---- status flash ----
  Text {
    anchors.centerIn: parent
    font.family: field.fontFamily
    font.pixelSize: field.baseSize * 1.4
    font.letterSpacing: field.baseSize * 0.2
    color: field.colorSelect
    text: field.statusMessage
    opacity: field.statusOpacity
    visible: opacity > 0.01
  }

  // ---- CRT scanlines ----
  // Tiled rather than drawn per-line: one texture, no per-frame cost.
  Image {
    anchors.fill: parent
    source: "scanline.png"
    fillMode: Image.Tile
    visible: field.scanlines && status === Image.Ready
    opacity: 0.5
  }

  // --------------------------------------------------------------------------
  // Input
  // --------------------------------------------------------------------------
  MouseArea {
    anchors.fill: parent
    enabled: field.interactive
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    onPositionChanged: function(mouse) {
      field.cursorX = mouse.x
      field.cursorY = mouse.y
      if (field.selecting) {
        field.selX1 = mouse.x
        field.selY1 = mouse.y
      }
    }

    onExited: {
      field.cursorX = -1
      field.cursorY = -1
    }

    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      field.selX0 = mouse.x
      field.selY0 = mouse.y
      field.selX1 = mouse.x
      field.selY1 = mouse.y
      field.selecting = true
    }

    onReleased: function(mouse) {
      if (!field.selecting) return
      field.selecting = false
      // A press-release that never travelled is a click, not a lasso. Ignoring
      // it is what lets the host's double-click gesture survive.
      var travelled = Math.abs(field.selX1 - field.selX0) + Math.abs(field.selY1 - field.selY0)
      if (travelled < 10) return
      field.commitSelection()
    }

    onDoubleClicked: function(mouse) {
      field.doubleClicked(mouse.button)
      mouse.accepted = true
    }
  }
}
