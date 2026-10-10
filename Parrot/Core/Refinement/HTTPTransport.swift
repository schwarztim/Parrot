import Foundation

/// Sends one HTTP request. Every language model client goes through this,
/// so tests hand in canned replies and never touch the network. [LLM]
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real network, through `URLSession.shared`.
struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RefinementError.invalidResponse
        }
        return (data, http)
    }
}
