import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components 3.0 as PlasmaComponents3

ColumnLayout {
    id: row

    property string title: ""
    property real percentLeft: 0
    property string resetsAt: ""
    // Window length in minutes (e.g. 300 for a 5h window). Enables the
    // time-remaining marker on the bar when both it and resetsAt are known.
    property real windowMinutes: 0
    // CodexBar pace report for this window ({ willLastToReset, deltaPercent,
    // summary, ... }) or null.
    property var pace: null
    property color accentColor: Kirigami.Theme.highlightColor
    // When true and a pace report is present, the fill uses the pace palette
    // (white = comfortable reserve, yellow = tight, red = runs dry before
    // reset) so the popup matches tray bars tinted by pace.
    property bool usePaceTint: false
    // Wall clock, ticked once a minute so the time marker keeps moving between
    // refreshes.
    property real nowMs: Date.now()
    // Fraction of the window still ahead (1 = just reset, 0 = about to reset),
    // or -1 when unknown. Drawn as a marker at the same scale as percentLeft so
    // the fill reaching past it means the budget outlasts the clock. A reset
    // scheduled at or beyond the full window length reads as more than a whole
    // window and counts as unknown instead of pinning the marker to the right
    // edge.
    readonly property real timeLeftFraction: {
        const minutes = Number(row.windowMinutes);
        if (!row.resetsAt || !Number.isFinite(minutes) || minutes <= 0) {
            return -1;
        }
        const resetMs = new Date(row.resetsAt).getTime();
        if (!Number.isFinite(resetMs)) {
            return -1;
        }
        const left = (resetMs - row.nowMs) / (minutes * 60000);
        if (!(left <= 1)) {
            return -1;
        }
        return Math.max(0, left);
    }
    // Fill color: white when full, muted yellow mid, red when low (red by ~10%).
    readonly property color remainingColor: {
        const value = Number(percentLeft);
        if (!Number.isFinite(value)) {
            return accentColor;
        }
        // Skip the pace palette until 10% of the window has elapsed; right
        // after a reset there is no burn rate to project from.
        const expected = Number(row.pace ? row.pace.expectedUsedPercent : NaN);
        if (row.usePaceTint && row.pace
                && (row.pace.willLastToReset !== null || row.pace.deltaPercent !== null)
                && !(Number.isFinite(expected) && expected < 10)) {
            if (row.pace.willLastToReset === false) {
                return Qt.rgba(1, 0, 0, 1);
            }
            const delta = Number(row.pace.deltaPercent);
            // deltaPercent < 0 means budget in reserve versus the expected burn.
            if (Number.isFinite(delta) && delta > -10) {
                return Qt.rgba(1.0, 0.92, 0.45, 1);
            }
            return Qt.rgba(1, 1, 1, 1);
        }
        const t = Math.max(0, Math.min(100, value)) / 100;
        // muted yellow around 55% remaining; pure red by 10%
        const yellowAt = 0.55;
        const redAt = 0.10;
        // soft butter yellow (not pure/neon)
        const yR = 1.0, yG = 0.92, yB = 0.45;
        if (t <= redAt) {
            return Qt.rgba(1, 0, 0, 1);
        }
        if (t >= yellowAt) {
            // white (1,1,1) → muted yellow
            const u = (t - yellowAt) / (1 - yellowAt);
            return Qt.rgba(1, 1 - (1 - yG) * (1 - u), 1 - (1 - yB) * (1 - u), 1);
        }
        // muted yellow → red (1,0,0)
        const u = (t - redAt) / (yellowAt - redAt);
        return Qt.rgba(1, yG * u, yB * u, 1);
    }

    spacing: Kirigami.Units.smallSpacing / 2

    PlasmaComponents3.ToolTip.delay: Qt.styleHints.mousePressAndHoldInterval
    PlasmaComponents3.ToolTip.visible: hoverHandler.hovered && PlasmaComponents3.ToolTip.text !== ""
    PlasmaComponents3.ToolTip.text: tooltipText()

    HoverHandler {
        id: hoverHandler
    }

    Timer {
        interval: 60000
        repeat: true
        running: row.visible && row.timeLeftFraction >= 0
        onTriggered: row.nowMs = Date.now()
    }

    function tooltipText() {
        const parts = [];
        const reset = formatResetTime(row.resetsAt);
        if (reset) {
            parts.push(reset);
        }
        if (row.timeLeftFraction >= 0) {
            parts.push(i18n("%1% of window remaining", Math.round(row.timeLeftFraction * 100)));
        }
        const pace = paceText();
        if (pace) {
            parts.push(pace);
        }
        return parts.join("\n");
    }

    // CodexBar's own pace prose when the CLI sent one; otherwise the same
    // "reserve | expected | outlook" line built here so it can be translated.
    function paceText() {
        const pace = row.pace;
        if (!pace) {
            return "";
        }
        if (pace.summary) {
            return String(pace.summary);
        }
        const parts = [];
        const delta = Number(pace.deltaPercent);
        if (Number.isFinite(delta)) {
            parts.push(delta <= 0
                ? i18n("%1% in reserve", Math.abs(delta))
                : i18n("%1% in deficit", delta));
        }
        const expected = Number(pace.expectedUsedPercent);
        if (Number.isFinite(expected)) {
            parts.push(i18n("Expected %1% used", Math.round(expected)));
        }
        if (pace.willLastToReset === true) {
            parts.push(i18n("Lasts until reset"));
        } else {
            const eta = Number(pace.etaSeconds);
            if (Number.isFinite(eta)) {
                parts.push(i18n("Projected empty in %1", formatDuration(eta)));
            }
        }
        return parts.join(" | ");
    }

    // Compact elapsed time shared by the reset and pace tooltip lines.
    function formatDuration(seconds) {
        const total = Math.max(0, Math.floor(Number(seconds) || 0));
        const days = Math.floor(total / 86400);
        const hours = Math.floor((total % 86400) / 3600);
        const minutes = Math.floor((total % 3600) / 60);

        const parts = [];
        if (days > 0) {
            parts.push(i18np("%1 day", "%1 days", days));
        }
        if (hours > 0 || days > 0) {
            parts.push(i18np("%1 hour", "%1 hours", hours));
        }
        if (days === 0 || minutes > 0) {
            parts.push(i18np("%1 minute", "%1 minutes", minutes));
        }

        return parts.join(" ");
    }

    function formatResetTime(value) {
        if (!value) {
            return "";
        }
        const date = new Date(value);
        if (!Number.isFinite(date.getTime())) {
            return "";
        }
        const diffMs = date.getTime() - Date.now();
        if (diffMs <= 0) {
            return i18n("Resetting...");
        }
        return i18n("Resets in %1", formatDuration(Math.floor(diffMs / 1000)));
    }

    RowLayout {
        Layout.fillWidth: true

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: row.title
            font: Kirigami.Theme.smallFont
            elide: Text.ElideRight
        }

        PlasmaComponents3.Label {
            text: Number.isFinite(Number(row.percentLeft)) ? Math.round(Number(row.percentLeft)) + "%" : "—"
            color: Kirigami.Theme.disabledTextColor
            font: Kirigami.Theme.smallFont
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Kirigami.Units.smallSpacing
        radius: height / 2
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.09)

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * Math.max(0, Math.min(100, Number(row.percentLeft))) / 100
            radius: parent.radius
            color: row.remainingColor
        }

        // Time-remaining marker. Fill short of the marker means usage is
        // outpacing the clock and the window is likely to run dry before reset.
        Rectangle {
            id: timeMarker
            visible: row.timeLeftFraction >= 0
            width: 2
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height + Kirigami.Units.smallSpacing
            x: Math.max(0, Math.min(parent.width - width, parent.width * row.timeLeftFraction - width / 2))
            radius: 1
            color: Kirigami.Theme.textColor
            opacity: 0.85
        }
    }

    PlasmaComponents3.Label {
        Layout.fillWidth: true
        visible: row.resetsAt.length > 0 && formatResetTime(row.resetsAt) !== ""
        text: formatResetTime(row.resetsAt)
        color: Kirigami.Theme.disabledTextColor
        font: Kirigami.Theme.smallFont
        elide: Text.ElideRight
    }
}
