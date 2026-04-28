import Combine
import Foundation

/// Fetches a `StatusReport` from status.claude.com.
protocol StatusPollerClient {
    func fetch() async -> StatusReport?
}

/// Live network client. Tests inject a stub.
struct LiveStatusPollerClient: StatusPollerClient {
    let session: URLSession
    let url: URL

    init(
        session: URLSession = .shared,
        url: URL = LiveStatusPollerClient.defaultURL()
    ) {
        self.session = session
        self.url = url
    }

    /// Production endpoint, with a `CCUS_STATUS_URL` env-var override for
    /// development / outage simulation (`file:///tmp/...` or
    /// `http://localhost:8080/...`).
    static func defaultURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["CCUS_STATUS_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://status.claude.com/api/v2/summary.json")!
    }

    func fetch() async -> StatusReport? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await session.data(for: req) else {
            return nil
        }
        // For HTTP responses require 2xx. file:// (used for outage
        // simulation) doesn't yield an HTTPURLResponse; accept any data
        // we got.
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        return StatusReport.parse(summaryJSON: data)
    }
}

/// Polls status.claude.com on a coarse cadence (5 min default). The status
/// page rarely changes; we just want to surface outages, not track them
/// at high resolution.
@MainActor
final class StatusPoller: ObservableObject {
    @Published private(set) var report: StatusReport?

    private let client: StatusPollerClient
    private let interval: TimeInterval
    private var timer: Timer?
    private var isRunning = false

    init(client: StatusPollerClient, interval: TimeInterval = 5 * 60) {
        self.client = client
        self.interval = interval
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in await self.tick() }
        scheduleTimer()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// For tests — single tick without timer.
    func tickForTest() async { await tick() }

    /// User/system-initiated immediate refresh (e.g. on wake from sleep).
    func refreshNow() async { await tick() }

    private func tick() async {
        if let r = await client.fetch() {
            report = r
        }
        // On nil (network error / 5xx) keep the previous report rather than
        // flapping the UI.
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                await self.tick()
                self.scheduleTimer()
            }
        }
    }
}
