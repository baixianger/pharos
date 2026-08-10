import Foundation
import PharosRuntime
import XCTest

final class RuntimeConfigurationTests: XCTestCase {
    func testNodeRequiresRemoteBrokerEndpoint() {
        XCTAssertThrowsError(
            try PharosRuntimeConfiguration(role: .node).validated()
        ) { error in
            XCTAssertEqual(error as? PharosRuntimeError, .invalidRemoteBrokerEndpoint)
        }
    }

    func testBrokerDoesNotRequireRemoteEndpoint() throws {
        let configuration = PharosRuntimeConfiguration(role: .broker)
        XCTAssertEqual(try configuration.validated(), configuration)
    }

    func testLegacyHostBrokerMigratesToBrokerRole() {
        withDefaults { defaults in
            defaults.set(true, forKey: "pharos.hostBroker")
            let store = PharosRuntimeConfigurationStore(defaults: defaults)

            XCTAssertTrue(store.isConfigured)
            XCTAssertEqual(store.load().role, .broker)
        }
    }

    func testSavedRoleIsAuthoritativeOverLegacyFlag() {
        withDefaults { defaults in
            defaults.set(false, forKey: "pharos.hostBroker")
            defaults.set(PharosRuntimeRole.broker.rawValue,
                         forKey: PharosRuntimeConfigurationStore.roleKey)

            XCTAssertEqual(PharosRuntimeConfigurationStore(defaults: defaults).load().role,
                           .broker)
        }
    }

    func testBrokerPreservesRemoteEndpointForSafeSwitchBack() {
        withDefaults { defaults in
            let store = PharosRuntimeConfigurationStore(defaults: defaults)
            store.save(.init(role: .broker, remoteBrokerEndpoint: "100.64.0.8:47800"))

            XCTAssertEqual(store.load(), .init(role: .broker,
                                               remoteBrokerEndpoint: "100.64.0.8:47800"))
            XCTAssertTrue(defaults.bool(forKey: "pharos.launchMeshAtLogin"))
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "me.pai.pharos.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
