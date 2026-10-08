import Foundation

/// Abstracts the network so uploads can be tested without a server.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum UploadError: Error, LocalizedError, Sendable, Equatable {
    case endpointNotConfigured
    case invalidEndpoint(String)

    public var errorDescription: String? {
        switch self {
        case .endpointNotConfigured: "No receiver endpoint is configured."
        case .invalidEndpoint(let url): "The endpoint URL is invalid: \(url)"
        }
    }
}

/// Everything needed to perform uploads, captured at flush time.
public struct UploadContext: Sendable {
    public var server: ServerSettings
    public var batchSize: Int
    /// Newest location record, attached as `current` when the backlog spans several batches.
    public var currentLocation: Data?
    /// Used to expand URL template placeholders.
    public var lastLocation: LocationSample?
    public var batteryLevel: Double?

    public init(server: ServerSettings, batchSize: Int, currentLocation: Data? = nil, lastLocation: LocationSample? = nil, batteryLevel: Double? = nil) {
        self.server = server
        self.batchSize = batchSize
        self.currentLocation = currentLocation
        self.lastLocation = lastLocation
        self.batteryLevel = batteryLevel
    }

    var effectiveBatchSize: Int {
        server.format == .owntracks ? 1 : min(max(batchSize, 1), 10_000)
    }
}

public struct FlushReport: Sendable, Equatable {
    public var recordsSent = 0
    public var requests = 0
    public var remaining = 0
    /// `set` objects returned by the server, in order.
    public var remoteSettings: [JSONValue] = []
    /// Description of the failure that stopped the flush, if any.
    public var failure: String?
    /// Set when another flush was already running and this call did nothing.
    public var skipped = false

    public init() {}

    public var succeeded: Bool { failure == nil && !skipped }
}

