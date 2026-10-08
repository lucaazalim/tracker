import Foundation
import Synchronization
import Testing
@testable import TrackerKit

@Suite("Queue store")
struct QueueStoreTests {
    @Test func appendsAndReadsInOrder() async throws {
        let store = try QueueStore()
        for index in 0..<5 {
            try await store.append(Data("\(index)".utf8), kind: index == 2 ? .event : .location)
        }
        let batch = try await store.oldest(limit: 3)
        #expect(batch.map { String(decoding: $0.payload, as: UTF8.self) } == ["0", "1", "2"])
        #expect(batch[2].kind == .event)
        #expect(try await store.counts() == QueueCounts(locations: 4, events: 1))

        try await store.remove(ids: batch.map(\.id))
        #expect(try await store.counts().total == 2)
    }

    @Test func latestStrategyKeepsOneLocationAndAllEvents() async throws {
        let store = try QueueStore()
        try await store.append(Data("e".utf8), kind: .event)
        try await store.replaceLocations(with: Data("1".utf8))
        try await store.replaceLocations(with: Data("2".utf8))
        let all = try await store.oldest(limit: 10)
        #expect(all.map { String(decoding: $0.payload, as: UTF8.self) } == ["e", "2"])
    }

    @Test func pruneEnforcesCountAndAge() async throws {
        let store = try QueueStore()
        let now = Date.now
        try await store.append(Data("old".utf8), kind: .location, at: now.addingTimeInterval(-10 * 86_400))
        for index in 0..<5 {
            try await store.append(Data("\(index)".utf8), kind: .location, at: now)
        }

        let removedByAge = try await store.prune(QueueRetention(maxRecords: nil, maxAgeDays: 7), now: now)
        #expect(removedByAge == 1)

        let removedByCount = try await store.prune(QueueRetention(maxRecords: 2, maxAgeDays: nil), now: now)
        #expect(removedByCount == 3)
        // The newest records survive.
        #expect(try await store.oldest(limit: 10).map { String(decoding: $0.payload, as: UTF8.self) } == ["3", "4"])
    }

    @Test func removesLargeIDSetsInChunks() async throws {
        let store = try QueueStore()
        for _ in 0..<1_200 {
            try await store.append(Data("x".utf8), kind: .location)
        }
        let all = try await store.oldest(limit: 2_000)
        try await store.remove(ids: all.map(\.id))
        #expect(try await store.counts().total == 0)
    }

    @Test func persistsToDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tracker-\(UUID().uuidString)/queue.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try QueueStore(url: url)
            try await store.append(Data("persisted".utf8), kind: .location)
        }
        let reopened = try QueueStore(url: url)
        #expect(try await reopened.counts().locations == 1)
    }

    @Test func requestLogIsCapped() async throws {
        let store = try QueueStore()
        for index in 0..<(QueueStore.maxLogEntries + 10) {
            try await store.appendLog(.fixture(statusCode: index))
        }
        let logs = try await store.recentLogs()
        #expect(logs.count == QueueStore.maxLogEntries)
        #expect(logs.first?.statusCode == QueueStore.maxLogEntries + 9)
    }
}

@Suite("Uploader")
struct UploaderTests {
    func makeServer(_ configure: (inout ServerSettings) -> Void = { _ in }) -> ServerSettings {
        var server = ServerSettings()
        server.endpoint = "https://example.com/api"
        server.accessToken = "token"
        configure(&server)
        return server
    }

    func filledStore(_ count: Int) async throws -> QueueStore {
        let store = try QueueStore()
        for index in 0..<count {
            try await store.append(try JSONValue.object(["n": .int(index)]).encoded(), kind: .location)
        }
        return store
    }

