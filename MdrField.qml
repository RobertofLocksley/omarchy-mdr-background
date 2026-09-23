import QtQuick
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
  readonly property real baseSize: cell * 0.30
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

    if (bins.length !== 5) resetBins()

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
      b.push({ WO: 0, FC: 0, DR: 0, MA: 0, open: false, lastRefined: 0, lidAngle: 180 })
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
        it.label.font.pixelSize = Math.max(1, baseSize * s.mul)
        it.label.color = colorSelect
        it.label.opacity = s.alpha
        it.label.text = s.digit
        continue
      }

      // Scariness: one noise lookup per cell. The z term is shared, so the
      // whole field breathes together rather than each digit doing its own
      // thing -- that coherence is what makes clusters legible.
      var v = Noise.fbm3(s.col * noiseStep, s.row * noiseStep, zoff, seed)
      var scary = v > scaryThreshold
      s.scary = scary
      // 0 for a calm digit, 1 at the centre of a cluster. Drives size and
      // brightness together: on the terminal, idle digits sit dim and small
      // and the scary ones burn bright.
      var n = scary ? (v - scaryThreshold) / (1 - scaryThreshold) : 0
      s.heat = n

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

      it.x = s.hx + s.ox
      it.y = s.hy + s.oy
      it.label.font.pixelSize = Math.max(1, baseSize * s.mul)
      it.label.color = (s.selected || s.heat > 0.45) ? colorSelect : colorFg
      it.label.opacity = s.selected ? 1 : 0.48 + s.heat * 0.52
      it.label.text = s.digit
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
      var wantOpen = (now - b.lastRefined) < 1200
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
        font.family: field.fontFamily
        font.pixelSize: field.baseSize
        color: field.colorFg
        text: "0"
        renderType: Text.NativeRendering
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

  // ---- header: file name, segmented meter, completion, wordmark ----
  Item {
    id: header
    x: field.width * 0.05
    y: field.buffer * 0.25
    width: field.width * 0.9
    height: field.buffer * 0.5

    Rectangle {
      anchors.fill: parent
      color: "transparent"
      border.color: field.colorFg
      border.width: 2
      radius: height * 0.16
    }

    Text {
      id: fileLabel
      anchors.left: parent.left
      anchors.leftMargin: field.buffer * 0.16
      anchors.verticalCenter: parent.verticalCenter
      font.family: field.fontFamily
      font.pixelSize: field.baseSize * 0.78
      color: field.colorFg
      text: field.fileName
    }

    // Progress reads as a row of discrete ticks rather than a solid bar.
    Item {
      id: meter
      anchors.left: fileLabel.right
      anchors.leftMargin: field.buffer * 0.18
      anchors.right: pctLabel.left
      anchors.rightMargin: field.buffer * 0.18
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height * 0.52
      clip: true

      readonly property real tickW: Math.max(2, field.baseSize * 0.13)
      readonly property real gap: tickW * 1.4
      readonly property int count: Math.max(1, Math.floor(width / (tickW + gap)))
      readonly property int lit: Math.round(count * field.progress)

      Repeater {
        model: meter.count
        delegate: Rectangle {
          required property int index
          x: index * (meter.tickW + meter.gap)
          width: meter.tickW
          height: meter.height
          color: field.colorFg
          opacity: index < meter.lit ? 1 : 0.18
        }
      }
    }

    Text {
      id: pctLabel
      anchors.right: logo.left
      anchors.rightMargin: field.buffer * 0.16
      anchors.verticalCenter: parent.verticalCenter
      font.family: field.fontFamily
      font.pixelSize: field.baseSize * 0.72
      color: field.colorFg
      text: Math.floor(field.progress * 100) + "% Complete"
    }

    // The Lumon mark: globe in an oval, wordmark beside it.
    Item {
      id: logo
      anchors.right: parent.right
      anchors.rightMargin: field.buffer * 0.08
      anchors.verticalCenter: parent.verticalCenter
      width: field.buffer * 1.2
      height: parent.height * 0.76

      Rectangle {
        anchors.fill: parent
        radius: height * 0.5
        color: "transparent"
        border.color: field.colorFg
        border.width: 1.5
      }

      Item {
        id: globe
        width: parent.height * 0.6
        height: width
        x: parent.height * 0.2
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.fill: parent
          radius: width * 0.5
          color: "transparent"
          border.color: field.colorFg
          border.width: 1
        }
        // A stadium stands in for the meridian ellipse at this size.
        Rectangle {
          anchors.centerIn: parent
          width: parent.width * 0.46
          height: parent.height
          radius: width * 0.5
          color: "transparent"
          border.color: field.colorFg
          border.width: 1
        }
        Rectangle {
          anchors.centerIn: parent
          width: parent.width
          height: 1
          color: field.colorFg
        }
      }

      Text {
        anchors.left: globe.right
        anchors.leftMargin: parent.height * 0.14
        anchors.verticalCenter: parent.verticalCenter
        font.family: field.fontFamily
        font.pixelSize: field.baseSize * 0.58
        font.letterSpacing: field.baseSize * 0.05
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

      // Lids. Two doors hinged at the bin's outer edges: flat across the mouth
      // when shut, swung up and outward when receiving. Drawn before the plate,
      // so the shut position is simply hidden behind it.
      Item {
        id: lids
        x: (parent.binW - parent.plateW) * 0.5
        y: field.binMouthY()
        width: parent.plateW
        height: 1

        Rectangle {
          x: 0
          y: 0
          width: parent.width * 0.5
          height: 2
          color: field.colorFg
          antialiasing: true
          transformOrigin: Item.TopLeft
          rotation: 180 + lidAngle
        }
        Rectangle {
          x: parent.width
          y: 0
          width: parent.width * 0.5
          height: 2
          color: field.colorFg
          antialiasing: true
          transformOrigin: Item.TopLeft
          rotation: -lidAngle
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
