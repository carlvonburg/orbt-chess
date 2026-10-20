import Foundation
import OpeningCoreRust

/// Sends the requests the core describes and hands back what the server answered. The core
/// builds every request (URL, headers, body) and reads every answer.
enum HTTP {
    /// Nil when there was no answer (offline, timeout, a URL the system rejects).
    static func send(_ request: HttpRequest) async -> HttpResponse? {
        guard let url = URL(string: request.url) else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = switch request.method {
        case .get: "GET"
        case .post: "POST"
        case .delete: "DELETE"
        }
        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }
        if !request.body.isEmpty { urlRequest.httpBody = request.body }
        if let timeout = request.timeoutSecs { urlRequest.timeoutInterval = TimeInterval(timeout) }
        guard let (data, response) = try? await URLSession.shared.data(for: urlRequest),
              let http = response as? HTTPURLResponse else { return nil }
        let headers = http.allHeaderFields.compactMap { name, value in
            (name as? String).map { Header(name: $0, value: "\(value)") }
        }
        return HttpResponse(status: UInt16(http.statusCode), headers: headers, body: data)
    }
}
