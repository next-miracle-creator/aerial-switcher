import AerialCore
import SwiftUI

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        ForEach(statusLines, id: \.self) { Text($0) }
        if let plan = model.downloadPlan, !plan.isEmpty {
            Divider()
            Text(downloadLine(plan))
            if plan.fitsOnDisk {
                Button(model.downloadOffered ? tr("Download") : tr("Retry Download")) { model.startDownload() }
                    .disabled(model.download != nil)
            } else {
                // Nothing to gain by starting it: the menu says so instead of offering.
                Text(tr("Not enough free space to download."))
            }
        }
        Divider()
        Toggle(tr("Switch Wallpaper"), isOn: Binding(get: { model.config.enabled }, set: { model.setEnabled($0) }))
            .disabled(model.selectedSet == nil)
        Toggle(tr("Pause"), isOn: Binding(get: { model.config.paused }, set: { model.setPaused($0) }))
            .disabled(model.selectedSet == nil || !model.config.enabled)
        Divider()
        Picker(tr("Set"), selection: Binding(
            get: { model.config.setID ?? "" },
            set: { model.selectSet($0) }
        )) {
            ForEach(model.sets) { Text(tr($0.name)).tag($0.id) }
        }
        .pickerStyle(.inline)
        Divider()
        Button(tr("Settings…")) {
            NotificationCenter.default.post(name: .showSettings, object: nil)
        }
        .keyboardShortcut(",")
        Button(tr("Quit Aerial Switcher")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLines: [String] {
        guard let set = model.selectedSet else { return [model.error.map { tr($0) } ?? tr("Choose a set below")] }
        var lines = [[tr(set.name), model.config.enabled ? model.currentPhase?.name : nil].compactMap { $0 }.joined(separator: " · ")]

        if let error = model.error {
            lines.append("⚠︎ " + tr(error))
        } else if let download = model.download {
            lines.append(tr("Downloading %1$@ of %2$@ · %3$@%%", "\(download.index + 1)", "\(download.count)", "\(Int(download.fraction * 100))"))
        } else if !model.config.enabled {
            lines.append(model.stoodAside ? tr("Stopped · showing your wallpaper") : tr("Off · original wallpaper"))
        } else if model.config.paused {
            lines.append(tr("Paused"))
        } else if let next = model.nextChange {
            let time = next.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.shared.locale))
            lines.append(tr("%1$@ at %2$@", next.phase.name, time))
        }
        return lines
    }

    private func downloadLine(_ plan: DownloadPlan) -> String {
        let size = plan.sizesKnown ? AppModel.showing(plan.totalBytes) : tr("size unknown")
        return tr("Missing %1$@ video(s) · %2$@", "\(plan.aerials.count)", size)
    }
}
