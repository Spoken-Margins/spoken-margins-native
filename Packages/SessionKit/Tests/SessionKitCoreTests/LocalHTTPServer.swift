import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A small real HTTP/1.1 server on 127.0.0.1 for tests that need actual sockets: ranges, dropped
/// connections, slow bodies. Every response closes its connection. Not a general server.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var path: String
        /// Header names lowercased.
        var headers: [String: String]
    }

    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Advertise the whole body, send only this many bytes, then drop the connection.
        var cutAfter: Int?
        /// After the cut, keep the connection open until the server stops, as a stalled server would.
        var stallAfterCut = false
        /// Seconds the connection stays open after the bytes are written and before the cut. A client
        /// that is handed the bytes and the close together (a busy Mac, #1882) may report the dropped
        /// connection before it has passed on what it already received; this gives it time to do both.
        var settleBeforeCut: TimeInterval = 0.2
    }

    /// Gets the request and how many requests for the same path came before it.
    typealias Handler = @Sendable (Request, Int) -> Reply

    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopped = false
    private var seen: [Request] = []
    private var perPath: [String: Int] = [:]
    private let release = DispatchSemaphore(value: 0)
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) throws {
        self.handler = handler
        signal(SIGPIPE, SIG_IGN)
        #if canImport(Darwin)
        let socketType = SOCK_STREAM
        #else
        let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, socketType, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: boundAddress.sin_port)
        listener = fd

        let thread = Thread { [self] in acceptLoop(fd) }
        thread.start()
    }

    deinit { stop() }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func requests(for path: String) -> [Request] { requests.filter { $0.path == path } }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let fd = listener
        lock.unlock()
        guard !wasStopped else { return }
        // Let any stalled connection finish, then wake the accept loop.
        for _ in 0..<16 { release.signal() }
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 { return }
            Thread { [self] in serve(connection) }.start()
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        guard let request = readRequest(connection) else { return }
        lock.lock()
        let index = perPath[request.path, default: 0]
        perPath[request.path] = index + 1
        seen.append(request)
        lock.unlock()

        let reply = handler(request, index)
        let reason = ["200": "OK", "206": "Partial Content", "404": "Not Found", "416": "Range Not Satisfiable", "500": "Internal Server Error", "503": "Service Unavailable"]["\(reply.status)"] ?? "Status"
        var head = "HTTP/1.1 \(reply.status) \(reason)\r\nConnection: close\r\nContent-Length: \(reply.body.count)\r\n"
        for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        send(connection, Data(head.utf8))
        send(connection, reply.cutAfter.map { reply.body.prefix($0) } ?? reply.body)
        if reply.cutAfter != nil {
            if reply.stallAfterCut { release.wait() } else { Thread.sleep(forTimeInterval: reply.settleBeforeCut) }
        }
    }

    private func readRequest(_ connection: Int32) -> Request? {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(connection, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            received.append(buffer, count: count)
            if received.count > 65_536 { return nil }
        }
        let text = String(decoding: received, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(path: String(parts[1]), headers: headers)
    }

    private func send(_ connection: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = write(connection, raw.baseAddress! + sent, raw.count - sent)
                if count <= 0 { return }
                sent += count
            }
        }
    }

    /// Serves `content` the way a file server does: the whole file, or the tail of it when the request
    /// asks for `Range: bytes=<n>-` (and `honoringRange` is true).
    static func file(_ content: Data, for request: Request, honoringRange: Bool = true) -> Reply {
        guard honoringRange, let range = request.headers["range"], range.hasPrefix("bytes="), range.hasSuffix("-"),
              let start = Int(range.dropFirst("bytes=".count).dropLast()) else {
            return Reply(body: content)
        }
        guard start < content.count else {
            return Reply(status: 416, headers: ["Content-Range": "bytes */\(content.count)"])
        }
        return Reply(
            status: 206,
            headers: ["Content-Range": "bytes \(start)-\(content.count - 1)/\(content.count)"],
            body: content.suffix(from: start)
        )
    }
}
