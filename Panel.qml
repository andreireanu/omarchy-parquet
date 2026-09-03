import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Parquet.js" as Parquet

// The popout from the bar chip: pick a layout for the focused workspace, or
// jump into the editor. Modelled on Omarchy's own bar-button popups
// (io.github.djrcx.layout-switcher, the built-in clock).
Panel {
  id: root
  moduleName: "io.github.andreireanu.parquet"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  property bool fillOpen: false

  readonly property int wsid: service ? service.activeWorkspaceId : 0
  readonly property string current: service ? service.currentLayout(wsid) : ""
  // The layout "Edit Layout" acts on: the active one, or — when Parquet is off
  // for this workspace — the layout it would use, so you can still tweak it.
  readonly property string editTarget: {
    if (current !== Parquet.OFF) return current
    return (service && wsid > 0) ? service.displayLayout(wsid) : ""
  }
  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    if (service) service.refreshActiveWorkspace()
    root.controller.show()
  }
  function close() { root.controller.hide() }
  function toggle() { opened ? close() : open() }

  function pick(name) {
    if (!service || wsid <= 0) return
    if (name === Parquet.OFF) service.disableWorkspace(wsid)
    else service.applyLayout(wsid, name)
    root.close()
  }

  function editLayout(name) {
    if (hostWidget && name && name !== Parquet.OFF) hostWidget.openEditor({ layout: name })
    root.close()
  }
  function newLayout() {
    if (hostWidget) hostWidget.openEditor({ "new": true })
    root.close()
  }

  KeyboardPanel {
    id: kp
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: kp.fittedContentWidth(Style.space(560), Style.space(760))
    contentHeight: kp.fittedContentHeight(content.implicitHeight, Style.space(360))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Text {
          Layout.fillWidth: true
          text: root.wsid > 0 ? ("Workspace " + root.wsid) : "Parquet"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Flickable {
          Layout.fillWidth: true
          implicitHeight: cardRow.implicitHeight
          contentWidth: cardRow.width
          contentHeight: height
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.HorizontalFlick

          Row {
            id: cardRow
            spacing: Style.space(8)

            LayoutCard {
              label: "Off"
              off: true
              fg: root.fg
              selected: root.current === Parquet.OFF
              onClicked: root.pick(Parquet.OFF)
            }

            Repeater {
              model: root.service ? root.service.library() : []

              LayoutCard {
                required property var modelData
                label: modelData.name
                tree: modelData.tree
                fg: root.fg
                selected: root.current === modelData.name
                onClicked: root.pick(modelData.name)
              }
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.fg }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            text: "Edit Layout"
            bordered: true
            enabled: root.editTarget !== ""
            tooltipText: root.current === Parquet.OFF && root.editTarget !== ""
                         ? ("Edit “" + root.editTarget + "” (Parquet is off here)")
                         : ""
            onClicked: root.editLayout(root.editTarget)
          }
          Button {
            text: "New Layout"
            bordered: true
            onClicked: root.newLayout()
          }
          Item { Layout.fillWidth: true }
          Button {
            text: "Overflow"
            bordered: true
            selected: root.fillOpen
            tooltipText: "What the last zone does with extra windows"
            onClicked: root.fillOpen = !root.fillOpen
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.fillOpen

          Text {
            text: "Extra windows in the last zone:"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Repeater {
            model: Parquet.FILL_MODES

            Button {
              required property var modelData
              text: modelData
              fontSize: Style.font.bodySmall
              bordered: true
              enabled: root.wsid > 0 && root.current !== Parquet.OFF
              selected: root.service && root.service.fillFor(root.wsid) === modelData
              onClicked: root.service.setFill(root.wsid, modelData)
            }
          }
        }
      }
    }
  }
}
