import XCTest
@testable import PortForwardingLib

final class ConfigStoreTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeForward(name: String = "test", localPort: Int = 5432) -> PortForward {
        PortForward(
            id: UUID(),
            name: name,
            awsProfile: "prod",
            region: "eu-west-1",
            target: "i-0abc123",
            remoteHost: nil,
            remotePort: 5432,
            localPort: localPort,
            enabled: true,
            sortOrder: 0
        )
    }

    func testSaveAndLoadRoundTrip() throws {
        let dir = try makeTempDir()
        let store = ConfigStore(directory: dir)
        let config = AppConfig(forwards: [makeForward()])

        try store.save(config)
        let loaded = try store.load()

        XCTAssertEqual(loaded.version, 1)
        XCTAssertEqual(loaded.forwards.count, 1)
        XCTAssertEqual(loaded.forwards[0].name, "test")
    }

    func testLoadOrDefaultReturnsEmptyWhenNoFile() throws {
        let dir = try makeTempDir()
        let store = ConfigStore(directory: dir)
        let config = store.loadOrDefault()

        XCTAssertTrue(config.forwards.isEmpty)
        XCTAssertEqual(config.version, 1)
    }

    func testSaveCreatesIntermediateDirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreTests-\(UUID().uuidString)")
            .appendingPathComponent("nested")
        let store = ConfigStore(directory: dir)
        let config = AppConfig(forwards: [makeForward()])

        try store.save(config)
        let loaded = try store.load()
        XCTAssertEqual(loaded.forwards.count, 1)
    }

    func testOverwritePreservesIntegrity() throws {
        let dir = try makeTempDir()
        let store = ConfigStore(directory: dir)

        try store.save(AppConfig(forwards: [makeForward(name: "first")]))
        try store.save(AppConfig(forwards: [makeForward(name: "second"), makeForward(name: "third")]))

        let loaded = try store.load()
        XCTAssertEqual(loaded.forwards.count, 2)
        XCTAssertEqual(loaded.forwards[0].name, "second")
    }
}
