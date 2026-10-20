import Foundation

/// Answers every request to `captureHost` with 200 and records its body, so a test sees the
/// webhook cards a run posts without a network. Registered globally, which `URLSession.shared`
/// consults.
final class WebhookCapture: URLProtocol, @unchecked Sendable {
    static let captureHost = "hooks.example.test"
    static let webhookURL = "https://\(captureHost)/incoming"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String] = []

    /// The request bodies seen since `start()`.
    static var posted: [String] { lock.withLock { bodies } }

    static func start() {
        lock.withLock { bodies = [] }
        URLProtocol.registerClass(WebhookCapture.self)
    }

    static func stop() { URLProtocol.unregisterClass(WebhookCapture.self) }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == captureHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            stream.close()
            data = collected
        }
        let body = String(decoding: data ?? Data(), as: UTF8.self)
        Self.lock.withLock { Self.bodies.append(body) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
