import Foundation
import XCTest
@testable import PharosClientKit

// MARK: - URLProtocol stub harness (no real network)

/// A request captured by `StubURLProtocol`, including the body.
///
/// URLSession hands `URLProtocol` the body as `httpBodyStream` (not `httpBody`),
/// so the stub drains the stream to make request-body assertions possible.
struct RecordedRequest {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    init(request: URLRequest) {
        self.method = request.httpMethod ?? "GET"
        self.url = request.url!
        self.headers = request.allHTTPHeaderFields ?? [:]
        self.body = Self.bodyData(from: request)
    }

    var path: String { url.path }

    func jsonBody() -> [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

/// URLProtocol that answers from a test-provided handler and records requests.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (RecordedRequest) throws -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var records: [RecordedRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        records = []
        lock.unlock()
    }

    static func recordedRequests() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(request: request)
        Self.lock.lock()
        let handler = Self.handler
        Self.records.append(recorded)
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (status, body) = try handler(recorded)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class HttpPharosClientServiceWiringTests: XCTestCase {
    private let baseURL = URL(string: "http://stub.test")!

    // MARK: Harness

    private func makeClient(
        _ handler: @escaping StubURLProtocol.Handler
    ) -> HttpPharosClientService {
        StubURLProtocol.install(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return HttpPharosClientService(
            configuration: PharosAPIConfiguration(baseURL: baseURL, backendKind: .rustAPI),
            session: session
        )
    }

    private func requests() -> [RecordedRequest] { StubURLProtocol.recordedRequests() }

    private func json(_ body: String, status: Int = 200) -> (status: Int, body: Data) {
        (status, Data(body.utf8))
    }

    private func raw(_ body: String) -> Data { Data(body.utf8) }

    private func assertOperationFailed(
        _ error: Error?,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let clientError = error as? PharosClientError else {
            return XCTFail(
                "Expected PharosClientError, got \(String(describing: error))",
                file: file,
                line: line
            )
        }
        guard case .operationFailed(let message) = clientError else {
            return XCTFail("Expected operationFailed, got \(clientError)", file: file, line: line)
        }
        XCTAssertTrue(
            message.contains(expected),
            "“\(message)” does not contain “\(expected)”",
            file: file,
            line: line
        )
    }

    // MARK: - Session configuration

    func testFetchSessionConfigurationMapsSupportedView() async throws {
        let client = makeClient { _ in
            self.json(#"{"sessionId":"s1","supported":true,"supportedFields":["model","mode"],"model":"gpt-5","mode":"safe","models":["gpt-5"],"modes":[{"name":"Safe","value":"safe"},{"name":"YOLO","value":"yolo"}],"capabilities":{"attachments":true,"commands":false,"stop":false,"revive":true},"readonly":false}"#)
        }
        let configuration = try await client.fetchSessionConfiguration(sessionId: "s1")
        let mapped = try XCTUnwrap(configuration)
        XCTAssertEqual(requests().count, 1)
        XCTAssertEqual(requests()[0].path, "/api/v1/sessions/s1/config")
        XCTAssertEqual(requests()[0].method, "GET")
        XCTAssertEqual(mapped.sessionId, "s1")
        XCTAssertTrue(mapped.supported)
        XCTAssertEqual(mapped.supportedFields, ["model", "mode"])
        XCTAssertEqual(mapped.model, "gpt-5")
        XCTAssertEqual(mapped.mode, "safe")
        XCTAssertEqual(mapped.models, ["gpt-5"])
        XCTAssertEqual(mapped.modes, [
            ClientSessionConfiguration.Mode(value: "safe", name: "Safe"),
            ClientSessionConfiguration.Mode(value: "yolo", name: "YOLO"),
        ])
        XCTAssertEqual(mapped.capabilities, ClientSessionConfiguration.Capabilities(
            attachments: true, commands: false, stop: false, revive: true
        ))
        XCTAssertFalse(mapped.readonly)
    }

    func testFetchSessionConfigurationHonestEmptyView() async throws {
        let client = makeClient { _ in
            self.json(#"{"sessionId":"s2","supported":false,"supportedFields":[],"model":null,"mode":null,"models":[],"modes":[],"capabilities":{"attachments":false,"commands":false,"stop":false,"revive":false},"readonly":true}"#)
        }
        let configuration = try await client.fetchSessionConfiguration(sessionId: "s2")
        let mapped = try XCTUnwrap(configuration)
        XCTAssertFalse(mapped.supported)
        XCTAssertEqual(mapped.supportedFields, [])
        XCTAssertNil(mapped.model)
        XCTAssertNil(mapped.mode)
        XCTAssertEqual(mapped.models, [])
        XCTAssertEqual(mapped.modes, [])
        XCTAssertFalse(mapped.capabilities.attachments)
        XCTAssertTrue(mapped.readonly)
        XCTAssertEqual(requests()[0].path, "/api/v1/sessions/s2/config")
    }

    func testSetSessionConfigurationPatchesAndMapsResponse() async throws {
        let client = makeClient { _ in
            self.json(#"{"sessionId":"s1","supported":true,"supportedFields":["model","mode"],"model":"gpt-5","mode":"yolo","models":["gpt-5"],"modes":[{"name":"YOLO","value":"yolo"}],"capabilities":{"attachments":false,"commands":false,"stop":false,"revive":false},"readonly":false}"#)
        }
        let mapped = try await client.setSessionConfiguration(sessionId: "s 1", configId: "mode", value: "yolo")
        XCTAssertEqual(mapped.mode, "yolo")
        let request = try XCTUnwrap(requests().last)
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.path, "/api/v1/sessions/s 1/config")
        XCTAssertTrue(request.url.absoluteString.contains("s%201"), request.url.absoluteString)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.jsonBody()?["mode"] as? String, "yolo")
        XCTAssertNil(request.jsonBody()?["model"])
    }

    func testSetSessionConfigurationRejectsUnknownFieldAndEmptyValueBeforeRequest() async {
        let client = makeClient { _ in self.json("{}") }
        do {
            _ = try await client.setSessionConfiguration(sessionId: "s1", configId: "temperature", value: "1")
            XCTFail("expected unsupported field error")
        } catch {
            assertOperationFailed(error, contains: "Unsupported Session configuration field: temperature")
        }
        do {
            _ = try await client.setSessionConfiguration(sessionId: "s1", configId: "model", value: "  ")
            XCTFail("expected blank value error")
        } catch {
            assertOperationFailed(error, contains: "Choose a model value first")
        }
        XCTAssertEqual(requests().count, 0)
    }

    func testSetSessionConfigurationPropagatesUnsupportedFieldMessage() async {
        let client = makeClient { _ in
            self.json(
                #"{"error":{"code":"unsupportedField","message":"the configured adapter does not support changing model","field":"model"},"contractsVersion":"0.1.0"}"#,
                status: 502
            )
        }
        do {
            _ = try await client.setSessionConfiguration(sessionId: "s1", configId: "model", value: "gpt-5")
            XCTFail("502 unsupportedField must not be reported as saved")
        } catch {
            assertOperationFailed(error, contains: "does not support changing model")
        }
        XCTAssertEqual(requests().count, 1)
        XCTAssertEqual(requests()[0].method, "PATCH")
    }

    // MARK: - Stop / revive

    func testStopAndReviveSessionPostLifecyclePaths() async throws {
        let client = makeClient { request in
            if request.path.hasSuffix("/stop") {
                return self.json(#"{"ok":true,"sessionId":"s1","status":"stopped"}"#)
            }
            return self.json(#"{"ok":true,"sessionId":"s1","status":"idle"}"#)
        }
        try await client.stopSession(sessionId: "s1")
        try await client.reviveSession(sessionId: "s1")
        let recorded = requests()
        XCTAssertEqual(recorded.map(\.method), ["POST", "POST"])
        XCTAssertEqual(recorded.map(\.path), [
            "/api/v1/sessions/s1/stop",
            "/api/v1/sessions/s1/revive",
        ])
        XCTAssertNil(recorded[0].body)
        XCTAssertNil(recorded[1].body)
    }

    func testStopSessionDoesNotTreat502AsSuccess() async {
        let client = makeClient { _ in
            self.json(
                #"{"error":{"code":"unsupportedOperation","message":"the configured session adapter does not support stopping sessions","field":"stop"},"contractsVersion":"0.1.0"}"#,
                status: 502
            )
        }
        do {
            try await client.stopSession(sessionId: "s1")
            XCTFail("502 must throw, never a fake success")
        } catch {
            assertOperationFailed(error, contains: "does not support stopping sessions")
        }
    }

    func testStopMemberResolvesExactSessionId() async throws {
        let client = makeClient { request in
            if request.path == "/api/v1/sessions" {
                return self.json(#"[{"sessionId":"s1","machineId":"m","agentType":"fake","workspacePath":"/p","title":"Fake Session","status":"idle","updatedAt":"2026-11-11T00:00:00Z","avatarSeed":"a"}]"#)
            }
            return self.json(#"{"ok":true,"sessionId":"s1","status":"stopped"}"#)
        }
        try await client.stopMember(name: "s1")
        XCTAssertEqual(requests().map(\.path), ["/api/v1/sessions", "/api/v1/sessions/s1/stop"])
    }

    func testStopMemberResolvesUniqueTitle() async throws {
        let client = makeClient { request in
            if request.path == "/api/v1/sessions" {
                return self.json(#"[{"sessionId":"s1","machineId":"m","agentType":"fake","workspacePath":"/p","title":"Fake Session","status":"idle","updatedAt":"2026-11-11T00:00:00Z","avatarSeed":"a"}]"#)
            }
            return self.json(#"{"ok":true,"sessionId":"s1","status":"stopped"}"#)
        }
        try await client.stopMember(name: "Fake Session")
        XCTAssertEqual(requests().last?.path, "/api/v1/sessions/s1/stop")
    }

    func testReviveMemberResolvesUniqueTitle() async throws {
        let client = makeClient { request in
            if request.path == "/api/v1/sessions" {
                return self.json(#"[{"sessionId":"s1","machineId":"m","agentType":"fake","workspacePath":"/p","title":"Fake Session","status":"stopped","updatedAt":"2026-11-11T00:00:00Z","avatarSeed":"a"}]"#)
            }
            return self.json(#"{"ok":true,"sessionId":"s1","status":"idle"}"#)
        }
        try await client.reviveMember(name: "Fake Session")
        XCTAssertEqual(requests().last?.path, "/api/v1/sessions/s1/revive")
    }

    func testStopMemberUnknownNameThrows() async {
        let client = makeClient { _ in self.json("[]") }
        do {
            try await client.stopMember(name: "Ghost")
            XCTFail("unknown member must throw")
        } catch {
            assertOperationFailed(error, contains: "No Session named Ghost on this backend")
        }
        XCTAssertEqual(requests().count, 1)
    }

    func testStopMemberAmbiguousTitleThrows() async {
        let client = makeClient { _ in
            self.json(#"[{"sessionId":"s1","machineId":"m","agentType":"fake","workspacePath":"/p","title":"Same","status":"idle","updatedAt":"2026-11-11T00:00:00Z","avatarSeed":"a"},{"sessionId":"s2","machineId":"m","agentType":"fake","workspacePath":"/p","title":"Same","status":"idle","updatedAt":"2026-11-11T00:00:00Z","avatarSeed":"b"}]"#)
        }
        do {
            try await client.stopMember(name: "Same")
            XCTFail("ambiguous title must throw")
        } catch {
            assertOperationFailed(error, contains: "Multiple Sessions are named Same")
        }
        XCTAssertEqual(requests().count, 1, "must not guess a session to stop")
    }

    // MARK: - Attachments

    private let configAttachmentsOn = #"{"sessionId":"s1","supported":true,"supportedFields":["model","mode"],"model":"fake","mode":"safe","models":["fake"],"modes":[],"capabilities":{"attachments":true,"commands":false,"stop":false,"revive":false},"readonly":false}"#
    private let configAttachmentsOff = #"{"sessionId":"s1","supported":true,"supportedFields":["model","mode"],"model":"fake","mode":"safe","models":["fake"],"modes":[],"capabilities":{"attachments":false,"commands":false,"stop":false,"revive":false},"readonly":false}"#

    private func turnJSON(turnId: String = "t1") -> String {
        #"{"turnId":"\#(turnId)","sessionId":"s1","turnNumber":1,"status":"completed","createdAt":"2026-11-11T00:00:00Z","completedAt":"2026-11-11T00:00:01Z","assistantText":["ok"]}"#
    }

    private func attachmentJSON(attachmentId: String, filename: String, contentType: String) -> String {
        #"{"attachmentId":"\#(attachmentId)","sessionId":"s1","filename":"\#(filename)","contentType":"\#(contentType)","sizeBytes":5,"sha256":"abc","createdAt":"2026-11-11T22:06:53Z"}"#
    }

    func testAttachmentUploadThenMessagesSequence() async throws {
        let client = makeClient { request in
            switch request.path {
            case "/api/v1/sessions/s1/config":
                return self.json(self.configAttachmentsOn)
            case "/api/v1/sessions/s1/attachments":
                let body = request.jsonBody() ?? [:]
                let filename = body["filename"] as? String ?? "unknown"
                let contentType = body["contentType"] as? String ?? "unknown"
                return self.json(self.attachmentJSON(
                    attachmentId: "att-\(filename)",
                    filename: filename,
                    contentType: contentType
                ))
            case "/api/v1/sessions/s1/messages":
                return self.json(self.turnJSON())
            default:
                throw URLError(.badURL)
            }
        }
        let turn = try await client.sendSessionMessage(
            sessionId: "s1",
            text: "see attached",
            files: [
                SessionFileUpload(name: "notes.txt", data: Data("hello".utf8)),
                SessionFileUpload(name: "photo.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
            ],
            requestId: "req-1"
        )
        XCTAssertEqual(turn.turnId, "t1")
        let recorded = requests()
        XCTAssertEqual(recorded.map(\.method), ["GET", "POST", "POST", "POST"])
        XCTAssertEqual(recorded.map(\.path), [
            "/api/v1/sessions/s1/config",
            "/api/v1/sessions/s1/attachments",
            "/api/v1/sessions/s1/attachments",
            "/api/v1/sessions/s1/messages",
        ])
        let firstUpload = try XCTUnwrap(recorded[1].jsonBody())
        XCTAssertEqual(firstUpload["filename"] as? String, "notes.txt")
        XCTAssertEqual(firstUpload["contentType"] as? String, "text/plain")
        XCTAssertEqual(firstUpload["dataBase64"] as? String, Data("hello".utf8).base64EncodedString())
        let secondUpload = try XCTUnwrap(recorded[2].jsonBody())
        XCTAssertEqual(secondUpload["filename"] as? String, "photo.png")
        XCTAssertEqual(secondUpload["contentType"] as? String, "image/png")
        let message = try XCTUnwrap(recorded[3].jsonBody())
        XCTAssertEqual(message["text"] as? String, "see attached")
        XCTAssertEqual(message["requestId"] as? String, "req-1")
        XCTAssertEqual(message["attachmentIds"] as? [String], ["att-notes.txt", "att-photo.png"])
    }

    func testAttachmentCapabilityFalseThrowsBeforeUpload() async {
        let client = makeClient { _ in self.json(self.configAttachmentsOff) }
        do {
            _ = try await client.sendSessionMessage(
                sessionId: "s1",
                text: "see attached",
                files: [SessionFileUpload(name: "notes.txt", data: Data("hello".utf8))],
                requestId: "req-1"
            )
            XCTFail("attachment capability false must throw")
        } catch {
            assertOperationFailed(error, contains: "the adapter does not advertise attachment support")
        }
        XCTAssertEqual(requests().count, 1, "no upload may happen when the capability is absent")
        XCTAssertEqual(requests()[0].path, "/api/v1/sessions/s1/config")
    }

    func testAttachmentUnknownExtensionThrows() async {
        let client = makeClient { _ in self.json(self.configAttachmentsOn) }
        do {
            _ = try await client.sendSessionMessage(
                sessionId: "s1",
                text: "see attached",
                files: [SessionFileUpload(name: "archive.bin", data: Data([0x00]))],
                requestId: "req-1"
            )
            XCTFail("unknown extension must throw")
        } catch {
            assertOperationFailed(error, contains: "Unsupported attachment type for archive.bin")
        }
        XCTAssertEqual(requests().count, 1, "validation happens before any upload")
    }

    func testAttachmentOversizeThrows() async {
        let oversized = Data(count: HttpPharosClientService.maxAttachmentBytes + 1)
        let client = makeClient { _ in self.json(self.configAttachmentsOn) }
        do {
            _ = try await client.sendSessionMessage(
                sessionId: "s1",
                text: "big",
                files: [SessionFileUpload(name: "big.txt", data: oversized)],
                requestId: "req-1"
            )
            XCTFail("oversize attachment must throw")
        } catch {
            assertOperationFailed(error, contains: "accepts at most")
        }
        XCTAssertEqual(requests().count, 1, "oversize validation happens before any upload")
    }

    func testAttachmentEmptyFileThrows() async {
        let client = makeClient { _ in self.json(self.configAttachmentsOn) }
        do {
            _ = try await client.sendSessionMessage(
                sessionId: "s1",
                text: "empty",
                files: [SessionFileUpload(name: "empty.txt", data: Data())],
                requestId: "req-1"
            )
            XCTFail("empty attachment must throw")
        } catch {
            assertOperationFailed(error, contains: "is empty")
        }
        XCTAssertEqual(requests().count, 1)
    }

    func testAttachmentUploadFailureSkipsMessages() async {
        let client = makeClient { request in
            if request.path == "/api/v1/sessions/s1/config" {
                return self.json(self.configAttachmentsOn)
            }
            return self.json(
                #"{"error":{"code":"unsupportedField","message":"this adapter cannot consume attachments","field":"attachments"},"contractsVersion":"0.1.0"}"#,
                status: 502
            )
        }
        do {
            _ = try await client.sendSessionMessage(
                sessionId: "s1",
                text: "see attached",
                files: [SessionFileUpload(name: "notes.txt", data: Data("hello".utf8))],
                requestId: "req-1"
            )
            XCTFail("upload failure must throw")
        } catch {
            assertOperationFailed(error, contains: "cannot consume attachments")
        }
        XCTAssertEqual(requests().map(\.path), [
            "/api/v1/sessions/s1/config",
            "/api/v1/sessions/s1/attachments",
        ])
        XCTAssertFalse(requests().contains { $0.path.hasSuffix("/messages") }, "no fake message send")
    }

    func testSupportsSessionTextAttachmentsTrueAndFalse() async throws {
        var client = makeClient { _ in self.json(self.configAttachmentsOn) }
        var supported = await client.supportsSessionTextAttachments(sessionId: "s1")
        XCTAssertTrue(supported)

        client = makeClient { _ in self.json(self.configAttachmentsOff) }
        supported = await client.supportsSessionTextAttachments(sessionId: "s1")
        XCTAssertFalse(supported)

        client = makeClient { _ in throw URLError(.cannotConnectToHost) }
        supported = await client.supportsSessionTextAttachments(sessionId: "s1")
        XCTAssertFalse(supported, "capability probe errors degrade to false, never a claim")
    }

    func testFetchSessionAttachmentsMapsMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/sessions/s1/attachments")
            return self.json(#"{"attachments":[{"attachmentId":"abc123","sessionId":"s1","filename":"notes.txt","contentType":"text/plain","sizeBytes":5,"sha256":"2cf24d","createdAt":"2026-11-11T22:06:53Z"}]}"#)
        }
        let attachments = try await client.fetchSessionAttachments(sessionId: "s1")
        XCTAssertEqual(attachments.count, 1)
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachment.id, "abc123")
        XCTAssertEqual(attachment.attachmentId, "abc123")
        XCTAssertEqual(attachment.sessionId, "s1")
        XCTAssertEqual(attachment.filename, "notes.txt")
        XCTAssertEqual(attachment.contentType, "text/plain")
        XCTAssertEqual(attachment.sizeBytes, 5)
        XCTAssertEqual(attachment.sha256, "2cf24d")
        XCTAssertEqual(attachment.createdAt, ISO8601DateFormatter().date(from: "2026-11-11T22:06:53Z"))
    }

    func testFetchAttachmentAndContent() async throws {
        let binary = Data([0x00, 0x01, 0xFF, 0x10])
        let client = makeClient { request in
            if request.path == "/api/v1/attachments/abc123" {
                return self.json(#"{"attachmentId":"abc123","sessionId":"s1","filename":"notes.txt","contentType":"text/plain","sizeBytes":5,"sha256":"2cf24d","createdAt":"2026-11-11T22:06:53Z"}"#)
            }
            XCTAssertEqual(request.path, "/api/v1/attachments/abc123/content")
            return (200, binary)
        }
        let metadata = try await client.fetchAttachment(attachmentId: "abc123")
        XCTAssertEqual(metadata.id, "abc123")
        let content = try await client.fetchAttachmentContent(attachmentId: "abc123")
        XCTAssertEqual(content, binary)
        XCTAssertEqual(requests().map(\.path), [
            "/api/v1/attachments/abc123",
            "/api/v1/attachments/abc123/content",
        ])
    }

    func testFetchAttachmentContent404PassesThrough() async {
        let client = makeClient { _ in
            self.json(
                #"{"error":{"code":"attachmentNotFound","message":"attachment missing not found"},"contractsVersion":"0.1.0"}"#,
                status: 404
            )
        }
        do {
            _ = try await client.fetchAttachmentContent(attachmentId: "missing")
            XCTFail("404 must throw")
        } catch {
            assertOperationFailed(error, contains: "attachment missing not found")
        }
    }

    // MARK: - Member settings

    func testFetchMemberDetailMapsSettingsHonestly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/members/grokbot")
            return self.json(#"{"memberId":"grokbot","displayName":"Grok","model":"gpt-5","mode":"yolo","avatarShape":"cloud","avatarColor":"blue","avatar":null,"bindings":[],"updatedAt":"2026-11-11T00:00:00Z"}"#)
        }
        let member = try await client.fetchMemberDetail(name: "grokbot")
        XCTAssertEqual(member.name, "grokbot")
        XCTAssertEqual(member.displayName, "Grok")
        XCTAssertEqual(member.model, "gpt-5")
        XCTAssertEqual(member.mode, "yolo")
        XCTAssertEqual(member.avatarSeed, "Grok")
        XCTAssertEqual(member.avatarShape, "cloud")
        XCTAssertEqual(member.avatarColor, "blue")
        // This route exposes settings only: live state is honestly unknown.
        XCTAssertEqual(member.agent, "")
        XCTAssertEqual(member.machine, "")
        XCTAssertEqual(member.status, "")
        XCTAssertNil(member.tmuxSession)
        XCTAssertNil(member.sessionId)
    }

    func testFetchMemberDetailEmptySettingsIsUnknownNotInvented() async throws {
        let client = makeClient { _ in
            self.json(#"{"memberId":"grokbot","displayName":null,"model":null,"mode":null,"avatarShape":null,"avatarColor":null,"avatar":null,"bindings":[],"updatedAt":null}"#)
        }
        let member = try await client.fetchMemberDetail(name: "grokbot")
        XCTAssertEqual(member.name, "grokbot")
        XCTAssertEqual(member.avatarSeed, "grokbot")
        XCTAssertNil(member.displayName)
        XCTAssertNil(member.avatarShape)
        XCTAssertNil(member.avatarColor)
        XCTAssertEqual(member.model, "")
        XCTAssertEqual(member.mode, "")
        XCTAssertEqual(member.agent, "")
        XCTAssertEqual(member.machine, "")
        XCTAssertEqual(member.status, "")
    }

    func testSetMemberModeAndModelPatchBodies() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.method, "PATCH")
            XCTAssertEqual(request.path, "/api/v1/members/grokbot")
            return self.json(#"{"memberId":"grokbot","displayName":null,"model":null,"mode":null,"avatarShape":null,"avatarColor":null,"avatar":null,"bindings":[],"updatedAt":null}"#)
        }
        try await client.setMemberMode(name: "grokbot", mode: "safe")
        try await client.setMemberModel(name: "grokbot", model: "gpt-5")
        XCTAssertEqual(requests().count, 2)
        XCTAssertEqual(requests()[0].jsonBody()?["mode"] as? String, "safe")
        XCTAssertNil(requests()[0].jsonBody()?["model"])
        XCTAssertEqual(requests()[1].jsonBody()?["model"] as? String, "gpt-5")
        XCTAssertNil(requests()[1].jsonBody()?["mode"])
    }

    func testSetMemberAvatarPatchesShapeAndColor() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.method, "PATCH")
            XCTAssertEqual(request.path, "/api/v1/members/human")
            return self.json(#"{"memberId":"human","displayName":null,"model":null,"mode":null,"avatarShape":"cloud","avatarColor":"blue","avatar":null,"bindings":[],"updatedAt":null}"#)
        }
        try await client.setMemberAvatar(
            name: "human",
            avatar: ClientAvatarInfo(seed: "human", shape: "cloud", color: "blue")
        )
        let body = try XCTUnwrap(requests().last?.jsonBody())
        XCTAssertEqual(body["avatarShape"] as? String, "cloud")
        XCTAssertEqual(body["avatarColor"] as? String, "blue")

        // Only the supplied identity tokens are sent.
        try await client.setMemberAvatar(
            name: "human",
            avatar: ClientAvatarInfo(seed: "human", color: "blue")
        )
        let colorOnly = try XCTUnwrap(requests().last?.jsonBody())
        XCTAssertNil(colorOnly["avatarShape"])
        XCTAssertEqual(colorOnly["avatarColor"] as? String, "blue")
    }

    func testSetMemberAvatarUploadsDataURI() async throws {
        let payload = Data("pngbytes".utf8).base64EncodedString()
        let client = makeClient { request in
            XCTAssertEqual(request.method, "PUT")
            XCTAssertEqual(request.path, "/api/v1/members/human/avatar")
            return self.json(#"{"memberId":"human","displayName":null,"model":null,"mode":null,"avatarShape":null,"avatarColor":null,"avatar":{"avatarId":"abc","contentType":"image/png","sizeBytes":8,"sha256":"def"},"bindings":[],"updatedAt":"2026-11-11T00:00:00Z"}"#)
        }
        try await client.setMemberAvatar(
            name: "human",
            avatar: ClientAvatarInfo(
                seed: "human",
                customImageUri: "data:image/png;base64,\(payload)"
            )
        )
        let body = try XCTUnwrap(requests().last?.jsonBody())
        XCTAssertEqual(body["contentType"] as? String, "image/png")
        XCTAssertEqual(body["dataBase64"] as? String, payload)
    }

    func testSetMemberAvatarRejectsMissingIdentity() async {
        let client = makeClient { _ in self.json("{}") }
        do {
            try await client.setMemberAvatar(
                name: "human",
                avatar: ClientAvatarInfo(seed: "human", colorHex: "#0055ff")
            )
            XCTFail("avatar identity without shape/colour or image must throw")
        } catch {
            assertOperationFailed(error, contains: "requires a shape/colour or a png/jpeg data URI")
        }
        XCTAssertEqual(requests().count, 0)
    }

    // MARK: - Thread bindings

    private let threadListJSON = #"[{"threadId":"t1","title":"Fake Thread","memberIds":["human"],"unreadCount":0,"lastActivityAt":"2026-11-11T00:00:00Z"}]"#

    func testSupportsThreadSessionBindingProbesKnownThread() async throws {
        let client = makeClient { request in
            if request.path == "/api/v1/threads" {
                return self.json(self.threadListJSON)
            }
            XCTAssertEqual(request.path, "/api/v1/threads/t1/bindings")
            return self.json(#"{"bindings":[]}"#)
        }
        let supported = await client.supportsThreadSessionBinding()
        XCTAssertTrue(supported)
        XCTAssertEqual(requests().map(\.path), ["/api/v1/threads", "/api/v1/threads/t1/bindings"])
    }

    func testSupportsThreadSessionBindingFalseWhenNoThreads() async {
        let client = makeClient { _ in self.json("[]") }
        let supported = await client.supportsThreadSessionBinding()
        XCTAssertFalse(supported)
        XCTAssertEqual(requests().count, 1)
    }

    func testSupportsThreadSessionBindingFalseWhenRouteErrors() async {
        let client = makeClient { request in
            if request.path == "/api/v1/threads" {
                return self.json(self.threadListJSON)
            }
            return self.json(
                #"{"error":{"code":"threadNotFound","message":"thread t1 not found"},"contractsVersion":"0.1.0"}"#,
                status: 404
            )
        }
        let supported = await client.supportsThreadSessionBinding()
        XCTAssertFalse(supported)
    }

    func testThreadSessionBindingCandidatesAreSessions() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/sessions")
            return self.json(#"[{"sessionId":"s1","machineId":"m","agentType":"fake","workspacePath":"/p","title":"One","status":"idle","updatedAt":"2026-11-11T00:00:00Z","avatarSeed":"a"},{"sessionId":"s2","machineId":"m","agentType":"fake","workspacePath":"/p","title":"Two","status":"idle","updatedAt":"2026-11-11T00:00:00Z","avatarSeed":"b"}]"#)
        }
        let candidates = await client.threadSessionBindingCandidates()
        XCTAssertEqual(candidates.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(candidates.map(\.title), ["One", "Two"])
    }

    func testBindThreadSessionPutsPathAndBody() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.method, "PUT")
            XCTAssertEqual(request.path, "/api/v1/threads/t1/bindings/codex worker")
            XCTAssertTrue(request.url.absoluteString.contains("codex%20worker"), request.url.absoluteString)
            return self.json(#"{"threadId":"t1","member":"codex worker","sessionId":"s 1","agentType":"fake","boundAt":"2026-11-11T00:00:00Z"}"#)
        }
        try await client.bindThreadSession(threadId: "t1", sessionId: "s 1", nickname: "  codex worker  ")
        let body = try XCTUnwrap(requests().last?.jsonBody())
        XCTAssertEqual(body["sessionId"] as? String, "s 1")
    }

    func testBindThreadSessionValidatesBlankInputBeforeRequest() async {
        let client = makeClient { _ in self.json("{}") }
        do {
            try await client.bindThreadSession(threadId: "t1", sessionId: "s1", nickname: "   ")
            XCTFail("blank nickname must throw")
        } catch {
            assertOperationFailed(error, contains: "Choose a Session and a member name before binding")
        }
        do {
            try await client.bindThreadSession(threadId: "t1", sessionId: "  ", nickname: "codex")
            XCTFail("blank session id must throw")
        } catch {
            assertOperationFailed(error, contains: "Choose a Session and a member name before binding")
        }
        XCTAssertEqual(requests().count, 0)
    }

    func testUnbindThreadSessionDeletesPath() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.method, "DELETE")
            XCTAssertEqual(request.path, "/api/v1/threads/t1/bindings/grokbot")
            return self.json(#"{"ok":true,"threadId":"t1","member":"grokbot","removed":true}"#)
        }
        try await client.unbindThreadSession(threadId: "t1", member: "grokbot")
        XCTAssertEqual(requests().count, 1)
        XCTAssertEqual(requests()[0].method, "DELETE")
        XCTAssertEqual(requests()[0].path, "/api/v1/threads/t1/bindings/grokbot")
    }

    func testUnbindThreadSessionValidatesBlankMember() async {
        let client = makeClient { _ in self.json("{}") }
        do {
            try await client.unbindThreadSession(threadId: "t1", member: "  ")
            XCTFail("blank member must throw")
        } catch {
            assertOperationFailed(error, contains: "Choose a Thread member to unbind")
        }
        XCTAssertEqual(requests().count, 0)
    }

    func testFetchThreadMembersMapsRoster() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/api/v1/threads/t1/members")
            return self.json(#"{"members":[{"memberId":"codex-worker","nick":"codex-worker","agentType":"fake","machineId":"fake-host","status":"idle","sessionId":"fake-session-1","boundAt":"2026-11-11T00:00:00Z","settings":{"avatar":null,"avatarColor":"blue","avatarShape":"cloud","displayName":"Codex Work","memberId":"codex-worker","mode":"safe","model":"gpt-5","updatedAt":"2026-11-11T00:00:00Z"}},{"memberId":"human","nick":"human","agentType":null,"machineId":null,"status":null,"sessionId":null,"boundAt":null,"settings":{"avatar":null,"avatarColor":null,"avatarShape":null,"displayName":null,"memberId":"human","mode":null,"model":null,"updatedAt":null}}]}"#)
        }
        let members = try await client.fetchThreadMembers(threadId: "t1")
        XCTAssertEqual(members.count, 2)
        let codex = try XCTUnwrap(members.first)
        XCTAssertEqual(codex.name, "codex-worker")
        XCTAssertEqual(codex.agent, "fake")
        XCTAssertEqual(codex.machine, "fake-host")
        XCTAssertEqual(codex.model, "gpt-5")
        XCTAssertEqual(codex.mode, "safe")
        XCTAssertEqual(codex.status, "idle")
        XCTAssertEqual(codex.avatarSeed, "Codex Work")
        XCTAssertEqual(codex.displayName, "Codex Work")
        XCTAssertEqual(codex.avatarShape, "cloud")
        XCTAssertEqual(codex.avatarColor, "blue")
        XCTAssertEqual(codex.sessionId, "fake-session-1")
        let human = try XCTUnwrap(members.last)
        XCTAssertEqual(human.name, "human")
        XCTAssertEqual(human.agent, "")
        XCTAssertEqual(human.machine, "")
        XCTAssertEqual(human.model, "")
        XCTAssertEqual(human.mode, "")
        XCTAssertEqual(human.status, "")
        XCTAssertEqual(human.avatarSeed, "human")
        XCTAssertNil(human.displayName)
        XCTAssertNil(human.avatarShape)
        XCTAssertNil(human.avatarColor)
        XCTAssertNil(human.sessionId)
    }

    // MARK: - Approvals

    private let questionnaireApprovalJSON = #"{"approvals":[{"approvalId":"a1","sessionId":"s1","kind":{"type":"structuredQuestionnaire","intent":"pick","questions":[{"id":"q1","question":"Pick","options":["a","b"],"isMultiSelect":false},{"id":"q2","question":"Why","options":[],"isMultiSelect":false}]},"availableChoices":["allowedOnce","cancelled"],"state":"pending","createdAt":"2026-11-11T00:00:00Z","expiresAt":"2026-11-11T01:00:00Z"}]}"#

    func testFetchSessionApprovalSnapshotPathAndQueryMapping() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/api/v1/approvals")
            return self.json(self.questionnaireApprovalJSON)
        }
        let fetched = try await client.fetchSessionApproval(sessionId: "s 1")
        let approval = try XCTUnwrap(fetched)
        let request = try XCTUnwrap(requests().first)
        let queryItems = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })
        XCTAssertEqual(query["state"] as? String, "pending")
        XCTAssertEqual(query["sessionId"] as? String, "s 1")
        XCTAssertEqual(approval.approvalId, "a1")
        XCTAssertEqual(approval.sessionId, "s1")
        XCTAssertEqual(approval.availableChoices, [.allowedOnce, .cancelled])
        guard case let .structuredQuestionnaire(intent, questions) = approval.kind else {
            return XCTFail("expected questionnaire kind, got \(approval.kind)")
        }
        XCTAssertEqual(intent, "pick")
        XCTAssertEqual(questions.map(\.id), ["q1", "q2"])
        XCTAssertEqual(questions[0].options, ["a", "b"])
        XCTAssertEqual(questions[1].options, [])
    }

    func testFetchSessionApprovalEmptyReturnsNil() async throws {
        let client = makeClient { _ in self.json(#"{"approvals":[]}"#) }
        let approval = try await client.fetchSessionApproval(sessionId: "s1")
        XCTAssertNil(approval)
    }

    func testFetchSessionApprovalPropagatesErrors() async {
        let client = makeClient { _ in
            self.json(
                #"{"error":{"code":"operationFailed","message":"approval store is unreadable"},"contractsVersion":"0.1.0"}"#,
                status: 502
            )
        }
        do {
            _ = try await client.fetchSessionApproval(sessionId: "s1")
            XCTFail("error must be propagated")
        } catch {
            assertOperationFailed(error, contains: "approval store is unreadable")
        }
    }

    func testResolveApprovalQuestionnaireAnswersSplitSelectedAndText() async throws {
        let client = makeClient { request in
            if request.method == "GET" {
                return self.json(self.questionnaireApprovalJSON)
            }
            XCTAssertEqual(request.path, "/api/v1/sessions/s1/approval")
            return self.json(#"{"ok":true,"approvalId":"a1","state":"resolved","decision":"rejected","alreadyResolved":false}"#)
        }
        try await client.resolveSessionApproval(
            sessionId: "s1",
            approvalId: "a1",
            decision: ApprovalDecision(
                choice: .rejected,
                answers: [
                    "q1": ["a", "c"],
                    "q2": ["first", "free text"],
                ]
            )
        )
        let recorded = requests()
        XCTAssertEqual(recorded.map(\.method), ["GET", "POST"])
        let body = try XCTUnwrap(recorded.last?.jsonBody())
        XCTAssertEqual(body["approvalId"] as? String, "a1")
        XCTAssertEqual(body["decision"] as? String, "rejected")
        let answers = try XCTUnwrap(body["questionnaireAnswers"] as? [[String: Any]])
        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers[0]["questionId"] as? String, "q1")
        // Values outside the non-empty option list are kept, never dropped.
        XCTAssertEqual(answers[0]["selected"] as? [String], ["a", "c"])
        XCTAssertNil(answers[0]["text"])
        XCTAssertEqual(answers[1]["questionId"] as? String, "q2")
        XCTAssertEqual(answers[1]["selected"] as? [String], [])
        XCTAssertEqual(answers[1]["text"] as? String, "free text")
    }

    func testResolveApprovalQuestionnaireFallsBackWithoutMetadata() async throws {
        let client = makeClient { request in
            if request.method == "GET" {
                // Approval no longer pending (e.g. already resolved elsewhere).
                return self.json(#"{"approvals":[]}"#)
            }
            return self.json(#"{"ok":true,"approvalId":"a1","state":"resolved","decision":"allowedOnce","alreadyResolved":false}"#)
        }
        try await client.resolveSessionApproval(
            sessionId: "s1",
            approvalId: "a1",
            decision: ApprovalDecision(choice: .allowedOnce, answers: ["q1": ["a", "b"]])
        )
        let body = try XCTUnwrap(requests().last?.jsonBody())
        let answers = try XCTUnwrap(body["questionnaireAnswers"] as? [[String: Any]])
        XCTAssertEqual(answers[0]["questionId"] as? String, "q1")
        XCTAssertEqual(answers[0]["selected"] as? [String], ["a", "b"])
        XCTAssertNil(answers[0]["text"])
    }

    func testResolveApprovalCancelledDecisionSerialized() async throws {
        let client = makeClient { _ in
            self.json(#"{"ok":true,"approvalId":"a1","state":"resolved","decision":"cancelled","alreadyResolved":false}"#)
        }
        try await client.resolveSessionApproval(
            sessionId: "s1",
            approvalId: "a1",
            decision: ApprovalDecision(choice: .cancelled)
        )
        XCTAssertEqual(requests().count, 1, "plain decisions need no metadata round-trip")
        let body = try XCTUnwrap(requests().last?.jsonBody())
        XCTAssertEqual(body["approvalId"] as? String, "a1")
        XCTAssertEqual(body["decision"] as? String, "cancelled")
        XCTAssertNil(body["questionnaireAnswers"])
    }

    func testResolveApprovalCancelledPropagatesServerRejection() async {
        let client = makeClient { _ in
            self.json(
                #"{"error":{"code":"invalidRequest","message":"approval does not offer the cancelled decision"},"contractsVersion":"0.1.0"}"#,
                status: 400
            )
        }
        do {
            try await client.resolveSessionApproval(
                sessionId: "s1",
                approvalId: "a1",
                decision: ApprovalDecision(choice: .cancelled)
            )
            XCTFail("server rejection must propagate")
        } catch {
            assertOperationFailed(error, contains: "does not offer the cancelled decision")
        }
    }

    func testApprovalResolvedWireEventCarriesCancelled() async {
        let client = makeClient { _ in self.json("{}") }
        let data = raw(#"{"eventType":"approvalResolved","approvalId":"a1","decision":"cancelled"}"#)
        let event = await client.mapWireEvent(eventType: "approvalResolved", data: data)
        XCTAssertEqual(
            event,
            .approvalResolved(approvalId: "a1", decision: ApprovalDecision(choice: .cancelled))
        )
    }

    // MARK: - Backend health + diagnostics

    func testProbeBackendReachable() async {
        let client = makeClient { request in
            XCTAssertEqual(request.path, "/health")
            return self.json(#"{"ok":true,"contractsVersion":"0.1.0","service":"pharos-meshd"}"#)
        }
        let probe = await client.probeBackend()
        XCTAssertEqual(
            probe,
            .reachable(BackendHealth(ok: true, contractsVersion: "0.1.0", service: "pharos-meshd"))
        )
        XCTAssertNil(
            PharosBackendDiagnostics.guidance(baseURL: baseURL, probe: probe),
            "a healthy pharos backend needs no guidance"
        )
    }

    func testProbeBackendUnreachable() async {
        let client = makeClient { _ in throw URLError(.cannotConnectToHost) }
        let probe = await client.probeBackend()
        guard case let .unreachable(reason) = probe else {
            return XCTFail("expected unreachable, got \(probe)")
        }
        XCTAssertFalse(reason.isEmpty)
        let guidance = PharosBackendDiagnostics.guidance(baseURL: baseURL, probe: probe)
        let text = guidance ?? ""
        XCTAssertTrue(text.contains(baseURL.absoluteString), text)
        XCTAssertTrue(text.contains("8787"), text)
        XCTAssertTrue(text.contains("PHAROS_API_BASE_URL"), text)
    }

    func testBackendDiagnosticsGuidance() {
        let url = URL(string: "http://127.0.0.1:8787")!

        // Another local app on the default port.
        let wrongService = BackendHealthProbe.reachable(
            BackendHealth(ok: true, contractsVersion: "0.1.0", service: "linked-demo")
        )
        let wrongText = PharosBackendDiagnostics.guidance(baseURL: url, probe: wrongService) ?? ""
        XCTAssertTrue(wrongText.contains("linked-demo"), wrongText)
        XCTAssertTrue(wrongText.contains("8787"), wrongText)
        XCTAssertTrue(wrongText.contains("PHAROS_API_BASE_URL"), wrongText)
        XCTAssertTrue(wrongText.contains(url.absoluteString), wrongText)

        // Contracts mismatch.
        let mismatch = BackendHealthProbe.reachable(
            BackendHealth(ok: true, contractsVersion: "0.2.0", service: "pharos-web")
        )
        let mismatchText = PharosBackendDiagnostics.guidance(baseURL: url, probe: mismatch) ?? ""
        XCTAssertTrue(mismatchText.contains("0.2.0"), mismatchText)
        XCTAssertTrue(mismatchText.contains(PharosAPIConfiguration.contractsVersion), mismatchText)
        XCTAssertTrue(mismatchText.contains("PHAROS_API_BASE_URL"), mismatchText)

        // Unhealthy Pharos backend.
        let unhealthy = BackendHealthProbe.reachable(
            BackendHealth(ok: false, contractsVersion: "0.1.0", service: "pharos-meshd")
        )
        let unhealthyText = PharosBackendDiagnostics.guidance(baseURL: url, probe: unhealthy) ?? ""
        XCTAssertTrue(unhealthyText.contains("pharos-meshd"), unhealthyText)
        XCTAssertTrue(unhealthyText.contains("ok=false"), unhealthyText)

        // Healthy pharos: no guidance.
        let healthy = BackendHealthProbe.reachable(
            BackendHealth(ok: true, contractsVersion: "0.1.0", service: "pharos-meshd")
        )
        XCTAssertNil(PharosBackendDiagnostics.guidance(baseURL: url, probe: healthy))
    }

    // MARK: - Honest gaps

    func testExecuteSessionCommandIsHonestlyUnavailable() async {
        let client = makeClient { _ in self.json("{}") }
        do {
            _ = try await client.executeSessionCommand(sessionId: "s1", line: "/compact")
            XCTFail("session commands must not be faked")
        } catch {
            assertOperationFailed(error, contains: "Session commands are unavailable")
        }
        XCTAssertEqual(requests().count, 0, "no endpoint call for a nonexistent API")
    }
}
