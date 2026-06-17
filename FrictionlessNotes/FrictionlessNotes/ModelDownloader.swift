//
//  ModelDownloader.swift
//  FrictionlessNotes
//
//  Robust background download of the Parakeet TDT v3 CoreML bundles from
//  Hugging Face, staged into a local folder that FluidAudio loads via
//  AsrModels.load(from:). Uses a background URLSession so the transfer
//  continues — and resumes — even if the app is suspended or the network
//  drops. Already-present files are skipped, so it's idempotent and resumable.
//

import Foundation

@MainActor
final class ModelDownloader: NSObject {

    static let shared = ModelDownloader()

    /// Canonical v3 asset set (FluidAudio ManualModelLoading) — four .mlmodelc
    /// bundles plus the vocab. Sizes are approximate, for progress only.
    private static let repo = "parakeet-tdt-0.6b-v3-coreml"
    private static let manifest: [(path: String, size: Int64)] = [
        ("Preprocessor.mlmodelc/analytics/coremldata.bin", 243),
        ("Preprocessor.mlmodelc/coremldata.bin", 486),
        ("Preprocessor.mlmodelc/metadata.json", 2841),
        ("Preprocessor.mlmodelc/model.mil", 28181),
        ("Preprocessor.mlmodelc/weights/weight.bin", 491072),
        ("Encoder.mlmodelc/analytics/coremldata.bin", 243),
        ("Encoder.mlmodelc/coremldata.bin", 485),
        ("Encoder.mlmodelc/metadata.json", 2921),
        ("Encoder.mlmodelc/model.mil", 959769),
        ("Encoder.mlmodelc/weights/weight.bin", 445_187_200),
        ("Decoder.mlmodelc/analytics/coremldata.bin", 243),
        ("Decoder.mlmodelc/coremldata.bin", 554),
        ("Decoder.mlmodelc/metadata.json", 3427),
        ("Decoder.mlmodelc/model.mil", 13110),
        ("Decoder.mlmodelc/weights/weight.bin", 23_604_992),
        ("JointDecision.mlmodelc/analytics/coremldata.bin", 243),
        ("JointDecision.mlmodelc/coremldata.bin", 534),
        ("JointDecision.mlmodelc/metadata.json", 2936),
        ("JointDecision.mlmodelc/model.mil", 9723),
        ("JointDecision.mlmodelc/weights/weight.bin", 12_642_764),
        ("parakeet_vocab.json", 151_122),
    ]

    private static var totalBytes: Int64 { manifest.reduce(0) { $0 + $1.size } }

    /// Staged repo folder; pass this directly to AsrModels.load(from:).
    /// nonisolated so the background-session delegate (off the main actor) can use it.
    nonisolated static var repoDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("Models/\(repo)", isDirectory: true)
    }

    nonisolated static func relativePath(for url: URL?) -> String? {
        guard let s = url?.absoluteString,
              let range = s.range(of: "/resolve/main/") else { return nil }
        let tail = String(s[range.upperBound...])
        return tail.replacingOccurrences(of: "?download=true", with: "")
            .removingPercentEncoding
    }

    // Progress, observed by the UI via the closure.
    var onProgress: ((Double) -> Void)?
    var onComplete: ((Result<URL, Error>) -> Void)?
    private(set) var isDownloading = false

    /// Stored by the app delegate when iOS relaunches us to finish a background
    /// transfer; invoked once the session reports all events delivered.
    var backgroundCompletionHandler: (() -> Void)?

    /// Live bytes for the file currently downloading, so the dominant 445 MB
    /// encoder shows continuous movement instead of freezing the bar.
    private var inFlightBytes: [String: Int64] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "notes.parakeet.models")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// True once every manifest file is on disk at the expected size.
    static func isStaged() -> Bool {
        let fm = FileManager.default
        for item in manifest {
            let url = repoDirectory.appendingPathComponent(item.path)
            guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64,
                  size > 0 else { return false }
        }
        return true
    }

    /// Begin (or resume) the download. Files already present are skipped.
    func start() {
        guard !isDownloading else { return }
        guard !Self.isStaged() else {
            onComplete?(.success(Self.repoDirectory))
            return
        }
        isDownloading = true
        ensureDirectories()
        // Re-enqueue only the files that are missing/incomplete.
        session.getAllTasks { tasks in
            let active = Set(tasks.compactMap { $0.originalRequest?.url?.absoluteString })
            Task { @MainActor in
                for item in Self.manifest where !Self.fileComplete(item) {
                    let url = Self.remoteURL(for: item.path)
                    if active.contains(url.absoluteString) { continue }
                    let task = self.session.downloadTask(with: url)
                    task.resume()
                }
            }
        }
    }

    // MARK: Helpers

    private static func remoteURL(for path: String) -> URL {
        URL(string: "https://huggingface.co/FluidInference/\(repo)/resolve/main/\(path)?download=true")!
    }

    private static func fileComplete(_ item: (path: String, size: Int64)) -> Bool {
        let url = repoDirectory.appendingPathComponent(item.path)
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        else { return false }
        return size > 0
    }

    private func ensureDirectories() {
        let fm = FileManager.default
        var dirs = Set<String>()
        for item in Self.manifest {
            let dir = (item.path as NSString).deletingLastPathComponent
            if !dir.isEmpty { dirs.insert(dir) }
        }
        try? fm.createDirectory(at: Self.repoDirectory, withIntermediateDirectories: true)
        for dir in dirs {
            try? fm.createDirectory(at: Self.repoDirectory.appendingPathComponent(dir),
                                    withIntermediateDirectories: true)
        }
    }

    private func reportProgress() {
        let done = Self.manifest.filter { Self.fileComplete($0) }.reduce(Int64(0)) { $0 + $1.size }
        // Add live bytes for in-flight files that haven't landed on disk yet.
        var live: Int64 = 0
        for (path, bytes) in inFlightBytes {
            if !Self.manifest.contains(where: { $0.path == path && Self.fileComplete($0) }) {
                live += bytes
            }
        }
        onProgress?(min(Double(done + live) / Double(Self.totalBytes), 1.0))
    }

    fileprivate func checkAllDone() {
        if Self.isStaged() {
            isDownloading = false
            onProgress?(1.0)
            onComplete?(.success(Self.repoDirectory))
        }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Runs on the background delegate queue. Move synchronously here,
        // before the temp file is reclaimed — using only nonisolated helpers.
        let fm = FileManager.default
        guard let rel = ModelDownloader.relativePath(for: downloadTask.originalRequest?.url)
        else { return }
        let dest = ModelDownloader.repoDirectory.appendingPathComponent(rel)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try? fm.moveItem(at: location, to: dest)
        Task { @MainActor in
            self.reportProgress()
            self.checkAllDone()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let rel = ModelDownloader.relativePath(for: downloadTask.originalRequest?.url)
        else { return }
        Task { @MainActor in
            self.inFlightBytes[rel] = totalBytesWritten
            self.reportProgress()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            // Transient failure: leave staged files in place; the next start()
            // (foreground resume) re-enqueues only what's missing.
            self.isDownloading = false
            self.onComplete?(.failure(error))
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
