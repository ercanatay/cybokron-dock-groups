import Foundation

/// Experimental bounded parser for Mach-O slice metadata.
/// This parses only the provided bytes and says nothing about signatures,
/// identity, path races, or production authorization.
internal enum MachOSliceTable {
    struct Slice: Equatable {
        let offset: UInt64
        let size: UInt64
    }

    private struct ArchitecturePair: Hashable {
        let cpu: UInt32
        let subtype: UInt32
    }

    static func parse(prefix: Data, fileSize: UInt64) -> [Slice]? {
        guard prefix.count <= 520 else { return nil }
        guard UInt64(prefix.count) <= fileSize else { return nil }
        if prefix.count == 0 { return nil }

        let bytes = Array(prefix)

        // Try thin Mach-O (four magic sequences; at least 28 bytes for 32-bit,
        // 32 bytes for 64-bit). Only a single offset-zero slice of fileSize.
        if let thin = parseThin(prefix: bytes, fileSize: fileSize) {
            return thin
        }

        // Only big-endian FAT_MAGIC and FAT_MAGIC_64.
        if bytes.count >= 8 {
            if let fat = parseFat32(prefix: bytes, fileSize: fileSize) {
                return fat
            }
            if let fat = parseFat64(prefix: bytes, fileSize: fileSize) {
                return fat
            }
        }

        return nil
    }

    // MARK: - Thin helpers

    private static func parseThin(prefix: [UInt8], fileSize: UInt64) -> [Slice]? {
        // 32-bit LE: MH_MAGIC little-endian bytes
        if prefix.count >= 28,
           prefix[0] == 0xce, prefix[1] == 0xfa, prefix[2] == 0xed, prefix[3] == 0xfe {
            return [Slice(offset: 0, size: fileSize)]
        }
        // 32-bit BE: MH_CIGAM big-endian bytes
        if prefix.count >= 28,
           prefix[0] == 0xfe, prefix[1] == 0xed, prefix[2] == 0xfa, prefix[3] == 0xce {
            return [Slice(offset: 0, size: fileSize)]
        }
        // 64-bit LE: MH_MAGIC_64 little-endian bytes
        if prefix.count >= 32,
           prefix[0] == 0xcf, prefix[1] == 0xfa, prefix[2] == 0xed, prefix[3] == 0xfe {
            return [Slice(offset: 0, size: fileSize)]
        }
        // 64-bit BE: MH_CIGAM_64 big-endian bytes
        if prefix.count >= 32,
           prefix[0] == 0xfe, prefix[1] == 0xed, prefix[2] == 0xfa, prefix[3] == 0xcf {
            return [Slice(offset: 0, size: fileSize)]
        }
        return nil
    }

    // MARK: - Fat helpers

    private static func parseFat32(prefix: [UInt8], fileSize: UInt64) -> [Slice]? {
        guard prefix.count >= 8 else { return nil }
        guard prefix[0] == 0xca, prefix[1] == 0xfe, prefix[2] == 0xba, prefix[3] == 0xbe else { return nil }

        guard let countU32 = readUInt32(prefix, at: 4) else { return nil }
        let count = Int(countU32)
        if count < 1 || count > 16 { return nil }

        let recordSize = 20
        let tableSize = 8 + count * recordSize
        if tableSize > prefix.count { return nil }
        if UInt64(tableSize) > fileSize { return nil }

        var slices: [Slice] = []
        slices.reserveCapacity(count)
        var seenPairs = Set<ArchitecturePair>()
        let tableEnd = UInt64(tableSize)

        for i in 0..<count {
            let offset = 8 + i * recordSize
            guard let cpu = readUInt32(prefix, at: offset) else { return nil }
            guard let subtype = readUInt32(prefix, at: offset + 4) else { return nil }
            guard let offsetU32 = readUInt32(prefix, at: offset + 8) else { return nil }
            guard let sizeU32 = readUInt32(prefix, at: offset + 12) else { return nil }
            guard let alignU32 = readUInt32(prefix, at: offset + 16) else { return nil }

            let sliceOffset = UInt64(offsetU32)
            let sliceSize = UInt64(sizeU32)
            let align = alignU32

            // Zero size rejection.
            if sliceSize == 0 { return nil }

            // Offset before table end.
            if sliceOffset < tableEnd { return nil }

            // Offset outside file or size exceeds remaining file.
            if sliceOffset >= fileSize { return nil }
            // Safe arithmetic: ensure no overflow in subtraction.
            if fileSize < sliceOffset { return nil } // impossible after previous check, kept for safety
            if sliceSize > fileSize - sliceOffset { return nil }

            // Alignment checks (align is exponent).
            if align > 31 { return nil }
            let alignBytes = UInt64(1) << align
            if alignBytes == 0 { return nil } // overflow protection
            if sliceOffset % alignBytes != 0 { return nil }

            // Duplicate cpu/subtype.
            let pair = ArchitecturePair(cpu: cpu, subtype: subtype)
            if seenPairs.contains(pair) { return nil }
            seenPairs.insert(pair)

            slices.append(Slice(offset: sliceOffset, size: sliceSize))
        }

        // Overlap detection (unsorted records allowed).
        for i in 0..<slices.count {
            for j in (i + 1)..<slices.count {
                let a = slices[i]
                let b = slices[j]
                // Overlap if [a.offset, a.offset + a.size) and [b.offset, b.offset + b.size) intersect.
                // Use safe arithmetic: since individual ranges are within file, sums are safe.
                let aEnd = a.offset + a.size
                let bEnd = b.offset + b.size
                if a.offset < bEnd && b.offset < aEnd {
                    return nil
                }
            }
        }

        return slices
    }

