import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshProtocol

final class DistributedMeshLaunchAgentTests: XCTestCase {
    func testPlanUsesStablePersonalLaunchAgentPaths() throws {
        let plan = try fixturePlan()

        XCTAssertEqual(
            plan.plistURL.path,
            "/Users/pai/Library/LaunchAgents/" +
                "me.pai.pharos.mesh-service.plist"
        )
        XCTAssertEqual(
            plan.installedHelper.path,
            "/Users/pai/Library/Application Support/Pharos/" +
                "Runtime/pharos-mesh"
        )
        XCTAssertFalse(plan.installedHelper.path.contains(".build"))
        XCTAssertEqual(
            plan.launchArguments,
            [
                plan.installedHelper.path,
                "distributed", "sync-serve", "--host",
                "--relay", "production", "--service-mode",
                "--build-id", "commit@time",
            ]
        )
    }

    func testPlistRunsAtLoadAndRestartsOnlyAfterFailure() throws {
        let plan = try fixturePlan()
        let value = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: plan.plistData(), format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            value["Label"] as? String,
            "me.pai.pharos.mesh-service"
        )
        XCTAssertEqual(value["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(
            (value["KeepAlive"] as? [String: Bool])?["SuccessfulExit"],
            false
        )
        XCTAssertEqual(
            value["ProgramArguments"] as? [String], plan.launchArguments
        )
        XCTAssertEqual(value["ProcessType"] as? String, "Background")
        XCTAssertEqual(value["Umask"] as? Int, 0o077)
    }

#if os(macOS)
    func testLaunchdRestartCountParsesRunsWithoutCountingInitialLaunch() {
        XCTAssertEqual(
            DistributedMeshLaunchAgent.launchdRestartCount(
                from: "state = running\nruns = 7\npid = 42\n"
            ),
            6
        )
        XCTAssertEqual(
            DistributedMeshLaunchAgent.launchdRestartCount(
                from: "runs = 1\n"
            ),
            0
        )
        XCTAssertNil(
            DistributedMeshLaunchAgent.launchdRestartCount(
                from: "state = waiting\n"
            )
        )
    }
#endif

    func testUninstallContractKeepsReplicaOutsideRuntimeDirectory() throws {
        let plan = try fixturePlan()
        let replica = plan.dataDirectory.appendingPathComponent(
            "replica-v1.sqlite"
        )

        XCTAssertFalse(replica.path.hasPrefix(plan.runtimeDirectory.path + "/"))
        XCTAssertFalse(
            plan.launchArguments.contains(where: {
                $0.contains("serve") && !$0.contains("sync-serve")
            })
        )
    }

    func testUpgradeValidationPreservesExactMeshIdentity() throws {
        let expected = fixtureIdentity()
        let status = fixtureStatus(identity: expected)

        XCTAssertNoThrow(
            try DistributedMeshLaunchAgent.validateReplacementIdentity(
                expected: expected, status: status
            )
        )
    }

    func testUpgradeValidationRejectsChangedEpoch() throws {
        let expected = fixtureIdentity()
        let changed = DistributedMeshServiceIdentity(
            deviceID: expected.deviceID,
            endpointID: expected.endpointID,
            trustGroupID: expected.trustGroupID,
            membershipEpoch: expected.membershipEpoch + 1
        )

        XCTAssertThrowsError(
            try DistributedMeshLaunchAgent.validateReplacementIdentity(
                expected: expected,
                status: fixtureStatus(identity: changed)
            )
        ) { error in
            XCTAssertEqual(
                error as? DistributedMeshLaunchAgentError,
                .replacementIdentityChanged
            )
        }
    }