    @Test func uploadsInBatchesUntilEmpty() async throws {
        let store = try await filledStore(5)
        let transport = MockTransport { _ in (200, #"{"result":"ok"}"#) }
        let uploader = Uploader(store: store, transport: transport)

        let report = await uploader.flush(UploadContext(server: makeServer(), batchSize: 2))
        #expect(report.succeeded)
        #expect(report.requests == 3)
        #expect(report.recordsSent == 5)
        #expect(report.remaining == 0)

        let bodies = try transport.requests.map { try JSONValue.decode($0.httpBody ?? Data()) }
        #expect(bodies.map { $0["locations"]?.arrayValue?.count } == [2, 2, 1])
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func attachesCurrentLocationOnlyWhenBacklogExceedsBatch() async throws {
        let store = try await filledStore(3)
        let transport = MockTransport { _ in (200, #"{"result":"ok"}"#) }
        let uploader = Uploader(store: store, transport: transport)
        let current = try JSONValue.object(["current": true]).encoded()

        _ = await uploader.flush(UploadContext(server: makeServer(), batchSize: 2, currentLocation: current))
        let bodies = try transport.requests.map { try JSONValue.decode($0.httpBody ?? Data()) }
        #expect(bodies[0]["current"] != nil)
        #expect(bodies[1]["current"] == nil)
    }

    @Test func keepsRecordsWhenServerDoesNotAcknowledge() async throws {
        let store = try await filledStore(3)
        let transport = MockTransport { _ in (200, #"{"error":"database is down"}"#) }
        let uploader = Uploader(store: store, transport: transport)

        let report = await uploader.flush(UploadContext(server: makeServer(), batchSize: 10))
        #expect(!report.succeeded)
        #expect(report.failure == "database is down")
        #expect(report.remaining == 3)
        #expect(transport.requests.count == 1)

        let log = try #require(try await store.recentLogs().first)
        #expect(!log.success)
        #expect(log.statusCode == 200)
        #expect(log.recordCount == 3)
        #expect(log.requestHeaders.contains("Authorization: Bearer ••••••"))
        #expect(!log.requestHeaders.contains("token"))
    }

    @Test func httpErrorsFail() async throws {
        let store = try await filledStore(1)
        let uploader = Uploader(store: store, transport: MockTransport { _ in (500, "oops") })
        let report = await uploader.flush(UploadContext(server: makeServer(), batchSize: 10))
        #expect(report.failure?.hasPrefix("HTTP 500") == true)
        #expect(report.remaining == 1)
    }

    @Test func anySuccessStatusModeAcceptsEmptyBodies() async throws {
        let store = try await filledStore(2)
        let uploader = Uploader(store: store, transport: MockTransport { _ in (204, "") })
        let report = await uploader.flush(UploadContext(server: makeServer { $0.acknowledgement = .anySuccessStatus }, batchSize: 10))
        #expect(report.succeeded)
        #expect(report.remaining == 0)
    }

    @Test func collectsRemoteSettings() async throws {
        let store = try await filledStore(1)
        let uploader = Uploader(store: store, transport: MockTransport { _ in (200, #"{"result":"ok","set":{"send_interval":"1m"}}"#) })
        let report = await uploader.flush(UploadContext(server: makeServer(), batchSize: 10))
        #expect(report.remoteSettings == [["send_interval": "1m"]])
    }

    @Test func ownTracksSendsOneObjectPerRequestWithBasicAuth() async throws {
        let store = try await filledStore(2)
        let transport = MockTransport { _ in (200, "[]") }
        let uploader = Uploader(store: store, transport: transport)
        let server = makeServer {
            $0.format = .owntracks
            $0.authentication = .basic
            $0.username = "user"
            $0.password = "pass"
        }

        let report = await uploader.flush(UploadContext(server: server, batchSize: 200))
        #expect(report.succeeded)
        #expect(transport.requests.count == 2)
        #expect(try JSONValue.decode(transport.requests[0].httpBody ?? Data()) == ["n": 0])
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
    }

    @Test func customHeadersOverrideDefaults() throws {
        let server = makeServer {
            $0.headers = [HTTPHeader(name: "Authorization", value: "Custom 1"), HTTPHeader(name: " X-Extra ", value: "2"), HTTPHeader(name: "", value: "ignored")]
        }
        let request = try Uploader.makeRequest(server: server, body: Data(), lastLocation: nil, batteryLevel: nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Custom 1")
        #expect(request.value(forHTTPHeaderField: "X-Extra") == "2")
    }

    @Test func missingEndpointFailsWithoutRequest() async throws {
        let store = try await filledStore(1)
        let transport = MockTransport { _ in (200, #"{"result":"ok"}"#) }
        let uploader = Uploader(store: store, transport: transport)
        let report = await uploader.flush(UploadContext(server: ServerSettings(), batchSize: 10))
        #expect(report.failure == UploadError.endpointNotConfigured.errorDescription)
        #expect(transport.requests.isEmpty)
    }

    @Test func capsRequestsPerFlush() async throws {
        let store = try await filledStore(30)
        let uploader = Uploader(store: store, transport: MockTransport { _ in (200, #"{"result":"ok"}"#) })
        let report = await uploader.flush(UploadContext(server: makeServer(), batchSize: 1))
        #expect(report.requests == 25)
        #expect(report.remaining == 5)
    }

    @Test func testConnectionLogsTheExchange() async throws {
        let store = try QueueStore()
        let transport = MockTransport { _ in (200, #"{"result":"ok"}"#) }
        let uploader = Uploader(store: store, transport: transport)
        let entry = try #require(await uploader.testConnection(makeServer()))
        #expect(entry.success)
        #expect(entry.requestPreview == #"{"locations":[]}"#)
    }
}

// MARK: - Helpers

final class MockTransport: HTTPTransport {
    private let handler: @Sendable (URLRequest) -> (Int, String)
    private let recorded = Mutex<[URLRequest]>([])

    init(handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.handler = handler
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

extension RequestLogEntry {
    static func fixture(statusCode: Int) -> RequestLogEntry {
        RequestLogEntry(
            date: .now, method: "POST", url: "https://example.com", statusCode: statusCode, duration: 0.1,
            requestBytes: 10, recordCount: 1, success: true, error: nil, requestHeaders: "",
            requestPreview: "{}", responsePreview: "{}"
        )
    }
}
