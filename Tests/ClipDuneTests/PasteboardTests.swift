import AppKit
import ClipDuneCore
import ClipDuneMac

final class PasteboardTests {
    @MainActor
    func testConfidentialMarkerPreventsCapture() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("synthetic secret", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        expectNil(try PasteboardCodec.read(pasteboard, sourceName: "Fixture", sourceBundleID: "test", excludedApplications: []))
    }

    @MainActor
    func testExcludedApplicationPreventsCapture() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("fixture", forType: .string)
        expectNil(try PasteboardCodec.read(pasteboard, sourceName: "Fixture", sourceBundleID: "excluded", excludedApplications: ["excluded"]))
    }

    @MainActor
    func testRichTextRepresentationsArePreservedAndOwnWritesIgnored() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setString("<strong>hello</strong>", forType: .html)
        pasteboard.writeObjects([item])
        let content = try requireValue(PasteboardCodec.read(pasteboard, sourceName: "Fixture", sourceBundleID: "test", excludedApplications: []))
        expectEqual(content.kind, .richText)
        expectEqual(content.fragments[0].representations.count, 2)
        expectTrue(PasteboardCodec.write(content, to: pasteboard, plainText: false))
        expectEqual(pasteboard.string(forType: .html), "<strong>hello</strong>")
        expectNil(try PasteboardCodec.read(pasteboard, sourceName: "Fixture", sourceBundleID: "test", excludedApplications: []))
    }

    @MainActor
    func testPlainTextPasteOmitsFormatting() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setString("<b>hello</b>", forType: .html)
        pasteboard.writeObjects([item])
        let content = try requireValue(PasteboardCodec.read(pasteboard, sourceName: "Fixture", sourceBundleID: "test", excludedApplications: []))
        expectTrue(PasteboardCodec.write(content, to: pasteboard, plainText: true))
        expectEqual(pasteboard.string(forType: .string), "hello")
        expectNil(pasteboard.string(forType: .html))
    }

    @MainActor
    func testMultipleFileReferencesStaySeparate() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let items = ["file:///tmp/first.txt", "file:///tmp/second.txt"].map { name in
            let item = NSPasteboardItem()
            item.setString(name, forType: .fileURL)
            return item
        }
        pasteboard.writeObjects(items)
        let content = try requireValue(PasteboardCodec.read(pasteboard, sourceName: "Finder", sourceBundleID: "test", excludedApplications: []))
        expectEqual(content.kind, .files)
        expectEqual(content.fragments.count, 2)
        expectTrue(PasteboardCodec.write(content, to: pasteboard, plainText: false))
        expectEqual(pasteboard.pasteboardItems?.count, 2)
    }

    func testPrivacyPolicyHandlesPauseAndKnownMarkers() {
        for marker in CapturePolicy.confidentialTypes {
            expectFalse(CapturePolicy.allows(types: [marker], sourceBundleID: "test", excludedApplications: [], paused: false))
        }
        expectFalse(CapturePolicy.allows(types: [], sourceBundleID: "test", excludedApplications: [], paused: true))
        expectTrue(CapturePolicy.allows(types: ["public.utf8-plain-text"], sourceBundleID: "test", excludedApplications: [], paused: false))
    }
}