    func testHelperDeploymentRetainsPreviousAndRollsBackAtomically()
        throws {
        let fixture = try TemporaryPlan()
        defer { fixture.remove() }
        try fixture.writeHelper("new-build", to: fixture.source)
        try fixture.writeHelper("old-build", to: fixture.plan.installedHelper)

        try DistributedMeshHelperDeployment.deploy(fixture.plan)

        XCTAssertEqual(
            try String(
                contentsOf: fixture.plan.installedHelper, encoding: .utf8
            ),
            "new-build"
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.plan.previousHelper, encoding: .utf8
            ),
            "old-build"
        )
        XCTAssertTrue(
            try DistributedMeshHelperDeployment.restorePrevious(
                fixture.plan
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.plan.installedHelper, encoding: .utf8
            ),
            "old-build"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.plan.previousHelper.path
        ))
    }

    func testHelperDeploymentFailsClosedWhenSourceIsMissing() throws {
        let fixture = try TemporaryPlan()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try DistributedMeshHelperDeployment.deploy(fixture.plan)
        ) { error in
            XCTAssertEqual(
                error as? DistributedMeshLaunchAgentError,
                .helperNotFound
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.plan.installedHelper.path
        ))
    }

    func testRuntimeArtifactRemovalPreservesReplicaAndIdentity()
        throws {
        let fixture = try TemporaryPlan()
        defer { fixture.remove() }
        let replica = fixture.plan.dataDirectory.appendingPathComponent(
            "replica-v1.sqlite"
        )
        let identity = fixture.plan.dataDirectory.appendingPathComponent(
            "headless-device-identity-v1.json"
        )
        let socket = try DistributedMeshLocalServicePaths.socketURL(
            dataDirectory: fixture.plan.dataDirectory
        )
        try fixture.writeHelper("fixture", to: replica)
        try fixture.writeHelper("fixture", to: identity)
        try fixture.writeHelper("fixture", to: socket)
        try fixture.writeHelper("fixture", to: fixture.plan.plistURL)
        try fixture.writeHelper(
            "fixture", to: fixture.plan.installedHelper
        )
        try fixture.writeHelper(
            "fixture", to: fixture.plan.previousHelper
        )

        try DistributedMeshHelperDeployment.removeRuntimeArtifacts(
            fixture.plan
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: replica.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: identity.path
        ))
        for removed in [
            socket, fixture.plan.plistURL, fixture.plan.installedHelper,
            fixture.plan.previousHelper,
        ] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: removed.path
            ))
        }
    }

    func testPlistWriterRepairsCorruptFileWithPrivateValidPlist()
        throws {
        let fixture = try TemporaryPlan()
        defer { fixture.remove() }
        try fixture.writeHelper(
            "not-a-plist", to: fixture.plan.plistURL
        )

        try DistributedMeshHelperDeployment.writePlist(fixture.plan)

        let data = try Data(contentsOf: fixture.plan.plistURL)
        let value = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: data, format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            value["Label"] as? String,
            DistributedMeshLaunchAgentPlan.label
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.plan.plistURL.path
        )
        XCTAssertEqual(
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1)
                & 0o777,
            0o600
        )
    }

    private func fixturePlan() throws -> DistributedMeshLaunchAgentPlan {
        try DistributedMeshLaunchAgentPlan(
            homeDirectory: URL(fileURLWithPath: "/Users/pai"),
            dataDirectory: URL(
                fileURLWithPath:
                    "/Users/pai/Library/Application Support/Pharos/" +
                    "distributed-mesh/v1",
                isDirectory: true
            ),
            sourceHelper: URL(
                fileURLWithPath:
                    "/Applications/Pharos.app/Contents/Helpers/pharos-mesh"
            ),
            buildID: "commit@time"
        )
    }

    private func fixtureIdentity() -> DistributedMeshServiceIdentity {
        DistributedMeshServiceIdentity(
            deviceID: MeshDeviceID(
                rawValue: UUID(
                    uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
                )!
            ),
            endpointID: MeshEndpointID(rawValue: "endpoint-test")!,
            trustGroupID: MeshTrustGroupID(
                rawValue: UUID(
                    uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
                )!
            ),
            membershipEpoch: 11
        )
    }

    private func fixtureStatus(
        identity: DistributedMeshServiceIdentity
    ) -> DistributedMeshLocalServiceStatus {
        DistributedMeshLocalServiceStatus(
            buildID: "replacement",
            deviceID: identity.deviceID,
            endpointID: identity.endpointID,
            trustGroupID: identity.trustGroupID,
            membershipEpoch: identity.membershipEpoch,
            networkState: .online
        )
    }
}

private final class TemporaryPlan {
    let root: URL
    let source: URL
    let plan: DistributedMeshLaunchAgentPlan

    init() throws {
        root = URL(
            fileURLWithPath:
                "/tmp/ph-la-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let data = home.appendingPathComponent(
            "Library/Application Support/Pharos/DistributedMesh/v1",
            isDirectory: true
        )
        source = root.appendingPathComponent("source-pharos-mesh")
        plan = try DistributedMeshLaunchAgentPlan(
            homeDirectory: home,
            dataDirectory: data,
            sourceHelper: source,
            buildID: "test-build"
        )
    }

    func writeHelper(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    func remove() {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        try? FileManager.default.removeItem(at: root)
    }
}
