import Foundation
@testable import PutAutomation
import Testing

@MainActor
@Suite("Debouncer")
struct DebouncerTests {
    @Test
    func burstCollapsesToSingleFire() async throws {
        let debouncer = Debouncer(interval: 0.05)
        let counter = Counter()
        for _ in 0..<10 {
            debouncer.schedule {
                await counter.increment()
            }
            // Keep the burst tight so each schedule cancels the previous.
            try await Task.sleep(for: .milliseconds(5))
        }
        // Wait well past the debounce window.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await counter.value == 1)
    }

    @Test
    func cancelPreventsFire() async throws {
        let debouncer = Debouncer(interval: 0.05)
        let counter = Counter()
        debouncer.schedule {
            await counter.increment()
        }
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await counter.value == 0)
    }

    @Test
    func separateSchedulesBeyondIntervalFireIndividually() async throws {
        let debouncer = Debouncer(interval: 0.02)
        let counter = Counter()
        debouncer.schedule { await counter.increment() }
        try await Task.sleep(for: .milliseconds(60))
        debouncer.schedule { await counter.increment() }
        try await Task.sleep(for: .milliseconds(60))
        #expect(await counter.value == 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}
