import Foundation
import ClipDuneCore

final class HistoryStoreTests {
    private var directory: URL!

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipdune-test-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func content(_ text: String, source: String = "测试应用", bundle: String = "app.clipdune.test") -> ClipboardContent {
        ClipboardContent(fragments: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])],
                         text: text, kind: .text, sourceName: source, sourceBundleID: bundle)
    }

    func testPersistsAndReopensWithoutLosingRepresentations() async throws {
        let original = ClipboardContent(fragments: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data("hello".utf8)),
            .init(type: "public.html", data: Data("<b>hello</b>".utf8))
        ])], text: "hello", kind: .richText, sourceName: "Test", sourceBundleID: "app.test")
        let store = try HistoryStore(directory: directory)
        let identity = try await store.record(original)
        let reopened = try HistoryStore(directory: directory)
        let restored = try await reopened.content(for: identity)
        expectEqual(restored, original)
    }

    func testDuplicateMovesToFrontAndPreservesPin() async throws {
        let store = try HistoryStore(directory: directory)
        let first = try await store.record(content("one"), at: Date().addingTimeInterval(-10))
        try await store.setPinned(true, for: first)
        try await store.record(content("two"), at: Date().addingTimeInterval(-5))
        let duplicate = try await store.record(content("one", source: "Another"))
        let results = try await store.search()
        expectEqual(first, duplicate)
        expectEqual(results.count, 2)
        expectEqual(results.first?.id, first)
        expectEqual(results.first?.sourceName, "Another")
        expectEqual(results.first?.isPinned, true)
    }

    func testShortChineseAndTrigramSearch() async throws {
        let store = try HistoryStore(directory: directory)
        try await store.record(content("部署前检查配置", source: "Terminal"))
        try await store.record(content("Nothing else", source: "Safari"))
        for query in ["部", "部署", "署前检", "TERMINAL", "部署前检查配置"] {
            let result = try await store.search(query)
            expectEqual(result.count, 1, query)
        }
    }

    func testSearchTreatsOperatorsAndQuotesAsLiteralText() async throws {
        let store = try HistoryStore(directory: directory)
        try await store.record(content("use \"quoted\" content and a+b"))
        for query in ["\"quoted\"", "a+b", "content and"] {
            let results = try await store.search(query)
            expectEqual(results.count, 1, query)
        }
        let injection = try await store.search("' OR 1=1 --")
        expectTrue(injection.isEmpty)
        let intact = try await store.search()
        expectEqual(intact.count, 1)
    }

    func testDeletingAlsoRemovesSearchEntries() async throws {
        let store = try HistoryStore(directory: directory)
        let identity = try await store.record(content("deletable phrase"))
        try await store.delete(identity)
        let results = try await store.search("deletable")
        expectTrue(results.isEmpty)
    }

    func testCountLimitDoesNotRemovePinnedItems() async throws {
        let store = try HistoryStore(directory: directory, limits: .init(maximumItems: 2))
        let pinned = try await store.record(content("keep me"), at: Date().addingTimeInterval(-20))
        try await store.setPinned(true, for: pinned)
        for number in 1...4 { try await store.record(content("ordinary \(number)")) }
        let results = try await store.search()
        expectEqual(results.count, 3)
        expectTrue(results.contains(where: { $0.id == pinned }))
    }

    func testExpirationKeepsPins() async throws {
        let store = try HistoryStore(directory: directory)
        let identity = try await store.record(content("pinned"))
        try await store.setPinned(true, for: identity)
        try await store.record(content("ordinary"))
        try await store.pruneExpired(now: Date().addingTimeInterval(40 * 86_400))
        let results = try await store.search()
        expectEqual(results.map(\.id), [identity])
    }

    func testCapacityFailureRollsBackNewCapture() async throws {
        let budget = try JSONEncoder().encode(content("12345678")).count
        let store = try HistoryStore(directory: directory, limits: .init(maximumBytes: budget))
        let identity = try await store.record(content("12345678"))
        try await store.setPinned(true, for: identity)
        do {
            try await store.record(content("12345"))
            fail("Expected capacity rejection")
        } catch HistoryError.capacityReached { }
        let results = try await store.search()
        expectEqual(results.map(\.id), [identity])
    }

    func testByteLimitEvictsOldestUnpinnedItem() async throws {
        let budget = try JSONEncoder().encode(content("12345678")).count
        let store = try HistoryStore(directory: directory, limits: .init(maximumBytes: budget))
        try await store.record(content("12345678"))
        let newest = try await store.record(content("abcdef"))
        let results = try await store.search()
        expectEqual(results.map(\.id), [newest])
    }

    func testRejectsOversizedAndUnknownRepresentations() async throws {
        let store = try HistoryStore(directory: directory, limits: .init(maximumItemBytes: 4))
        do { try await store.record(content("12345")); fail("Expected size rejection") }
        catch HistoryError.invalidContent { }
        let invalid = ClipboardContent(fragments: [.init(representations: [.init(type: "application/executable", data: Data([1]))])],
                                       text: "", kind: .text, sourceName: "test", sourceBundleID: "test")
        do { try await store.record(invalid); fail("Expected format rejection") }
        catch HistoryError.invalidContent { }
    }

    func testClearPreservesPinnedAndDoesNotResurrectSearchRows() async throws {
        let store = try HistoryStore(directory: directory)
        let identity = try await store.record(content("saved favorite"))
        try await store.setPinned(true, for: identity)
        try await store.record(content("transient note"))
        try await store.clearUnpinned()
        let results = try await store.search()
        expectEqual(results.map(\.id), [identity])
        let search = try await store.search("transient")
        expectTrue(search.isEmpty)
    }

    func testArchiveRoundTripPreservesPins() async throws {
        let store = try HistoryStore(directory: directory)
        let original = content("round trip")
        let identity = try await store.record(original)
        try await store.setPinned(true, for: identity)
        let archive = try await store.exportArchive()
        let file = directory.appendingPathComponent("backup.clipdunebackup")
        try archive.write(to: file)
        let restored = try HistoryStore(directory: directory.appendingPathComponent("restored"))
        let imported = try await restored.importArchive(from: file, excludedApplications: [])
        let results = try await restored.search()
        expectEqual(imported, 1)
        expectEqual(results.first?.isPinned, true)
        let restoredContent = try await restored.content(for: requireValue(results.first?.id))
        expectEqual(restoredContent, original)
    }

    func testArchiveRespectsExcludedApplications() async throws {
        let store = try HistoryStore(directory: directory)
        try await store.record(content("private fixture", bundle: "app.excluded"))
        let archive = try await store.exportArchive()
        let file = directory.appendingPathComponent("backup.clipdunebackup")
        try archive.write(to: file)
        let restored = try HistoryStore(directory: directory.appendingPathComponent("restored"))
        let count = try await restored.importArchive(from: file, excludedApplications: ["app.excluded"])
        expectEqual(count, 0)
    }

    func testMalformedImportDoesNotDestroyHistory() async throws {
        let store = try HistoryStore(directory: directory)
        try await store.record(content("keep this"))
        let file = directory.appendingPathComponent("bad.clipdunebackup")
        try Data("not json".utf8).write(to: file)
        do { _ = try await store.importArchive(from: file, excludedApplications: []); fail("Expected invalid archive") }
        catch HistoryError.invalidContent { }
        let results = try await store.search()
        expectEqual(results.first?.text, "keep this")
    }

    func testDatabasePermissionsArePrivate() async throws {
        _ = try HistoryStore(directory: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.sqlite3").path)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFingerprintIsOrderIndependentWithinItemButNotAcrossItems() {
        let first = ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("one".utf8))
        let second = ClipboardRepresentation(type: "public.html", data: Data("<b>one</b>".utf8))
        func make(_ fragments: [ClipboardFragment]) -> ClipboardContent {
            .init(fragments: fragments, text: "", kind: .text, sourceName: "", sourceBundleID: "")
        }
        expectEqual(make([.init(representations: [first, second])]).fingerprint,
                       make([.init(representations: [second, first])]).fingerprint)
        expectNotEqual(make([.init(representations: [first]), .init(representations: [second])]).fingerprint,
                          make([.init(representations: [second]), .init(representations: [first])]).fingerprint)
    }
}
