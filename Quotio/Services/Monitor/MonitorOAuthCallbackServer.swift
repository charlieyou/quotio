import Foundation
import Network

nonisolated final class MonitorOAuthCallbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: URL?
    private var timeoutWorkItem: DispatchWorkItem?
    private var expectedPath: String?
    private var boundPort: UInt16?

    func start(preferredPort: UInt16? = nil, expectedPath: String? = nil) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        if let preferredPort, let port = NWEndpoint.Port(rawValue: preferredPort) {
            listener = try NWListener(using: parameters, on: port)
        } else {
            listener = try NWListener(using: parameters, on: .any)
        }
        configureListener(listener, expectedPath: expectedPath)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            setStartContinuation(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        listener.cancel()
                        self?.completeStart(listener: listener, result: .failure(MonitorOAuthError.invalidResponse))
                        return
                    }
                    self?.completeStart(listener: listener, result: .success(port))
                case .waiting(let error):
                    listener.cancel()
                    self?.completeStart(listener: listener, result: .failure(error))
                case .failed(let error):
                    listener.cancel()
                    self?.completeStart(listener: listener, result: .failure(error))
                case .cancelled:
                    self?.completeStart(listener: listener, result: .failure(CancellationError()))
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "\(AppIdentity.bundleIdentifier).monitor-oauth"))
        }
    }

    private func configureListener(_ listener: NWListener, expectedPath: String?) {
        lock.lock()
        self.listener = listener
        self.expectedPath = expectedPath
        self.boundPort = nil
        lock.unlock()
    }

    private func setStartContinuation(_ continuation: CheckedContinuation<UInt16, Error>) {
        lock.lock()
        self.startContinuation = continuation
        lock.unlock()
    }

    private func completeStart(listener: NWListener, result: Result<UInt16, Error>) {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        if case .success(let port) = result {
            boundPort = port
        } else if self.listener === listener {
            self.listener = nil
        }
        lock.unlock()
        listener.stateUpdateHandler = nil
        switch result {
        case .success(let port):
            continuation?.resume(returning: port)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func waitForCallback(timeout: Duration = .seconds(180)) async throws -> URL {
        let components = timeout.components
        let seconds = max(0, Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let pendingCallback {
                    self.pendingCallback = nil
                    lock.unlock()
                    listener?.cancel()
                    listener = nil
                    continuation.resume(returning: pendingCallback)
                    return
                }
                callbackContinuation = continuation
                let workItem = DispatchWorkItem { [weak self] in
                    self?.completeCallback(error: MonitorOAuthError.expired)
                }
                timeoutWorkItem = workItem
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: workItem)
            }
        } onCancel: {
            completeCallback(error: CancellationError())
        }
    }

    func stop() {
        completeCallback(error: CancellationError())
    }

    private func completeCallback(url: URL? = nil, error: Error? = nil) {
        lock.lock()
        let continuation = callbackContinuation
        callbackContinuation = nil
        let timeoutWorkItem = timeoutWorkItem
        self.timeoutWorkItem = nil
        if continuation == nil, let url {
            pendingCallback = url
        }
        let listener = listener
        self.listener = nil
        lock.unlock()
        timeoutWorkItem?.cancel()
        listener?.cancel()
        if let url, let continuation {
            continuation.resume(returning: url)
        } else if let error, let continuation {
            continuation.resume(throwing: error)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "\(AppIdentity.bundleIdentifier).monitor-oauth.connection"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self,
                  let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            lock.lock()
            let port = boundPort
            let expectedPath = expectedPath
            lock.unlock()

            let target = String(parts[1])
            let base = port.map { "http://localhost:\($0)" } ?? "http://localhost"
            guard let url = URL(string: base + target) else {
                connection.cancel()
                return
            }

            if let expectedPath, url.path != expectedPath {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(notFound.utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            let body = "<html><body><h2>Authentication complete</h2><p>You can return to Quotio.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

            completeCallback(url: url)
        }
    }
}