/// Drains the queue to the configured receiver, batch by batch.
public actor Uploader {
    private let store: QueueStore
    private let transport: any HTTPTransport
    private var isFlushing = false

    /// Requests per flush are capped so a huge backlog can't keep the app busy in the background indefinitely.
    public var maxRequestsPerFlush = 25

    public init(store: QueueStore, transport: any HTTPTransport = URLSession(configuration: .ephemeral)) {
        self.store = store
        self.transport = transport
    }

    /// Uploads queued records until the queue is empty, a request fails, or the per-flush cap is hit.
    public func flush(_ context: UploadContext) async -> FlushReport {
        var report = FlushReport()
        guard !isFlushing else {
            report.skipped = true
            return report
        }
        isFlushing = true
        defer { isFlushing = false }

        do {
            while report.requests < maxRequestsPerFlush {
                let batch = try await store.oldest(limit: context.effectiveBatchSize)
                if batch.isEmpty { break }

                let total = try await store.counts().total
                let current = (context.server.includeCurrentLocation && total > batch.count) ? context.currentLocation : nil
                let body = PayloadBuilder.batchBody(records: batch.map(\.payload), current: current, format: context.server.format)
                let request = try Self.makeRequest(server: context.server, body: body, lastLocation: context.lastLocation, batteryLevel: context.batteryLevel)

                let outcome = await perform(request, recordCount: batch.count, server: context.server)
                report.requests += 1
                switch outcome {
                case .success(let remoteSettings):
                    try await store.remove(ids: batch.map(\.id))
                    report.recordsSent += batch.count
                    if let remoteSettings { report.remoteSettings.append(remoteSettings) }
                case .failure(let message):
                    report.failure = message
                    report.remaining = try await store.counts().total
                    return report
                }
            }
            report.remaining = try await store.counts().total
        } catch {
            report.failure = error.localizedDescription
        }
        return report
    }

    /// Sends an empty batch to check connectivity, authentication and the acknowledgement contract.
    public func testConnection(_ server: ServerSettings) async -> RequestLogEntry? {
        do {
            let body = server.format == .owntracks ? Data("[]".utf8) : Data(#"{"locations":[]}"#.utf8)
            let request = try Self.makeRequest(server: server, body: body, lastLocation: nil, batteryLevel: nil)
            _ = await perform(request, recordCount: 0, server: server)
            return try await store.recentLogs(limit: 1).first
        } catch {
            return nil
        }
    }

    // MARK: Request

    public static func makeRequest(server: ServerSettings, body: Data, lastLocation: LocationSample?, batteryLevel: Double?) throws -> URLRequest {
        let template = server.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { throw UploadError.endpointNotConfigured }
        let expanded = URLTemplate.expand(template, location: lastLocation, batteryLevel: batteryLevel, deviceID: server.deviceID)
        guard let url = URL(string: expanded), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw UploadError.invalidEndpoint(expanded)
        }

        var request = URLRequest(url: url, timeoutInterval: max(server.timeout, 5))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch server.authentication {
        case .none:
            break
        case .bearer:
            if !server.accessToken.isEmpty {
                request.setValue("Bearer \(server.accessToken)", forHTTPHeaderField: "Authorization")
            }
        case .basic:
            let credentials = Data("\(server.username):\(server.password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        // Custom headers go last so they can override anything above.
        for header in server.headers where !header.name.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.name.trimmingCharacters(in: .whitespaces))
        }
        return request
    }

    // MARK: Response

    enum Outcome {
        case success(remoteSettings: JSONValue?)
        case failure(String)
    }

    private func perform(_ request: URLRequest, recordCount: Int, server: ServerSettings) async -> Outcome {
        let started = Date.now
        let outcome: Outcome
        var status: Int?
        var responseData = Data()
        var transportError: String?

        do {
            let (data, response) = try await transport.send(request)
            status = response.statusCode
            responseData = data
            outcome = Self.evaluate(status: response.statusCode, body: data, server: server)
        } catch {
            transportError = error.localizedDescription
            outcome = .failure(error.localizedDescription)
        }

        let failureMessage: String? = if case .failure(let message) = outcome { message } else { nil }
        let entry = RequestLogEntry(
            date: started,
            method: request.httpMethod ?? "POST",
            url: request.url?.absoluteString ?? "",
            statusCode: status,
            duration: Date.now.timeIntervalSince(started),
            requestBytes: request.httpBody?.count ?? 0,
            recordCount: recordCount,
            success: failureMessage == nil,
            error: failureMessage ?? transportError,
            requestHeaders: Self.describeHeaders(request.allHTTPHeaderFields ?? [:]),
            requestPreview: Self.preview(request.httpBody ?? Data()),
            responsePreview: Self.preview(responseData)
        )
        try? await store.appendLog(entry)
        return outcome
    }

    /// Applies the acknowledgement contract to a response.
    static func evaluate(status: Int, body: Data, server: ServerSettings) -> Outcome {
        let json = try? JSONValue.decode(body)
        let remoteSettings = json?["set"].flatMap { $0.objectValue != nil ? $0 : nil }

        guard (200..<300).contains(status) else {
            let detail = json?["error"]?.stringValue ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
            return .failure("HTTP \(status): \(detail)")
        }

        // OwnTracks receivers answer with an array (often empty), never `{"result":"ok"}`.
        if server.acknowledgement == .anySuccessStatus || server.format == .owntracks {
            return .success(remoteSettings: remoteSettings)
        }

        guard let json, json.objectValue != nil else {
            return .failure(#"The server did not return a JSON object. Expected {"result":"ok"}."#)
        }
        guard json["result"]?.stringValue == "ok" else {
            let error = json["error"]?.stringValue
            return .failure(error ?? #"The server did not acknowledge the batch with {"result":"ok"}."#)
        }
        return .success(remoteSettings: remoteSettings)
    }

    // MARK: Logging helpers

    static let previewLimit = 4_096

    static func preview(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let truncated = data.prefix(previewLimit)
        let text = String(decoding: truncated, as: UTF8.self)
        return data.count > previewLimit ? text + "\n… (\(data.count - previewLimit) more bytes)" : text
    }

    /// Header list for the inspector, with credentials masked.
    static func describeHeaders(_ headers: [String: String]) -> String {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { key, value in
                let sensitive = ["authorization", "cookie", "x-api-key", "proxy-authorization"].contains(key.lowercased())
                return "\(key): \(sensitive ? mask(value) : value)"
            }
            .joined(separator: "\n")
    }

    private static func mask(_ value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1)
        if parts.count == 2 { return "\(parts[0]) ••••••" }
        return "••••••"
    }
}
