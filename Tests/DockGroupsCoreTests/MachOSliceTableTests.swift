import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Bounded Mach-O slice metadata")
struct MachOSliceTableTests {
    private struct Record {
        var cpu: UInt32 = 0x0100000c
        var subtype: UInt32 = 0
        var offset: UInt64 = 256
        var size: UInt64 = 128
        var align: UInt32 = 8
        var reserved: UInt32 = 0
    }
    private func be32(_ n: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
    private func be64(_ n: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
    private func fat32(_ records: [Record], count: UInt32? = nil) -> Data {
        var bytes = be32(0xcafebabe) + be32(count ?? UInt32(records.count))
        for r in records {
            bytes += be32(r.cpu) + be32(r.subtype) + be32(UInt32(truncatingIfNeeded: r.offset)) + be32(UInt32(truncatingIfNeeded: r.size)) + be32(r.align)
        }
        return Data(bytes)
    }
    private func fat64(_ records: [Record], count: UInt32? = nil) -> Data {
        var bytes = be32(0xcafebabf) + be32(count ?? UInt32(records.count))
        for r in records {
            bytes += be32(r.cpu) + be32(r.subtype) + be64(r.offset) + be64(r.size) + be32(r.align) + be32(r.reserved)
        }
        return Data(bytes)
    }

    @Test func acceptsBoundedDisjointFatAndThinFiles() throws {
        let a = Record()
        let b = Record(cpu: 0x01000007, subtype: 3, offset: 1024, size: 256, align: 8)
        let slices = try #require(MachOSliceTable.parse(prefix: fat32([a, b]), fileSize: 1280))
        #expect(slices.map(\.offset) == [256, 1024])
        #expect(slices.map(\.size) == [128, 256])
        let reversed = try #require(MachOSliceTable.parse(prefix: fat32([b, a]), fileSize: 1280))
        #expect(reversed.map(\.offset) == [1024, 256])
        // Data slices can retain a nonzero startIndex; parsing must not assume zero-based Data indices.
        let shifted = Data([0] + Array(fat32([a, b]))).dropFirst()
        let shiftedSlices = try #require(MachOSliceTable.parse(prefix: shifted, fileSize: 1280))
        #expect(shiftedSlices == slices)
        let wide = Record(offset: 1024, size: 512, align: 8)
        let fat64Slices = try #require(MachOSliceTable.parse(prefix: fat64([wide]), fileSize: 1536))
        #expect(fat64Slices.map(\.offset) == [1024])
        #expect(fat64Slices.map(\.size) == [512])
        let thin = Data([0xcf, 0xfa, 0xed, 0xfe] + Array(repeating: 0, count: 28))
        let thinSlices = try #require(MachOSliceTable.parse(prefix: thin, fileSize: 32))
        #expect(thinSlices.map(\.offset) == [0])
        #expect(thinSlices.map(\.size) == [32])
    }

    @Test func acceptsMaximumFat64TableAndAllRecognizedThinHeaders() throws {
        var records: [Record] = []
        for i in 0..<16 {
            let index = UInt64(i)
            let offset: UInt64 = 1024 + index * 256
            records.append(Record(cpu: UInt32(i + 1), subtype: 0, offset: offset, size: 128, align: 8))
        }
        let prefix = fat64(records)
        #expect(prefix.count == 520)
        #expect(MachOSliceTable.parse(prefix: prefix, fileSize: 4992)?.count == 16)
        let thinHeaders: [([UInt8], Int)] = [
            ([0xce, 0xfa, 0xed, 0xfe], 28),
            ([0xfe, 0xed, 0xfa, 0xce], 28),
            ([0xcf, 0xfa, 0xed, 0xfe], 32),
            ([0xfe, 0xed, 0xfa, 0xcf], 32),
        ]
        for (magic, length) in thinHeaders {
            let header = Data(magic + Array(repeating: 0, count: length - magic.count))
            let slices = try #require(MachOSliceTable.parse(prefix: header, fileSize: UInt64(length)))
            #expect(slices.count == 1)
            #expect(slices.first?.offset == 0)
        }
    }

    @Test func parsesSystemExecutableUsingOnlyBoundedPrefix() throws {
        let url = URL(fileURLWithPath: "/bin/sleep")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require((attributes[.size] as? NSNumber)?.uint64Value)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 520)
        let prefix = try #require(bytes)
        let slices = try #require(MachOSliceTable.parse(prefix: prefix, fileSize: size))
        #expect((1...16).contains(slices.count))
        for slice in slices {
            #expect(slice.offset < size)
            #expect(slice.size <= size - slice.offset)
        }
    }

    @Test func mutatedHeadersNeverProduceOutOfBoundsOrOverlappingSlices() {
        let first = Record()
        let second = Record(cpu: 0x01000007, subtype: 3, offset: 1024, size: 256, align: 8)
        let original = Array(fat32([first, second]))
        let fileSize: UInt64 = 2048
        var state: UInt64 = 0x6b6f646578
        for _ in 0..<1000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var bytes = original
            let index = Int(state % UInt64(bytes.count))
            bytes[index] ^= UInt8(truncatingIfNeeded: state >> 32) | 1
            guard let slices = MachOSliceTable.parse(prefix: Data(bytes), fileSize: fileSize) else { continue }
            #expect((1...16).contains(slices.count))
            for (index, slice) in slices.enumerated() {
                guard slice.offset <= fileSize else { Issue.record("slice offset exceeds file"); continue }
                #expect(slice.size > 0)
                guard slice.size <= fileSize - slice.offset else { Issue.record("slice exceeds file"); continue }
                for other in slices.dropFirst(index + 1) {
                    guard other.offset <= fileSize, other.size <= fileSize - other.offset else { Issue.record("other slice exceeds file"); continue }
                    #expect(slice.offset + slice.size <= other.offset || other.offset + other.size <= slice.offset)
                }
            }
        }
    }

