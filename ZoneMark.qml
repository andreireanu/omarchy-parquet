import QtQuick
import "Parquet.js" as Parquet

// A tiny live thumbnail of a zone tree — the bar chip's icon. Filled zones when
// Parquet is on for the workspace, hollow outlines when off. Uses the same
// Parquet.leafRects carving the editor and the Lua shim use, so it always
// matches what the workspace will actually do.
Item {
  id: mark

  property var tree: ({})
  property color color: "white"
  property bool filled: true
  property real gapPx: 1.5          // space between zones

  implicitWidth: 16
  implicitHeight: 16

  Item {
    id: box
    width: Math.min(mark.width, mark.height)
    height: width
    anchors.centerIn: parent

    Repeater {
      model: Parquet.leafRects(mark.tree, 0, 0, box.width, box.height)

      Rectangle {
        x: modelData.x + mark.gapPx / 2
        y: modelData.y + mark.gapPx / 2
        width: Math.max(1, modelData.w - mark.gapPx)
        height: Math.max(1, modelData.h - mark.gapPx)
        radius: 1.5
        color: mark.filled ? mark.color : "transparent"
        // A little alternation so the filled state reads as woven, not a blob.
        opacity: mark.filled ? ((modelData.index % 2 === 0) ? 1.0 : 0.6) : 1.0
        border.width: mark.filled ? 0 : 1
        border.color: mark.color
      }
    }
  }
}
