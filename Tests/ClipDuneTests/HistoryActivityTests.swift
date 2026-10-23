import Foundation
import ClipDuneCore

final class HistoryActivityTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipdune-activity-\(UUID().uuidString)")
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func content(_ text: String, html: String? = nil) -> ClipboardContent {
        var representations = [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]
        if let html { representations.append(.init(type: "public.html", data: Data(html.utf8))) }
        return ClipboardContent(fragments: [.init(representations: representations)], text: text,
                                kind: html == nil ? .text : .html, sourceName: "Fixture", sourceBundleID: "app.clipdune.fixture")
    }

    func successfulUseMovesWithoutChangingContentOrCaptureTime() async throws {
        let store = try HistoryStore(directory: directory)
        let copiedAt = now.addingTimeInterval(-60)
        let usedAt = now
        let original = content("kept", html: "<b>kept</b>")
        let identity = try await store.record(original, at: copiedAt)
        try await store.record(content("newer"), at: copiedAt.addingTimeInterval(30))
        try await store.setPinned(true, for: identity)
        try await store.rename(identity, title: "收藏名称")
        let bytes = try await store.storageUsage().totalBytes
        try await store.recordUse(of: identity, at: usedAt)
        let summaries = try await store.search()
        expectEqual(summaries.count, 2)
        expectEqual(summaries.first?.id, identity)
        expectEqual(summaries.first?.copiedAt, copiedAt)
        expectEqual(summaries.first?.lastUsedAt, usedAt)
        expectEqual(summaries.first?.isPinned, true)
        expectEqual(summaries.first?.userTitle, "收藏名称")
        expectEqual(try await store.content(for: identity), original)
        expectEqual(try await store.storageUsage().totalBytes, bytes)
        try await store.recordUse(of: identity, at: copiedAt)
        expectEqual(try await store.search().first?.lastUsedAt, usedAt)
        try await store.rename(identity, title: "改名不刷新")
        try await store.setPinned(false, for: identity)
        expectEqual(try await store.search().first?.lastUsedAt, usedAt)
    }

    func deduplicationRetainsFormattingDifferences() async throws {
        let store = try HistoryStore(directory: directory)
        let plain = try await store.record(content("same"))
        let bold = try await store.record(content("same", html: "<b>same</b>"))
        let italic = try await store.record(content("same", html: "<i>same</i>"))
        try await store.rename(bold, title: "粗体版本")
        try await store.setPinned(true, for: bold)
        expectEqual(try await store.record(content("same", html: "<b>same</b>")), bold)
        expectEqual(try await store.search().count, 3)
        expectEqual(try await store.search().first?.id, bold)
        expectEqual(try await store.search().first?.userTitle, "粗体版本")
        expectEqual(try await store.search().first?.isPinned, true)
        expectNotEqual(plain, bold)
        expectNotEqual(bold, italic)
    }

    func filtersAndExpirationUseRecentActivity() async throws {
        let store = try HistoryStore(directory: directory)
        let copiedAt = now.addingTimeInterval(-10 * 86_400)
        let identity = try await store.record(content("used today"), at: copiedAt)
        let unused = try await store.record(content("unused"), at: copiedAt)
        let usedAt = now
        try await store.recordUse(of: identity, at: usedAt)
        expectEqual(try await store.search(filter: .init(period: .today), now: usedAt).map(\.id), [identity])
        try await store.pruneExpired(now: usedAt.addingTimeInterval(25 * 86_400))
        expectEqual(try await store.search().map(\.id), [identity])
        expectNil(try await store.content(for: unused))
        try await store.delete(identity)
        try await store.recordUse(of: identity)
        expectTrue(try await store.search().isEmpty)
    }

    func capacityEvictsLeastRecentlyUsedAndProtectsPins() async throws {
        let store = try HistoryStore(directory: directory)
        let rowBytes = try JSONEncoder().encode(content("aaa")).count
        let pinned = try await store.record(content("aaa"), at: Date().addingTimeInterval(-60))
        try await store.setPinned(true, for: pinned)
        let used = try await store.record(content("bbb"), at: Date().addingTimeInterval(-40))
        let unused = try await store.record(content("ccc"), at: Date().addingTimeInterval(-20))
        try await store.recordUse(of: used)
        expectEqual(try await store.storageUsage().pinnedBytes, rowBytes)
        try await store.setMaximumBytes(rowBytes * 2)
        expectEqual(Set(try await store.search().map(\.id)), [pinned, used])
        expectNil(try await store.content(for: unused))
        expectTrue(try await store.search("ccc").isEmpty)
        expectEqual(try await store.storageUsage().totalBytes, rowBytes * 2)
    }

    func rejectedReductionAndCaptureRollBack() async throws {
        let store = try HistoryStore(directory: directory)
        let rowBytes = try JSONEncoder().encode(content("aaa")).count
        let pinned = try await store.record(content("aaa"))
        try await store.setPinned(true, for: pinned)
        let ordinary = try await store.record(content("bbb"))
        do {
            try await store.setMaximumBytes(rowBytes - 1)
            fail("Expected pinned capacity rejection")
        } catch HistoryError.capacityReached { }
        expectEqual(Set(try await store.search().map(\.id)), [pinned, ordinary])
        try await store.record(content("ccc"))
        expectEqual(try await store.search().count, 3)
        try await store.setMaximumBytes(rowBytes)
        do {
            try await store.record(content("ddd"))
            fail("Expected full capacity rejection")
        } catch HistoryError.capacityReached { }
        expectEqual(try await store.search().map(\.id), [pinned])
        expectTrue(try await store.search("ddd").isEmpty)
        expectEqual(try await store.record(content("aaa")), pinned)
        try await store.recordUse(of: pinned)
        for invalid in [0, -1, HistoryLimits.maximumConfigurableBytes + 1] {
            do { try await store.setMaximumBytes(invalid); fail("Expected invalid capacity rejection") }
            catch HistoryError.invalidCapacity { }
        }
        try await store.setMaximumBytes(rowBytes * 2)
        try await store.record(content("eee"))
        expectEqual(try await store.search().count, 2)
    }

    func countLimitAlsoUsesRecentActivity() async throws {
        let store = try HistoryStore(directory: directory, limits: .init(maximumItems: 2))
        let first = try await store.record(content("first"), at: Date().addingTimeInterval(-60))
        let second = try await store.record(content("second"), at: Date().addingTimeInterval(-30))
        try await store.recordUse(of: first)
        let third = try await store.record(content("third"))
        expectEqual(Set(try await store.search().map(\.id)), [first, third])
        expectNil(try await store.content(for: second))
    }

    func archiveAndReopenPreserveRecencyWithoutRewinding() async throws {
        let store = try HistoryStore(directory: directory)
        let copiedAt = now.addingTimeInterval(-60)
        let usedAt = now.addingTimeInterval(-10)
        let identity = try await store.record(content("first"), at: copiedAt)
        let oldBackup = directory.appendingPathComponent("old.clipdunebackup")
        try await store.exportArchive().write(to: oldBackup)
        try await store.record(content("second"), at: copiedAt.addingTimeInterval(30))
        try await store.recordUse(of: identity, at: usedAt)
        _ = try await store.importArchive(from: oldBackup, excludedApplications: [])
        expectEqual(try await store.search().first?.lastUsedAt, usedAt)
        let backup = directory.appendingPathComponent("current.clipdunebackup")
        try await store.exportArchive().write(to: backup)
        let destination = try HistoryStore(directory: directory.appendingPathComponent("restored"))
        expectEqual(try await destination.importArchive(from: backup, excludedApplications: []), 2)
        expectEqual(try await destination.search().first?.text, "first")
        expectEqual(try await destination.search().first?.lastUsedAt, usedAt)
        expectEqual(try await destination.search().first?.copiedAt, copiedAt)
        let reopened = try HistoryStore(directory: directory)
        expectEqual(try await reopened.search().first?.lastUsedAt, usedAt)
        try await reopened.record(content("first"), at: copiedAt.addingTimeInterval(40))
        expectEqual(try await reopened.search().first?.lastUsedAt, usedAt)
    }

    func legacyDatabaseBackfillsAndLegacyWriterUpdatesActivity() async throws {
        let store = try HistoryStore(directory: directory)
        let copiedAt = now.addingTimeInterval(-60)
        let identity = try await store.record(content("legacy"), at: copiedAt)
        try await store.rename(identity, title: "旧版名称")
        try sqlite("DROP TRIGGER activity_insert; DROP TRIGGER activity_copy; DROP TRIGGER activity_delete; DROP TABLE clip_activity;")
        let reopened = try HistoryStore(directory: directory)
        expectEqual(try await reopened.search().first?.lastUsedAt, copiedAt)
        expectEqual(try await reopened.search().first?.userTitle, "旧版名称")
        let updated = now.timeIntervalSince1970
        try sqlite("UPDATE clips SET copied_at=\(updated) WHERE id='\(identity)';")
        expectEqual(try await reopened.search().first?.lastUsedAt, Date(timeIntervalSince1970: updated))
        try await reopened.delete(identity)
        try await reopened.recordUse(of: identity)
        expectTrue(try await reopened.search().isEmpty)
    }

    func storagePreferencesPersistAndRejectInvalidValues() throws {
        let suite = "app.clipdune.storage.test.\(UUID().uuidString)"
        let defaults = try requireValue(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        expectEqual(AppPreferences(defaults: defaults).maximumStorageMiB, 256)
        for capacity in AppPreferences.storageOptionsMiB {
            var preferences = AppPreferences(defaults: defaults)
            preferences.maximumStorageMiB = capacity
            preferences.save(to: defaults)
            expectEqual(AppPreferences(defaults: defaults).maximumStorageMiB, capacity)
            expectEqual(AppPreferences(defaults: defaults).maximumStorageBytes, capacity * 1024 * 1024)
        }
        for invalid in [-1, 0, 63, 2_049, Int.max] {
            defaults.set(invalid, forKey: "maximumStorageMiB")
            expectEqual(AppPreferences(defaults: defaults).maximumStorageMiB, 256)
        }
    }

    func legacyAndInvalidActivityArchivesAreHandledSafely() async throws {
        let store = try HistoryStore(directory: directory)
        let copiedAt = now.addingTimeInterval(-60)
        try await store.record(content("legacy archive"), at: copiedAt)
        let url = directory.appendingPathComponent("legacy.clipdunebackup")
        var json = try requireValue(JSONSerialization.jsonObject(with: await store.exportArchive()) as? [String: Any])
        var entries = try requireValue(json["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "lastUsedAt")
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let restored = try HistoryStore(directory: directory.appendingPathComponent("restored"))
        expectEqual(try await restored.importArchive(from: url, excludedApplications: []), 1)
        expectEqual(try await restored.search().first?.lastUsedAt, copiedAt)
        entries[0]["lastUsedAt"] = copiedAt.addingTimeInterval(-1).timeIntervalSinceReferenceDate
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        do {
            _ = try await restored.importArchive(from: url, excludedApplications: [])
            fail("Expected invalid activity rejection")
        } catch HistoryError.invalidContent { }
        expectEqual(try await restored.search().count, 1)
        expectEqual(try await restored.search().first?.lastUsedAt, copiedAt)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(384 * 1024 * 1024 + 1))
        try handle.close()
        do {
            _ = try await restored.importArchive(from: url, excludedApplications: [])
            fail("Expected archive size rejection")
        } catch HistoryError.archiveTooLarge { }
        expectEqual(try await restored.search().count, 1)
    }

    private func sqlite(_ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [directory.appendingPathComponent("history.sqlite3").path, sql]
        try process.run()
        process.waitUntilExit()
        expectEqual(process.terminationStatus, 0)
    }
}
