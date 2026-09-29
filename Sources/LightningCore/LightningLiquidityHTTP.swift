import Foundation

/// The provider's HTTPS LSPS1 adapter. Only explicit requests create an unpaid
/// order; no wallet keys, payment secrets or payment authority cross this API.
public struct LightningLiquidityHTTP: Sendable {
    private let base: URL
    public init(base: URL) throws {
        guard base.scheme == "https", base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else { throw LightningError.invalidMessage }
        self.base = base
    }
    public func info() async throws -> LightningLiquidity.Info {
        try LightningLiquidity.decode(LightningLiquidity.Info.self, from: await request("get_info"))
    }
    public func order(_ purchase: LightningLiquidity.Purchase, nodeID: Data) async throws -> LightningLiquidity.Order {
        _ = try ChannelKeys.point(nodeID)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        guard var object = try JSONSerialization.jsonObject(with: encoder.encode(purchase)) as? [String: Any] else { throw LightningError.invalidMessage }
        object["public_key"] = nodeID.hex
        let body = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        return try LightningLiquidity.decode(LightningLiquidity.Order.self, from: await request("create_order", body: body))
    }
    public func status(id: String) async throws -> LightningLiquidity.Order {
        guard !id.isEmpty, id.utf8.count <= 64 else { throw LightningError.invalidMessage }
        return try LightningLiquidity.decode(LightningLiquidity.Order.self, from: await request("get_order", id: id))
    }
    private func request(_ method: String, body: Data? = nil, id: String? = nil) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(method), resolvingAgainstBaseURL: false)!
        if let id { components.queryItems = [.init(name: "order_id", value: id)] }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        let http = try validateResponse(response)
        return try await readBody(bytes, response: http)
    }
    private func validateResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse, http.url?.host == base.host else { throw LightningError.invalidMessage }
        return http
    }
    private func readBody(_ bytes: URLSession.AsyncBytes, response: HTTPURLResponse) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < 32_768 else { throw LightningError.invalidMessage }
            data.append(byte)
        }
        try validateStatus(response.statusCode)
        return data
    }
    private func validateStatus(_ status: Int) throws {
        guard status == 200 else {
            throw LightningLiquidityError.provider("Channel service returned HTTP \(status). No fee was paid.")
        }
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
