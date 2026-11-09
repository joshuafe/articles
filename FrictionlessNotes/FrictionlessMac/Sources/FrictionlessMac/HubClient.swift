//
//  HubClient.swift
//  FrictionlessMac
//
//  The Mac's line to the frictionless-pm hub (DESIGN-PM.md §9, hub/README.md):
//  pull the ledger with GET /sync, push a batch of changes with POST /sync,
//  ask for a re-plan. Configured by hub.json next to ledger.json:
//
//      { "url": "https://<ref>.supabase.co", "key": "fpm_mac_…" }
//
//  No hub.json → no hub; the file-only path works exactly as before.
//

import Foundation

struct HubConfig: Codable, Equatable {
    var url: URL
    var key: String

    static func defaultURL(appName: String = "FrictionlessNotes") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("hub.json")
    }

    static func load(from url: URL = defaultURL()) -> HubConfig? {
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(HubConfig.self, from: data) else { return nil }
        guard !c.key.isEmpty, c.url.host != nil else { return nil }
        return c
    }

    var functionsBase: URL { url.appendingPathComponent("functions/v1", isDirectory: true) }
}

enum HubError: LocalizedError {
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "hub \(code): \(body.prefix(200))"
        case .decoding(let why): return "hub reply unreadable: \(why)"
        }
    }
}

struct HubPushResult: Decodable {
    var applied: Int
    var version: Int
}

final class HubClient: Sendable {
    let config: HubConfig
    private let session: URLSession

    init(config: HubConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    private func request(_ path: String, method: String, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: config.functionsBase.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = body
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw HubError.http(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw HubError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// The whole ledger as the hub has it.
    func pull() async throws -> WireSnapshot {
        let data = try await send(request("sync", method: "GET"))
        do { return try JSONDecoder().decode(WireSnapshot.self, from: data) } catch { throw HubError.decoding(String(describing: error)) }
    }

    /// Upsert the changed rows (and deletions); the hub re-plans before replying.
    func push(_ changes: HubChanges) async throws -> HubPushResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try await send(request("sync", method: "POST", body: try encoder.encode(changes)))
        do { return try JSONDecoder().decode(HubPushResult.self, from: data) } catch { throw HubError.decoding(String(describing: error)) }
    }

    /// Ask the hub to run the engine now (the Mac runs its own copy; this keeps the feed and assistants current).
    func replan() async throws {
        _ = try await send(request("replan", method: "POST", body: Data("{\"source\":\"mac\"}".utf8)))
    }
}
