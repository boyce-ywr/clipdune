import AppKit
import Foundation
import ClipDuneCore
import ClipDuneMac

final class CardMetadataTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipdune-card-test-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func content(_ text: String, kind: ClipKind = .text, bundle: String = "com.apple.Terminal") -> ClipboardContent {
        .init(fragments: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])],
              text: text, kind: kind, sourceName: "终端", sourceBundleID: bundle)
    }

    func renameSearchPinDuplicateAndReopen() async throws {
        let store = try HistoryStore(directory: directory)
        let original = content("原始内容不变")
        let identity = try await store.record(original)
        try await store.setPinned(true, for: identity)
        try await store.rename(identity, title: "  每周汇报模板  ")
        expectEqual(try await store.search("汇报").first?.id, identity)
        expectEqual(try await store.search("每周汇报", pinnedOnly: true).first?.userTitle, "每周汇报模板")
        expectEqual(try await store.content(for: identity), original)
        try await store.record(original)
        expectEqual(try await store.search("汇报").first?.isPinned, true)
        let reopened = try HistoryStore(directory: directory)
        expectEqual(try await reopened.search("汇报").first?.userTitle, "每周汇报模板")
        try await reopened.rename(identity, title: "新名称")
        expectTrue(try await reopened.search("汇报").isEmpty)
        expectEqual(try await reopened.search("新名称").first?.id, identity)
        try await reopened.rename(identity, title: "")
        expectTrue(try await reopened.search("新名称").isEmpty)
        expectEqual(try await reopened.search().first?.userTitle, "")
    }

    func rejectsInvalidTitlesWithoutMutatingData() async throws {
        let store = try HistoryStore(directory: directory)
        let identity = try await store.record(content("body"))
        try await store.rename(identity, title: "valid")
        for title in [String(repeating: "字", count: 121), "two\nlines", "bad\0name"] {
            do { try await store.rename(identity, title: title); fail("invalid title accepted") }
            catch HistoryError.invalidTitle { }
            expectEqual(try await store.search().first?.userTitle, "valid")
        }
        try await store.rename(identity, title: "' OR 1=1 --")
        expectEqual(try await store.search("' OR 1=1 --").count, 1)
    }

    func combinedTypeDateNameAndPinFilters() async throws {
        let store = try HistoryStore(directory: directory)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let identity = try await store.record(content("unique html", kind: .html), at: today)
        try await store.setPinned(true, for: identity)
        try await store.rename(identity, title: "filter name")
        try await store.record(content("plain today"), at: today.addingTimeInterval(1))
        try await store.record(content("unique yesterday", kind: .html), at: yesterday)
        expectEqual(try await store.search("filter", pinnedOnly: true, filter: .init(kind: .html, period: .today), now: now, calendar: calendar).map(\.id), [identity])
        expectEqual(try await store.search(filter: .init(kind: .html, period: .yesterday), now: now, calendar: calendar).first?.text, "unique yesterday")
        expectEqual(try await store.search(filter: .init(period: .today), now: now, calendar: calendar).count, 2)
        expectTrue(try await store.search("filter", filter: .init(kind: .text), now: now, calendar: calendar).isEmpty)
        expectEqual(try await store.search(filter: .init(period: .lastSevenDays), now: now, calendar: calendar).count, 3)
    }

    func calendarFiltersRespectDSTAndHalfOpenBounds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let range = HistoryFilter(period: .today).dateRange(now: spring, calendar: calendar)!
        expectEqual(range.duration, 23 * 3600)
        let yesterday = HistoryFilter(period: .yesterday).dateRange(now: spring, calendar: calendar)!
        expectEqual(yesterday.end, range.start)
        expectNil(HistoryFilter().dateRange(now: spring, calendar: calendar))
    }

    func namedArchiveRoundTripAndLegacyImport() async throws {
        let store = try HistoryStore(directory: directory)
        let identity = try await store.record(content("backup text"))
        try await store.rename(identity, title: "备份名称")
        try await store.setPinned(true, for: identity)
        let archive = try await store.exportArchive()
        let url = directory.appendingPathComponent("test.clipdunebackup")
        try archive.write(to: url)
        let restored = try HistoryStore(directory: directory.appendingPathComponent("restored"))
        _ = try await restored.importArchive(from: url, excludedApplications: [])
        expectEqual(try await restored.search("备份名称", pinnedOnly: true).count, 1)
        var json = try requireValue(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        var entries = try requireValue(json["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "userTitle")
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        _ = try await restored.importArchive(from: url, excludedApplications: [])
        expectEqual(try await restored.search("备份名称").count, 1)
    }

    func backfillsOldRowsAndKeepsLegacySchemaWritable() async throws {
        let store = try HistoryStore(directory: directory)
        let identity = try await store.record(content("migration"))
        let sql = Process()
        sql.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sql.arguments = [directory.appendingPathComponent("history.sqlite3").path,
                         "DROP TRIGGER details_delete; DROP TABLE clip_details;"]
        try sql.run()
        sql.waitUntilExit()
        expectEqual(sql.terminationStatus, 0)
        let reopened = try HistoryStore(directory: directory)
        let result = try await reopened.search().first
        expectEqual(result?.id, identity)
        expectEqual(result?.sourceBundleID, "com.apple.Terminal")
        expectEqual(result?.userTitle, "")
        expectEqual(result?.contentBytes, "migration".utf8.count)
        try await reopened.rename(identity, title: "migrated name")
        try await reopened.delete(identity)
        expectTrue(try await reopened.search("migrated").isEmpty)
        let reinserted = try await reopened.record(content("migration"))
        expectTrue(reinserted != identity)
        expectEqual(try await reopened.search().first?.userTitle, "")
    }

    func newKindsKeepLegacyPayloadReadable() throws {
        for kind in [ClipKind.html, .color, .other] {
            let payload = try JSONEncoder().encode(content("test", kind: kind))
            let object = try requireValue(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            expectEqual(object["kind"] as? String, kind.legacyKind.rawValue)
            expectEqual(try JSONDecoder().decode(ClipboardContent.self, from: payload).kind, kind)
        }
        let html = ClipboardContent(fragments: [.init(representations: [.init(type: "public.html", data: Data("<p>legacy HTML</p>".utf8))])],
                                    text: "legacy HTML", kind: .richText, sourceName: "Safari", sourceBundleID: "com.apple.Safari")
        var legacy = try requireValue(JSONSerialization.jsonObject(with: JSONEncoder().encode(html)) as? [String: Any])
        legacy.removeValue(forKey: "contentKind")
        expectEqual(try JSONDecoder().decode(ClipboardContent.self, from: JSONSerialization.data(withJSONObject: legacy)).kind, .html)
    }

    @MainActor
    func codecHandlesEightKindsAndOpaqueBytes() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        func capture(_ values: [(NSPasteboard.PasteboardType, Data)]) throws -> ClipboardContent {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            pasteboard.writeObjects([item])
            return try requireValue(PasteboardCodec.read(pasteboard, sourceName: "Fixture", sourceBundleID: "test", excludedApplications: []))
        }
        let fixtures: [(ClipKind, NSPasteboard.PasteboardType, String)] = [
            (.text, .string, "hello"), (.link, .URL, "https://example.com"),
            (.richText, .rtf, "{\\rtf1 hello}"), (.html, .html, "<p>Hello &amp; welcome</p><script>hidden</script>"),
            (.files, .fileURL, "file:///tmp/synthetic.txt"), (.color, .string, "#3399CC"),
            (.other, .pdf, "%PDF synthetic fixture")
        ]
        for (kind, type, text) in fixtures {
            let clip = try capture([(type, Data(text.utf8))])
            expectEqual(clip.kind, kind)
            expectTrue(PasteboardCodec.write(clip, to: pasteboard, plainText: false))
            expectEqual(pasteboard.data(forType: type), Data(text.utf8))
            if [.richText, .html, .link].contains(kind) { expectEqual(pasteboard.string(forType: .string), clip.text) }
            if kind == .html { expectEqual(clip.text, "Hello & welcome") }
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = try capture([(.png, bitmap.representation(using: .png, properties: [:])!)])
        expectEqual(image.kind, .image)
        expectTrue(image.thumbnail != nil)
        pasteboard.clearContents()
        pasteboard.declareTypes([.color], owner: nil)
        NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1).write(to: pasteboard)
        let native = try requireValue(PasteboardCodec.read(pasteboard, sourceName: "test", sourceBundleID: "test", excludedApplications: []))
        expectEqual(native.kind, .color)
        expectTrue(PasteboardCodec.write(native, to: pasteboard, plainText: false))
        expectTrue(NSColor(from: pasteboard) != nil)
        expectEqual(pasteboard.string(forType: .string), native.text)
        let type = NSPasteboard.PasteboardType("com.example.custom-data")
        let bytes = Data([0, 1, 255, 2])
        let opaque = try capture([(type, bytes)])
        expectEqual(opaque.kind, .other)
        expectTrue(PasteboardCodec.write(opaque, to: pasteboard, plainText: false))
        expectEqual(pasteboard.data(forType: type), bytes)
    }

    func summaryShowsCharactersImageBytesAndFileCount() async throws {
        let store = try HistoryStore(directory: directory)
        try await store.record(content("中👨‍👩‍👧‍👦e\u{301}"))
        expectEqual(try await store.search().first?.sizeLabel, "3 个字符")
        let representations = [ClipboardRepresentation(type: "public.png", data: Data(repeating: 1, count: 1024)),
                               ClipboardRepresentation(type: "public.tiff", data: Data(repeating: 2, count: 4096))]
        try await store.record(.init(fragments: [.init(representations: representations)], text: "", kind: .image,
                                    sourceName: "image", sourceBundleID: "test", thumbnail: Data(repeating: 3, count: 100)))
        expectEqual(try await store.search(filter: .init(kind: .image)).first?.contentBytes, 1024)
        let tiff = ClipboardContent(fragments: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data("caption".utf8)),
            .init(type: "public.tiff", data: Data(repeating: 1, count: 2048))
        ])], text: "caption", kind: .image, sourceName: "image", sourceBundleID: "test")
        expectEqual(tiff.contentByteCount, 2048)
        let files = ["file:///tmp/a", "file:///tmp/b"].map { ClipboardFragment(representations: [.init(type: "public.file-url", data: Data($0.utf8))]) }
        try await store.record(.init(fragments: files, text: "a\nb", kind: .files, sourceName: "Finder", sourceBundleID: "com.apple.finder"))
        expectEqual(try await store.search(filter: .init(kind: .files)).first?.sizeLabel, "2 个文件引用")
    }

    func everyKindIsIndependentlySearchable() async throws {
        let store = try HistoryStore(directory: directory)
        for kind in ClipKind.allCases {
            try await store.record(content("fixture \(kind.rawValue)", kind: kind))
        }
        for kind in ClipKind.allCases {
            let results = try await store.search("fixture", filter: .init(kind: kind))
            expectEqual(results.count, 1)
            expectEqual(results.first?.kind, kind)
        }
    }

    func oldVersionCanReadPayloadAndInsertOriginalSchema() async throws {
        struct LegacyPayload: Decodable {
            let text: String
            let kind: String
            let fragments: [ClipboardFragment]
        }
        let store = try HistoryStore(directory: directory)
        let entry = content("legacy compatible", kind: .html)
        let identity = try await store.record(entry)
        try await store.rename(identity, title: "title survives rollback")
        let bytes = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LegacyPayload.self, from: bytes)
        expectEqual(decoded.kind, "richText")
        expectEqual(decoded.text, "legacy compatible")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        process.arguments = [directory.appendingPathComponent("history.sqlite3").path,
            "INSERT INTO clips VALUES('legacy-insert','legacy-hash',\(Date().timeIntervalSince1970),'old writer','text','legacy app','old writer',0,\(bytes.count),X'\(hex)',NULL); SELECT user_version FROM pragma_user_version;"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        expectEqual(process.terminationStatus, 0)
        expectEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let reopened = try HistoryStore(directory: directory)
        expectEqual(try await reopened.search().count, 2)
        expectEqual(try await reopened.search("title survives").first?.id, identity)
    }

    @MainActor
    func panelUsesScreenWidthWithSmallSafeInsets() {
        for screen in [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: -2560, y: 0, width: 2560, height: 1440), NSRect(x: 200, y: 60, width: 1024, height: 768)] {
            let frame = ClipboardPanelController.frame(on: screen)
            expectEqual(frame.minX - screen.minX, 16)
            expectEqual(screen.maxX - frame.maxX, 16)
            expectTrue(screen.contains(frame))
        }
    }
}
