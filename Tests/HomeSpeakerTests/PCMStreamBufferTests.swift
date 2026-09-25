import XCTest
@testable import HomeSpeaker

final class PCMStreamBufferTests: XCTestCase {
    func testArbitraryCaptureAndNetworkChunksPreserveEveryByte() {
        let buffer = PCMStreamBuffer(capacity: 8192)
        buffer.activate()
        let source = Data((0..<4000).map { UInt8($0 % 251) })
        XCTAssertTrue(buffer.append(source.prefix(37)))
        XCTAssertTrue(buffer.append(source.dropFirst(37).prefix(1101)))
        var result = buffer.take(maxBytes: 127)
        XCTAssertEqual(result.count % 4, 0)
        XCTAssertTrue(buffer.append(source.dropFirst(1138)))
        while true {
            let packet = buffer.take(maxBytes: 303)
            if packet.isEmpty { break }
            result.append(packet)
        }
        XCTAssertEqual(result, source)
    }

    func testOverloadIsReportedAndDoesNotDiscardQueuedSamples() {
        let buffer = PCMStreamBuffer(capacity: 8)
        buffer.activate()
        let first = Data([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertTrue(buffer.append(first))
        XCTAssertFalse(buffer.append(Data([9, 10, 11, 12])))
        XCTAssertEqual(buffer.take(maxBytes: 8), first)
        buffer.deactivate()
        buffer.activate()
        XCTAssertTrue(buffer.take(maxBytes: 8).isEmpty)
    }
}
