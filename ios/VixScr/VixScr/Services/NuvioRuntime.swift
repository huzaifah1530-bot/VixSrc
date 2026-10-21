import Foundation
import JavaScriptCore

/// Runs the bundled Nuvio providers (`nuvio-bundle.js`, built by
/// providers/build.mjs) in JavaScriptCore. The bundle polyfills fetch, URL,
/// Buffer, timers and `require` on top of a small host bridge defined here;
/// the desktop app runs the same bundle in a Node `vm`, so a provider that
/// passes `npm test` in providers/ behaves the same on both.
///
/// Every JavaScript call happens on `queue`. Network requests run on
/// URLSession and hop back to `queue` before calling into JS.
final class NuvioRuntime: @unchecked Sendable {
    static let shared = NuvioRuntime()

    struct Stream: Decodable, Sendable {
        struct Subtitle: Decodable, Sendable {
            let url: String
            let name: String
            let language: String
            let headers: [String: String]
        }
        let name: String
        let title: String
        let url: String
        let quality: String
        let size: String
        let headers: [String: String]
        let subtitles: [Subtitle]
    }

    enum RuntimeError: LocalizedError {
        case unavailable(String)
        case provider(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let m), .provider(let m): return m
            }
        }
    }

    private let queue = DispatchQueue(label: "vela.nuvio.runtime")
    // Everything below is only touched on `queue`.
    private var context: JSContext?
    private var api: JSValue?
    private var loadError: String?
    private var fetchCallbacks: [Int: JSValue] = [:]
    private var timerCallbacks: [Int: JSValue] = [:]
    private var nextId = 1

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    private init() {}

    /// Runs one provider. Throws on provider errors; an empty array means
    /// the provider ran but found nothing.
    func streams(for route: NuvioRoute) async throws -> [Stream] {
        let json: String = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.run(route) { result in continuation.resume(with: result) }
            }
        }
        return (try? JSONDecoder().decode([Stream].self, from: Data(json.utf8))) ?? []
    }

    // MARK: - JavaScript (queue only)

    private func run(_ route: NuvioRoute, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        guard let api = loadedAPI() else {
            completion(.failure(RuntimeError.unavailable(loadError ?? "Provider runtime unavailable")))
            return
        }
        let callback: @convention(block) (JSValue, JSValue) -> Void = { err, value in
            if !err.isNull && !err.isUndefined {
                completion(.failure(RuntimeError.provider(err.toString() ?? "Provider failed")))
            } else {
                completion(.success(value.toString() ?? "[]"))
            }
        }
        let args: [Any] = [
            route.provider.id,
            route.tmdbId,
            route.mediaType,
            route.season.map { $0 as Any } ?? NSNull(),
            route.episode.map { $0 as Any } ?? NSNull(),
            45_000,
            unsafeBitCast(callback, to: AnyObject.self)
        ]
        api.invokeMethod("run", withArguments: args)
    }

    private func loadedAPI() -> JSValue? {
        if let api { return api }
        if loadError != nil { return nil }
        guard let url = Bundle.main.url(forResource: "nuvio-bundle", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "nuvio-bundle.js is missing from the app bundle"
            return nil
        }
        guard let context = JSContext() else {
            loadError = "JavaScriptCore is unavailable"
            return nil
        }
        context.name = "Vela providers"
        context.exceptionHandler = { _, exception in
            #if DEBUG
            print("[nuvio] JS exception: \(exception?.toString() ?? "?")")
            #endif
        }
        installHost(in: context)
        context.evaluateScript(source, withSourceURL: url)
        let api = context.objectForKeyedSubscript("__velaNuvio")
        guard let api, !api.isUndefined, !api.isNull else {
            loadError = "Provider bundle failed to load"
            return nil
        }
        self.context = context
        self.api = api
        return api
    }

    private func installHost(in context: JSContext) {
        let host = JSValue(newObjectIn: context)!

        let fetch: @convention(block) (String, JSValue) -> Void = { [unowned self] raw, callback in
            let id = self.nextId
            self.nextId += 1
            self.fetchCallbacks[id] = callback
            let session = self.session
            Task.detached {
                let (error, response) = await NuvioRuntime.perform(raw, session: session)
                self.queue.async {
                    guard let cb = self.fetchCallbacks.removeValue(forKey: id) else { return }
                    cb.call(withArguments: [error.map { $0 as Any } ?? NSNull(), response.map { $0 as Any } ?? NSNull()])
                }
            }
        }
        let setTimer: @convention(block) (JSValue, Double) -> Int = { [unowned self] fn, ms in
            let id = self.nextId
            self.nextId += 1
            self.timerCallbacks[id] = fn
            let delay = max(0, ms.isFinite ? ms : 0) / 1000
            self.queue.asyncAfter(deadline: .now() + delay) {
                guard let fn = self.timerCallbacks.removeValue(forKey: id) else { return }
                fn.call(withArguments: [])
            }
            return id
        }
        let clearTimer: @convention(block) (JSValue) -> Void = { [unowned self] id in
            guard id.isNumber else { return }
            self.timerCallbacks.removeValue(forKey: Int(id.toInt32()))
        }
        let log: @convention(block) (String, String) -> Void = { level, message in
            #if DEBUG
            print("[nuvio:\(level)] \(message.prefix(400))")
            #endif
        }
        // Blocks must cross as ObjC objects, not boxed Swift closures.
        host.setObject(unsafeBitCast(fetch, to: AnyObject.self), forKeyedSubscript: "fetch" as NSString)
        host.setObject(unsafeBitCast(setTimer, to: AnyObject.self), forKeyedSubscript: "setTimeout" as NSString)
        host.setObject(unsafeBitCast(clearTimer, to: AnyObject.self), forKeyedSubscript: "clearTimeout" as NSString)
        host.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
        context.setObject(host, forKeyedSubscript: "__velaHost" as NSString)
    }

    // MARK: - Networking

    private struct HostRequest: Decodable {
        let url: String
        let method: String?
        let headers: [[String]]?
        let body: String?
        let bodyBase64: String?
        let redirect: String?
        let timeout: Double?
    }

    /// Stops URLSession following redirects so `redirect: 'manual'` sees the 3xx.
    private final class ManualRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    /// Headers URLSession manages itself (and decompression depends on).
    private static let skippedHeaders: Set<String> = ["accept-encoding", "connection", "host", "content-length", "keep-alive"]

    /// Returns (error, responseJson) in the shape the runtime expects.
    private static func perform(_ raw: String, session: URLSession) async -> (String?, String?) {
        guard let req = try? JSONDecoder().decode(HostRequest.self, from: Data(raw.utf8)),
              let url = URL(string: req.url), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return ("Invalid request", nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = req.method ?? "GET"
        request.timeoutInterval = min(max((req.timeout ?? 20_000) / 1000, 1), 60)
        request.httpShouldHandleCookies = false
        for pair in req.headers ?? [] where pair.count == 2 {
            if skippedHeaders.contains(pair[0].lowercased()) { continue }
            if request.value(forHTTPHeaderField: pair[0]) == nil {
                request.setValue(pair[1], forHTTPHeaderField: pair[0])
            } else {
                request.addValue(pair[1], forHTTPHeaderField: pair[0])
            }
        }
        if let b64 = req.bodyBase64 {
            request.httpBody = Data(base64Encoded: b64)
        } else if let body = req.body {
            request.httpBody = Data(body.utf8)
        }

        do {
            let manual = req.redirect == "manual"
            let (data, response) = manual
                ? try await session.data(for: request, delegate: ManualRedirect())
                : try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return ("Not an HTTP response", nil) }
            var pairs: [[String]] = []
            for (key, value) in http.allHeaderFields {
                let k = String(describing: key).lowercased()
                if k == "set-cookie" { continue }
                pairs.append([k, String(describing: value)])
            }
            // allHeaderFields folds Set-Cookie together; rebuild one per cookie.
            var fields: [String: String] = [:]
            for (key, value) in http.allHeaderFields { fields[String(describing: key)] = String(describing: value) }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: http.url ?? url) {
                pairs.append(["set-cookie", "\(cookie.name)=\(cookie.value); Path=\(cookie.path)"])
            }
            var out: [String: Any] = [
                "status": http.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                "url": (http.url ?? url).absoluteString,
                "redirected": (http.url ?? url) != url,
                "headers": pairs
            ]
            if let text = String(data: data, encoding: .utf8) {
                out["text"] = text
            } else {
                out["base64"] = data.base64EncodedString()
            }
            guard let json = try? JSONSerialization.data(withJSONObject: out),
                  let string = String(data: json, encoding: .utf8) else { return ("Bad response", nil) }
            return (nil, string)
        } catch {
            return (error.localizedDescription, nil)
        }
    }
}
