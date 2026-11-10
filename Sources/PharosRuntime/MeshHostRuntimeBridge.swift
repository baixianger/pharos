import Foundation
import PharosAgentCore
import PharosMeshCore

/// The mesh host asks only its own same-user runtime for this fixed operation.
public enum MeshHostRuntimeBridge {
    public static func hello(hostDeviceID: MeshDeviceID) async throws -> MeshHostRuntimeHello {
        try await Task.detached {
            let request = #"{"jsonrpc":"2.0","id":"mesh-runtime-hello","method":"runtime.hello","params":{}}"#
            let response = try AgentRuntimeClient.send(request)
            guard let data = response.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let service = result["service"] as? String,
                  service == AgentRuntimeProtocol.service,
                  let protocolVersion = result["protocolVersion"] as? Int,
                  let capabilities = result["capabilities"] as? [String] else {
                throw AgentRuntimeClient.ClientError.invalidResponse
            }
            let hello = MeshHostRuntimeHello(hostDeviceID: hostDeviceID, service: service,
                                             protocolVersion: protocolVersion,
                                             capabilities: capabilities)
            try hello.validate()
            return hello
        }.value
    }

    /// Forward one allowlisted Runtime JSON-RPC call onto this Host's Runtime.
    public static func call(
        _ request: MeshHostRuntimeCallRequest
    ) async throws -> MeshHostRuntimeCallResponse {
        try request.validate()
        let response = try await Task.detached {
            try AgentRuntimeClient.send(request.jsonrpcRequest)
        }.value
        let value = MeshHostRuntimeCallResponse(
            hostDeviceID: request.hostDeviceID, jsonrpcResponse: response
        )
        try value.validate()
        return value
    }
}
