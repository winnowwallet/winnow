@testable import WinnowApp
import Network
import WebKit
import XCTest

@MainActor
private final class PaperHTTPProbe {
    let listener: NWListener
    var connections: [NWConnection] = []
    var count = 0
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
        for _ in 0..<100 {
            if case .ready = listener.state, let port = listener.port, port.rawValue != 0 {
                return port.rawValue
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "PaperHTTPProbe", code: 1)
    }
    private func accept(_ connection: NWConnection) {
        count += 1
        connections.append(connection)
        connection.start(queue: .main)
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/css\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}

@MainActor
final class OfflinePaperTests: XCTestCase {
    func testBundledPaperBlocksHTTPSubresourcesWithPositiveControl() async throws {
        let server = try PaperHTTPProbe()
        defer { server.stop() }
        let port = try await server.start()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paper.html")
        let origin = URL(string: "http://localhost:\(port)/")!
        let html = "<html><head><title>Offline proof</title><link rel='stylesheet' href='\(origin)style.css'></head><body>Local paper</body></html>"
        try html.write(to: url, atomically: true, encoding: .utf8)

        let control = WKWebView()
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow })
        control.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        window.addSubview(control)
        defer { control.removeFromSuperview() }
        control.loadFileURL(url, allowingReadAccessTo: directory)
        try await loaded(control)
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(server.count, 0, "The unprotected WebKit positive control must reach the HTTP probe")
        let previous = server.count
        control.stopLoading()

        let paper = BundledPageView(url: url) { _ in XCTFail("No user activated an external link") }
        let coordinator = paper.makeCoordinator()
        let protected = paper.makeWebView(coordinator: coordinator)
        protected.frame = control.frame
        window.addSubview(protected)
        defer { protected.removeFromSuperview() }
        try await loaded(protected)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(server.count, previous, "Offline paper loaded an HTTP subresource outside wallet routing")
        XCTAssertFalse(protected.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        protected.stopLoading()
        withExtendedLifetime(coordinator) {}
    }

    /// WebKit's first content process on a loaded hosted runner has taken
    /// longer than ten seconds to come up; a minute is the allowance.
    private func loaded(_ view: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if view.title == "Offline proof", !view.isLoading { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The local HTML paper did not finish loading within a minute")
    }
}
