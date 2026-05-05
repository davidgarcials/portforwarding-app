import XCTest
@testable import PortForwardingLib

final class PortForwardTests: XCTestCase {

    private func makeForward(
        remoteHost: String? = nil,
        remotePort: Int = 5432,
        localPort: Int = 5432,
        target: String = "i-0abc123",
        awsProfile: String = "prod",
        region: String = "eu-west-1"
    ) -> PortForward {
        PortForward(
            id: UUID(),
            name: "test",
            awsProfile: awsProfile,
            region: region,
            target: target,
            remoteHost: remoteHost,
            remotePort: remotePort,
            localPort: localPort,
            enabled: true,
            sortOrder: 0
        )
    }

    func testDirectModeWhenRemoteHostIsNil() {
        let fwd = makeForward()
        XCTAssertFalse(fwd.isRemoteHostMode)
        XCTAssertEqual(fwd.documentName, "AWS-StartPortForwardingSession")
    }

    func testDirectModeWhenRemoteHostIsEmpty() {
        let fwd = makeForward(remoteHost: "")
        XCTAssertFalse(fwd.isRemoteHostMode)
    }

    func testRemoteHostMode() {
        let fwd = makeForward(remoteHost: "mydb.cluster-xxx.eu-west-1.rds.amazonaws.com")
        XCTAssertTrue(fwd.isRemoteHostMode)
        XCTAssertEqual(fwd.documentName, "AWS-StartPortForwardingSessionToRemoteHost")
    }

    func testSSMParametersDirectMode() {
        let fwd = makeForward(remotePort: 3306, localPort: 3307)
        let params = fwd.ssmParameters
        XCTAssertEqual(params["portNumber"], ["3306"])
        XCTAssertEqual(params["localPortNumber"], ["3307"])
        XCTAssertNil(params["host"])
    }

    func testSSMParametersRemoteHostMode() {
        let fwd = makeForward(remoteHost: "mydb.rds.amazonaws.com", remotePort: 5432, localPort: 5433)
        let params = fwd.ssmParameters
        XCTAssertEqual(params["portNumber"], ["5432"])
        XCTAssertEqual(params["localPortNumber"], ["5433"])
        XCTAssertEqual(params["host"], ["mydb.rds.amazonaws.com"])
    }

    func testLaunchArgumentsDirectMode() {
        let fwd = makeForward(remotePort: 5432, localPort: 5433, target: "i-0abc", awsProfile: "prod", region: "eu-west-1")
        let args = fwd.launchArguments
        XCTAssertEqual(args[0], "exec")
        XCTAssertEqual(args[1], "prod")
        XCTAssertEqual(args[2], "--")
        XCTAssert(args.contains("--target"))
        XCTAssert(args.contains("i-0abc"))
        XCTAssert(args.contains("AWS-StartPortForwardingSession"))
        XCTAssert(args.contains("--region"))
        XCTAssert(args.contains("eu-west-1"))
    }

    func testLaunchArgumentsRemoteHostMode() {
        let fwd = makeForward(remoteHost: "mydb.rds.amazonaws.com")
        let args = fwd.launchArguments
        XCTAssert(args.contains("AWS-StartPortForwardingSessionToRemoteHost"))
    }

    func testJSONRoundTrip() throws {
        let original = makeForward(remoteHost: "mydb.rds.amazonaws.com")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PortForward.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
