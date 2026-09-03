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

  // The Hyprland half. `omarchy plugin add` clones this QML and nothing else,
  // so until the user says yes to the card below there is no `lua:parquet` for
  // a workspace rule to name. Service only READS ~/.config/hypr to know this;
  // the button is the one thing in Parquet that runs the installer.
  readonly property bool needsSetup: service ? service.needsSetup : false
  readonly property bool needsUpdate: service ? service.needsUpdate : false
  readonly property bool setupRunning: service ? service.setupRunning : false
  readonly property string setupError: service ? service.setupError : ""

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

        // ---- setup card --------------------------------------------------
        //
        // Shown only when the Hyprland half is missing or stale. It names every
        // file the installer will write before offering the button, because
        // those files are the user's compositor config and agreeing to that is
        // the whole point of putting this in front of them.
        BorderSurface {
          Layout.fillWidth: true
          visible: root.needsSetup || root.needsUpdate
          implicitHeight: setupBody.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Style.controlFill(false, false, root.fg, Color.accent)
          borderSpec: Border.controlSpec("focus", root.fg, Color.accent)

          ColumnLayout {
            id: setupBody
            x: Style.space(10)
            y: Style.space(10)
            width: parent.width - Style.space(20)
            spacing: Style.space(6)

            Text {
              Layout.fillWidth: true
              text: root.needsSetup
                    ? "Finish setting up Parquet"
                    : "Parquet's Hyprland layout is out of date"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.needsSetup
                ? "Parquet tiles through a Hyprland Lua layout. Adding the plugin "
                  + "installed this widget and nothing else, so there is nothing to "
                  + "tile with yet.\n\nInstalling it will:\n"
                  + "  •  write ~/.config/hypr/parquet.lua\n"
                  + "  •  add one marked block to ~/.config/hypr/hyprland.lua, "
                  + "after backing it up\n"
                  + "  •  reload Hyprland\n\n"
                  + "Nothing else on your system is touched, and the README's "
                  + "Uninstalling section reverses all of it."
                : "The copy in ~/.config/hypr is older than the one this plugin "
                  + "ships. Updating rewrites the same two files, backing them up "
                  + "first, and reloads Hyprland."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              lineHeight: 1.25
            }

            // install.sh refuses rather than guesses — a symlinked config, an
            // unbalanced managed block, a hyprland.conf machine — and says why.
            // Show its own words: they name the file and the fix.
            Text {
              Layout.fillWidth: true
              visible: root.setupError.length > 0
              textFormat: Text.PlainText
              text: root.setupError
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Button {
                text: root.setupRunning
                      ? "Working…"
                      : (root.needsSetup ? "Install the Hyprland layout"
                                         : "Update the Hyprland layout")
                bordered: true
                selected: !root.setupRunning
                enabled: !root.setupRunning && root.service !== null
                onClicked: root.service.runSetup()
              }
              Item { Layout.fillWidth: true }
              Text {
                visible: root.needsUpdate && !root.setupRunning
                text: "Parquet still works until you do."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Flickable {
          enabled: !root.needsSetup
          opacity: root.needsSetup ? 0.4 : 1
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
          enabled: !root.needsSetup
          opacity: root.needsSetup ? 0.4 : 1

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
