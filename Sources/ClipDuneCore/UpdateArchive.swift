import Foundation

public enum UpdateArchive {
    public static func validateEntries(at url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 22, size <= 256 * 1024 * 1024 else { throw UpdateError.invalidDownload }
        let tailSize = min(size, 65_557)
        try file.seek(toOffset: size - tailSize)
        guard let tail = try file.read(upToCount: Int(tailSize)), tail.count == tailSize else { throw UpdateError.invalidDownload }
        var endOffset: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if uint32(tail, offset) == 0x06054b50, offset + 22 + Int(uint16(tail, offset + 20)) == tail.count {
                endOffset = offset
                break
            }
        }
        guard let endOffset, uint16(tail, endOffset + 4) == 0, uint16(tail, endOffset + 6) == 0 else { throw UpdateError.invalidDownload }
        let entryCount = Int(uint16(tail, endOffset + 10))
        let centralSize = Int(uint32(tail, endOffset + 12))
        let centralOffset = UInt64(uint32(tail, endOffset + 16))
        guard entryCount > 0, entryCount <= 4_096, centralSize <= 4 * 1024 * 1024,
              centralOffset + UInt64(centralSize) <= size - tailSize + UInt64(endOffset) else { throw UpdateError.invalidDownload }
        try file.seek(toOffset: centralOffset)
        guard let central = try file.read(upToCount: centralSize), central.count == centralSize else { throw UpdateError.invalidDownload }
        var offset = 0
        var expanded: UInt64 = 0
        var names = Set<String>()
        for _ in 0..<entryCount {
            guard offset + 46 <= central.count, uint32(central, offset) == 0x02014b50 else { throw UpdateError.invalidDownload }
            let nameSize = Int(uint16(central, offset + 28))
            let extraSize = Int(uint16(central, offset + 30))
            let commentSize = Int(uint16(central, offset + 32))
            let next = offset + 46 + nameSize + extraSize + commentSize
            guard next <= central.count, uint16(central, offset + 8) & 1 == 0,
                  [0, 8].contains(uint16(central, offset + 10)), uint16(central, offset + 34) == 0,
                  let name = String(data: central.subdata(in: (offset + 46)..<(offset + 46 + nameSize)), encoding: .utf8),
                  isSafeEntry(name), names.insert(name).inserted else { throw UpdateError.invalidDownload }
            let mode = (uint32(central, offset + 38) >> 16) & 0o170000
            guard mode == 0 || mode == 0o100000 || mode == 0o040000 else { throw UpdateError.invalidDownload }
            expanded += UInt64(uint32(central, offset + 24))
            guard expanded <= 512 * 1024 * 1024 else { throw UpdateError.invalidDownload }
            offset = next
        }
        guard offset == central.count else { throw UpdateError.invalidDownload }
    }

    public static func isSafeEntry(_ name: String) -> Bool {
        guard name.hasPrefix("ClipDune.app/"), !name.contains("\\"), !name.contains("\0"), name.utf8.count <= 1024 else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." })
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(uint16(data, offset)) | UInt32(uint16(data, offset + 2)) << 16
    }
}
