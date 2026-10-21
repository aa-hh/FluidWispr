import Foundation

enum LocalAPI {
    static let defaultPort: UInt16 = 47_733
    static let maxRequestBytes = 500 * 1024 * 1024

    struct Configuration {
        let enabled: Bool
        let port: UInt16

        static var current: Configuration {
            let defaults = UserDefaults.standard
            let enabled: Bool
            if defaults.object(forKey: "LocalAPIEnabled") == nil {
                enabled = false
            } else {
                enabled = defaults.bool(forKey: "LocalAPIEnabled")
            }

            let rawPort = defaults.integer(forKey: "LocalAPIPort")
            let port = rawPort > 0 && rawPort <= Int(UInt16.max) ? UInt16(rawPort) : LocalAPI.defaultPort
            return Configuration(enabled: enabled, port: port)
        }
    }

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data

        init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    struct ErrorBody: Encodable {
        let error: String
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
        do {
            let body = try Self.encoder.encode(value)
            return Response(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        } catch {
            return Self.error("Failed to encode response.", status: 500)
        }
    }

    static func empty(status: Int = 204) -> Response {
        Response(status: status)
    }

    static func error(_ message: String, status: Int) -> Response {
        let body = (try? Self.encoder.encode(ErrorBody(error: message))) ?? Data()
        return Response(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    /// The listener only accepts loopback peers, but a web page in the user's browser is also a
    /// loopback peer. Refuse what only a browser sends: a Host naming another site (DNS
    /// rebinding), any Origin header, and a POST body type a page can send without the
    /// browser asking first (text/plain, form data, or no type at all).
    static func browserRejection(for request: Request, port: UInt16) -> Response? {
        if let host = request.headers["host"]?.lowercased(),
           !["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host)
        {
            return Self.error("Host must be 127.0.0.1, localhost or [::1] with port \(port).", status: 403)
        }
        if request.headers["origin"] != nil {
            return Self.error("Requests from web pages are not accepted.", status: 403)
        }
        if request.method == "POST" {
            let mediaType = request.headers["content-type"]?
                .split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces)
                .lowercased() ?? ""
            if ["", "text/plain", "application/x-www-form-urlencoded", "multipart/form-data"].contains(mediaType) {
                return Self.error("Send a Content-Type such as application/json or audio/wav.", status: 415)
            }
        }
        return nil
    }

    static func boundedLimit(from request: Request, default defaultValue: Int = 100, maximum: Int = 1000) -> Int {
        guard let raw = request.query["limit"], let value = Int(raw) else {
            return defaultValue
        }
        return max(1, min(value, maximum))
    }
}

@MainActor
protocol LocalAPIRouteHandler {
    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response
}