    @Test func rejectsMalformedOrUnboundedHeaders() {
        let good = Record()
        #expect(MachOSliceTable.parse(prefix: Data(), fileSize: 0) == nil)
        #expect(MachOSliceTable.parse(prefix: Data(repeating: 0, count: 521), fileSize: 521) == nil)
        #expect(MachOSliceTable.parse(prefix: Data([0xcf, 0xfa, 0xed, 0xfe]), fileSize: 4) == nil)
        #expect(MachOSliceTable.parse(prefix: fat32([], count: 0), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat32([], count: 17), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat32([good], count: 2), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat32([good]), fileSize: 20) == nil)
        #expect(MachOSliceTable.parse(prefix: fat32([Record(offset: 0, size: 128, align: 0)]), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat32([Record(offset: 256, size: 0)]), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat32([Record(offset: 256, size: 900)]), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat32([Record(offset: 257, size: 128)]), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat32([Record(offset: 256, size: 128, align: 32)]), fileSize: 1024) == nil)
        let overlapping = Record(cpu: 0x01000007, offset: 256, size: 128, align: 8)
        #expect(MachOSliceTable.parse(prefix: fat32([good, overlapping]), fileSize: 1024) == nil)
        let duplicateArch = Record(offset: 512, size: 128, align: 8)
        #expect(MachOSliceTable.parse(prefix: fat32([good, duplicateArch]), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat64([], count: 0), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat64([], count: 17), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat64([good], count: 2), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat64([Record(offset: 256, size: 128, align: 64)]), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: fat64([Record(offset: UInt64.max - 7, size: 16, align: 0)]), fileSize: UInt64.max) == nil)
        #expect(MachOSliceTable.parse(prefix: fat64([Record(offset: 256, size: 128, align: 8, reserved: 1)]), fileSize: 1024) == nil)
        #expect(MachOSliceTable.parse(prefix: Data([0xbe, 0xba, 0xfe, 0xca, 0, 0, 0, 1]), fileSize: 1024) == nil)
    }
}
