import AppKit
import ClipDuneMac

@MainActor
enum HistoryActivityUICheck {
    static func run(panel: ClipboardPanelController, open: () -> Void) async throws -> [String: Bool] {
        var results: [String: Bool] = [:]
        for copyOnly in [true, false] {
            panel.hide()
            open()
            try await Task.sleep(for: .milliseconds(150))
            guard let selected = panel.summaries.last, panel.summaries.count > 1 else {
                results["recentUseFixtureReady"] = false
                return results
            }
            let identities = Set(panel.summaries.map(\.id))
            panel.onChoose?(selected, false, copyOnly)
            try await Task.sleep(for: .milliseconds(150))
            results[copyOnly ? "copyClosesPanel" : "pasteClosesPanel"] = !panel.isVisible
            panel.hide()
            open()
            try await Task.sleep(for: .milliseconds(150))
            results[copyOnly ? "copyMovesExistingItemFirst" : "pasteMovesExistingItemFirst"] = panel.summaries.first?.id == selected.id
            results[copyOnly ? "copyDoesNotDuplicateHistory" : "pasteDoesNotDuplicateHistory"] = Set(panel.summaries.map(\.id)) == identities
            results[copyOnly ? "copyPreservesCaptureTime" : "pastePreservesCaptureTime"] = panel.summaries.first(where: { $0.id == selected.id })?.copiedAt == selected.copiedAt
        }
        return results
    }
}
