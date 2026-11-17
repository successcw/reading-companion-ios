import Combine
import Foundation
import Network

final class LocalHTTPServer: ObservableObject {
    private let queue = DispatchQueue(label: "com.cg.readingcompanion.http")
    private var listener: NWListener?
    private(set) var port: UInt16 = 8787
    @Published private(set) var isRunning = false

    var onContext: ((ReadingContext) -> Void)?
    var token: String = "change-me"

    func start(port: UInt16 = 8787) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    DispatchQueue.main.async { self.isRunning = true }
                case .failed, .cancelled:
                    DispatchQueue.main.async { self.isRunning = false }
                default:
                    break
                }
            }
            self.port = port
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    buffer.append(data)
                }
                if let request = Self.parse(buffer) {
                    self.respond(request, on: connection)
                    return
                }
                if buffer.count > 1_048_576 {
                    self.send(status: 413, body: ["error": "payload too large"], on: connection)
                    return
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                receive()
            }
        }
        receive()
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func parse(_ data: Data) -> Request? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + length else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return Request(method: method, path: path, headers: headers, body: body)
    }

    private func respond(_ request: Request, on connection: NWConnection) {
        if !token.isEmpty,
           request.headers["x-companion-token"] != token {
            send(status: 401, body: ["error": "invalid token"], on: connection)
            return
        }
        guard request.method == "POST", request.path == "/context" else {
            if request.method == "GET", request.path == "/health" {
                send(status: 200, body: ["ok": true], on: connection)
            } else {
                send(status: 404, body: ["error": "not found"], on: connection)
            }
            return
        }
        do {
            let context = try JSONDecoder().decode(ReadingContext.self, from: request.body)
            DispatchQueue.main.async { [weak self] in
                self?.onContext?(context)
            }
            send(status: 200, body: ["ok": true], on: connection)
        } catch {
            send(status: 400, body: ["error": "invalid json"], on: connection)
        }
    }

    private func send(status: Int, body: [String: Any], on connection: NWConnection) {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        var response = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        response.append(Data("Content-Type: application/json\r\n".utf8))
        response.append(Data("Content-Length: \(payload.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
