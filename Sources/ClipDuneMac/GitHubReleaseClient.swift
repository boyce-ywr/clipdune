import Foundation
import ClipDuneCore
import CFNetwork

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let id: Int64
        public let name: String
        public let size: Int64
    }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    public func asset(named name: String) throws -> Asset {
        let matches = assets.filter { $0.name == name }
        guard matches.count == 1, let asset = matches.first, asset.id > 0 else { throw UpdateError.missingAsset }
        return asset
    }
}

public enum GitHubReleaseClient {
    public static func releaseForPublishing(id: Int64, token: String) async throws -> GitHubRelease {
        guard id > 0 else { throw UpdateError.invalidManifest }
        let data = try await ReleaseRequest(url: GitHubUpdatePolicy.apiRoot.appendingPathComponent("releases/\(id)"),
                                            token: token, accept: "application/vnd.github+json", maximumBytes: 1024 * 1024,
                                            proxyURL: URL(string: "http://127.0.0.1:7897")).run()
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else { throw UpdateError.invalidManifest }
        return release
    }

    public static func latest(token: String, proxyURL: URL? = URL(string: "http://127.0.0.1:7897")) async throws -> GitHubRelease {
        let data = try await ReleaseRequest(url: GitHubUpdatePolicy.apiRoot.appendingPathComponent("releases/latest"),
                                            token: token, accept: "application/vnd.github+json", maximumBytes: 1024 * 1024, proxyURL: proxyURL).run()
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data), !release.draft, !release.prerelease else {
            throw UpdateError.invalidManifest
        }
        return release
    }

    public static func manifest(_ asset: GitHubRelease.Asset, token: String, proxyURL: URL? = URL(string: "http://127.0.0.1:7897")) async throws -> Data {
        guard asset.size > 0, asset.size <= 128 * 1024 else { throw UpdateError.invalidManifest }
        return try await ReleaseRequest(url: assetURL(asset.id), token: token, accept: "application/octet-stream", maximumBytes: 128 * 1024, proxyURL: proxyURL).run()
    }

    public static func archive(_ asset: GitHubRelease.Asset, token: String, destination: URL,
                               proxyURL: URL? = URL(string: "http://127.0.0.1:7897"),
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        guard asset.size > 0, asset.size <= 256 * 1024 * 1024 else { throw UpdateError.invalidDownload }
        _ = try await ReleaseRequest(url: assetURL(asset.id), token: token, accept: "application/octet-stream",
                                    maximumBytes: asset.size, proxyURL: proxyURL, destination: destination, progress: progress).run()
    }

    private static func assetURL(_ identity: Int64) -> URL {
        GitHubUpdatePolicy.apiRoot.appendingPathComponent("releases/assets/\(identity)")
    }
}

private final class ReleaseRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let token: String
    private let accept: String
    private let maximumBytes: Int64
    private let destination: URL?
    private let proxyURL: URL?
    private let progress: (@Sendable (Double) -> Void)?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var failure: Error?
    private var redirects = 0
    private let lock = NSLock()
    private var cancelled = false

    init(url: URL, token: String, accept: String, maximumBytes: Int64, proxyURL: URL?,
         destination: URL? = nil, progress: (@Sendable (Double) -> Void)? = nil) {
        self.url = url
        self.token = token
        self.accept = accept
        self.maximumBytes = maximumBytes
        self.destination = destination
        self.proxyURL = proxyURL
        self.progress = progress
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if cancelled { continuation.resume(throwing: UpdateError.cancelled); return }
                do {
                    if let destination {
                        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw UpdateError.invalidDownload }
                        handle = try FileHandle(forWritingTo: destination)
                    }
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 30
                    configuration.timeoutIntervalForResource = 600
                    configuration.httpCookieStorage = nil
                    configuration.urlCache = nil
                    if let proxyURL {
                        configuration.connectionProxyDictionary = [
                            kCFNetworkProxiesHTTPEnable as String: 1,
                            kCFNetworkProxiesHTTPProxy as String: proxyURL.host!,
                            kCFNetworkProxiesHTTPPort as String: proxyURL.port!,
                            kCFNetworkProxiesHTTPSEnable as String: 1,
                            kCFNetworkProxiesHTTPSProxy as String: proxyURL.host!,
                            kCFNetworkProxiesHTTPSPort as String: proxyURL.port!
                        ]
                    }
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    self.continuation = continuation
                    task = session.dataTask(with: request(for: url))
                    task?.resume()
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            self.task?.cancel()
            self.lock.unlock()
        }
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("ClipDune-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if GitHubUpdatePolicy.allowsAuthorization(url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 4, let target = newRequest.url, GitHubUpdatePolicy.allows(target) else {
            failure = UpdateError.untrustedRedirect
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request(for: target))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = response.url, GitHubUpdatePolicy.allows(url) else {
            failure = UpdateError.untrustedRedirect
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            failure = http.statusCode == 401 ? UpdateError.noAuthorization : http.statusCode == 404 ? UpdateError.noRelease : UpdateError.network(http.statusCode)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= maximumBytes else {
            failure = UpdateError.invalidDownload
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        received += Int64(chunk.count)
        guard received <= maximumBytes else { failure = UpdateError.invalidDownload; dataTask.cancel(); return }
        do {
            if let handle { try handle.write(contentsOf: chunk) }
            else { data.append(chunk) }
            progress?(Double(received) / Double(maximumBytes))
        } catch { failure = UpdateError.invalidDownload; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let completion = continuation
        continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        if let failure { completion?.resume(throwing: failure) }
        else if let error {
            let status = (error as NSError).code
            completion?.resume(throwing: status == NSURLErrorCancelled ? UpdateError.cancelled : UpdateError.network(status))
        } else { completion?.resume(returning: data) }
    }
}
