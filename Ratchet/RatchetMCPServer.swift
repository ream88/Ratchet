//
//  RatchetMCPServer.swift
//  Ratchet
//
//  Hosts an in-process MCP server (Streamable HTTP) so a running coding agent
//  (Claude Code, Codex, OpenCode) can pull the repository's review comments.
//
//  The MCP Swift SDK implements the protocol and routing but not the socket, so a small
//  NWListener bridges raw HTTP/1.1 on 127.0.0.1 into the SDK's StatelessHTTPServerTransport.
//

import Foundation
import Network
import Combine
import AppKit
import MCP

@MainActor
final class RatchetMCPServer: ObservableObject {
    /// Fixed loopback port. Agents connect to http://127.0.0.1:<port>/mcp
    static let port: UInt16 = 8765

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    let repositoryPath: String
    var endpoint: String { "http://127.0.0.1:\(Self.port)/mcp" }

    /// The selected branch's commits — the MCP tool only serves comments on these.
    var currentBranchCommits: [GitCommit] = []

    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ratchet.mcp", qos: .userInitiated)

    init(repositoryPath: String) {
        self.repositoryPath = repositoryPath
    }

    /// Copies the Claude Code registration command for this server to the clipboard.
    func copyRegistrationCommand() {
        let command = "claude mcp add --transport http ratchet \(endpoint)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    // MARK: Lifecycle

    func toggle() {
        if isRunning { stop() } else { Task { await start() } }
    }

    /// Markdown of the current branch's review comments (what the MCP tool returns).
    func reviewMarkdown() -> String {
        let shas = Set(currentBranchCommits.map(\.id))
        return ExportService.markdownForAllComments(
            repositoryPath: repositoryPath,
            commits: currentBranchCommits,
            store: .shared,
            limitToCommits: shas.isEmpty ? nil : shas
        )
    }

    func start() async {
        guard !isRunning else { return }
        lastError = nil

        let server = Server(
            name: "Ratchet",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(
                    name: "list_review_comments",
                    description: "All review comments recorded in Ratchet for this repository, "
                        + "grouped by commit and file, as Markdown. Use these to address the reviewer's notes.",
                    inputSchema: .object(["type": .string("object"), "properties": .object([:])])
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard params.name == "list_review_comments" else {
                return CallTool.Result(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            // Hop to the main actor to read the (main-actor) review store.
            let markdown = await MainActor.run { self?.reviewMarkdown() ?? "" }
            return CallTool.Result(content: [.text(text: markdown, annotations: nil, _meta: nil)])
        }

        let transport = StatelessHTTPServerTransport()
        do {
            try await server.start(transport: transport)
        } catch {
            lastError = error.localizedDescription
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback   // 127.0.0.1 only
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { connection in
                Self.handle(connection, transport: transport, queue: self.queue)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor in self?.lastError = error.localizedDescription; self?.stop() }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
            return
        }

        self.server = server
        self.transport = transport
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        server = nil
        transport = nil
        isRunning = false
    }

    // MARK: HTTP bridge (runs off the main actor on `queue`)

    private nonisolated static func handle(
        _ connection: NWConnection,
        transport: StatelessHTTPServerTransport,
        queue: DispatchQueue
    ) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), transport: transport)
    }

    private nonisolated static func receive(
        _ connection: NWConnection,
        buffer: Data,
        transport: StatelessHTTPServerTransport
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }

            if let (request, _) = parseRequest(buffer) {
                Task {
                    let response = await transport.handleRequest(request)
                    send(response, on: connection)
                }
            } else if error == nil && !isComplete {
                receive(connection, buffer: buffer, transport: transport)   // need more bytes
            } else {
                connection.cancel()
            }
        }
    }

    /// Parses a complete HTTP/1.1 request from the buffer, or nil if more bytes are needed.
    private nonisolated static func parseRequest(_ data: Data) -> (HTTPRequest, Int)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let header = String(data: data.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) else { return nil }

        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = headers.first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.value) } ?? 0
        guard data.count - bodyStart >= contentLength else { return nil }   // body incomplete

        let body = contentLength > 0 ? data.subdata(in: bodyStart..<(bodyStart + contentLength)) : nil
        let request = HTTPRequest(method: method, headers: headers, body: body, path: path)
        return (request, bodyStart + contentLength)
    }

    private nonisolated static func send(_ response: HTTPResponse, on connection: NWConnection) {
        if case let .stream(stream, headers) = response {
            sendStream(stream, headers: headers, on: connection)
        } else {
            sendBuffered(status: response.statusCode, headers: response.headers,
                         body: response.bodyData, on: connection)
        }
    }

    private nonisolated static func sendBuffered(
        status: Int, headers: [String: String], body: Data?, on connection: NWConnection
    ) {
        var headers = headers
        headers["Content-Length"] = String(body?.count ?? 0)
        headers["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        if let body { out.append(body) }
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private nonisolated static func sendStream(
        _ stream: AsyncThrowingStream<Data, Swift.Error>, headers: [String: String], on connection: NWConnection
    ) {
        var headers = headers
        headers["Connection"] = "keep-alive"
        var head = "HTTP/1.1 200 OK\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        Task {
            do {
                for try await chunk in stream {
                    connection.send(content: chunk, completion: .contentProcessed { _ in })
                }
            } catch {}
            connection.cancel()
        }
    }

    private nonisolated static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        default: return "Status"
        }
    }
}