    private static func parseFat64(prefix: [UInt8], fileSize: UInt64) -> [Slice]? {
        guard prefix.count >= 8 else { return nil }
        guard prefix[0] == 0xca, prefix[1] == 0xfe, prefix[2] == 0xba, prefix[3] == 0xbf else { return nil }

        guard let countU32 = readUInt32(prefix, at: 4) else { return nil }
        let count = Int(countU32)
        if count < 1 || count > 16 { return nil }

        let recordSize = 32
        let tableSize = 8 + count * recordSize
        if tableSize > prefix.count { return nil }
        if UInt64(tableSize) > fileSize { return nil }

        var slices: [Slice] = []
        slices.reserveCapacity(count)
        var seenPairs = Set<ArchitecturePair>()
        let tableEnd = UInt64(tableSize)

        for i in 0..<count {
            let offset = 8 + i * recordSize
            guard let cpu = readUInt32(prefix, at: offset) else { return nil }
            guard let subtype = readUInt32(prefix, at: offset + 4) else { return nil }
            guard let offsetU64 = readUInt64(prefix, at: offset + 8) else { return nil }
            guard let sizeU64 = readUInt64(prefix, at: offset + 16) else { return nil }
            guard let alignU32 = readUInt32(prefix, at: offset + 24) else { return nil }
            guard let reservedU32 = readUInt32(prefix, at: offset + 28) else { return nil }

            let sliceOffset = offsetU64
            let sliceSize = sizeU64
            let align = alignU32

            // Zero size.
            if sliceSize == 0 { return nil }

            // Nonzero reserved in 64-bit record.
            if reservedU32 != 0 { return nil }

            // Offset before table end.
            if sliceOffset < tableEnd { return nil }

            // Offset outside file.
            if sliceOffset >= fileSize { return nil }

            // Size exceeds remaining file (safe arithmetic).
            if fileSize < sliceOffset { return nil } // defensive
            if sliceSize > fileSize - sliceOffset { return nil }

            // Alignment exponent.
            if align > 63 { return nil }
            let alignBytes = UInt64(1) << align
            if alignBytes == 0 { return nil }
            if sliceOffset % alignBytes != 0 { return nil }

            // Duplicate architecture/subarchitecture.
            let pair = ArchitecturePair(cpu: cpu, subtype: subtype)
            if seenPairs.contains(pair) { return nil }
            seenPairs.insert(pair)

            slices.append(Slice(offset: sliceOffset, size: sliceSize))
        }

        // Overlap detection.
        for i in 0..<slices.count {
            for j in (i + 1)..<slices.count {
                let a = slices[i]
                let b = slices[j]
                let aEnd = a.offset + a.size
                let bEnd = b.offset + b.size
                if a.offset < bEnd && b.offset < aEnd {
                    return nil
                }
            }
        }

        return slices
    }

    // MARK: - Bytewise big-endian readers (no unsafe alignment)

    private static func readUInt32(_ data: [UInt8], at index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= data.count else { return nil }
        return (UInt32(data[index]) << 24)
             | (UInt32(data[index + 1]) << 16)
             | (UInt32(data[index + 2]) << 8)
             | UInt32(data[index + 3])
    }

    private static func readUInt64(_ data: [UInt8], at index: Int) -> UInt64? {
        guard index >= 0, index + 8 <= data.count else { return nil }
        return (UInt64(data[index]) << 56)
             | (UInt64(data[index + 1]) << 48)
             | (UInt64(data[index + 2]) << 40)
             | (UInt64(data[index + 3]) << 32)
             | (UInt64(data[index + 4]) << 24)
             | (UInt64(data[index + 5]) << 16)
             | (UInt64(data[index + 6]) << 8)
             | UInt64(data[index + 7])
    }
}
