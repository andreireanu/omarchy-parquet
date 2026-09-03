import QtQuick
import qs.Commons
import qs.Ui

// One tile in the panel's layout row: a ZoneMark thumbnail plus a name.
BorderSurface {
  id: card

  property string label: ""
  property var tree: ({})
  property bool selected: false
  property bool off: false           // the "Off / native" tile
  property color fg: "white"

  signal clicked()

  implicitWidth: Style.space(88)
  implicitHeight: Style.space(74)
  radius: Style.cornerRadius
  color: Style.controlFill(card.selected, cardMouse.containsMouse, card.fg, Color.accent)
  borderSpec: Border.controlSpec(
    card.selected ? "focus" : (cardMouse.containsMouse ? "hover-cursor" : "normal"),
    card.fg, Color.accent)

  Column {
    anchors.centerIn: parent
    spacing: Style.space(5)

    ZoneMark {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Style.space(54)
      height: Style.space(34)
      tree: card.off ? ({}) : card.tree
      filled: !card.off
      color: card.fg
      opacity: card.off ? 0.6 : 1
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Style.space(80)
      text: card.label
      color: card.fg
      font.pixelSize: Style.font.caption
      font.bold: card.selected
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }
  }

  MouseArea {
    id: cardMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: card.clicked()
  }
}
