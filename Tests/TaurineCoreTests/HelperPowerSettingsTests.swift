import Foundation
import XCTest
@testable import TaurineCore
@testable import TaurineShared

@MainActor
final class FakeHelperProxy: HelperProxy {
    var reportedVersion = HelperVersion.current
    var disabled = false
    var failure: HelperFailure?
    var unavailable = false
    var hangs = false
    var calls: [String] = []

    func version() async throws -> Int {
        self.calls.append("version")
        if self.unavailable { throw PowerError.helperUnavailable }
        if self.hangs { try await Task.sleep(for: .seconds(60)) }
        return self.reportedVersion
    }

    func sleepIsDisabled() async throws -> Bool {
        self.calls.append("read")
        if let failure { throw failure.nsError }
        return self.disabled
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        self.calls.append("write:\(disabled)")
        if let failure { throw failure.nsError }
        self.disabled = disabled
    }
}

@MainActor
final class HelperPowerSettingsTests: XCTestCase {
    func testUnresponsiveHelperTimesOutAsUnavailable() async {
        let proxy = FakeHelperProxy()
        proxy.hangs = true
        let settings = HelperPowerSettings(proxy: proxy, timeout: .milliseconds(50))
        let started = ContinuousClock.now
        do {
            _ = try await settings.sleepIsDisabled()
            XCTFail("expected helperUnavailable")
        } catch PowerError.helperUnavailable {
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testWritesVerifyVersionFirst() async throws {
        let proxy = FakeHelperProxy()
        let settings = HelperPowerSettings(proxy: proxy)
        try await settings.setSleepDisabled(true)
        XCTAssertEqual(proxy.calls, ["version", "write:true"])
        let disabled = try await settings.sleepIsDisabled()
        XCTAssertTrue(disabled)
    }

    func testVersionMismatchIsOutdated() async {
        let proxy = FakeHelperProxy()
        proxy.reportedVersion = HelperVersion.current + 1
        let settings = HelperPowerSettings(proxy: proxy)
        do {
            _ = try await settings.sleepIsDisabled()
            XCTFail("expected helperOutdated")
        } catch PowerError.helperOutdated {
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(proxy.calls, ["version"])
    }

    func testHelperFailuresMapToPowerErrors() async {
        let cases: [(HelperError, (PowerError) -> Bool)] = [
            (.busy, { if case .commandFailed = $0 { return true } else { return false } }),
            (.unreadableState, { if case .unreadableState = $0 { return true } else { return false } }),
            (.verificationFailed, { if case .verificationFailed = $0 { return true } else { return false } }),
            (.commandFailed, { if case let .commandFailed(text) = $0 { return text == "boom" } else { return false } }),
            (.unauthorized, { if case .commandFailed = $0 { return true } else { return false } }),
        ]
        for (code, matches) in cases {
            let proxy = FakeHelperProxy()
            proxy.failure = HelperFailure(code: code, message: "boom")
            let settings = HelperPowerSettings(proxy: proxy)
            do {
                try await settings.setSleepDisabled(true)
                XCTFail("expected error for \(code)")
            } catch let error as PowerError {
                XCTAssertTrue(matches(error), "\(code) mapped to \(error)")
            } catch { XCTFail("unexpected \(error)") }
        }
    }

    func testUnavailableHelperPropagates() async {
        let proxy = FakeHelperProxy()
        proxy.unavailable = true
        let settings = HelperPowerSettings(proxy: proxy)
        do {
            _ = try await settings.sleepIsDisabled()
            XCTFail("expected helperUnavailable")
        } catch PowerError.helperUnavailable {
        } catch { XCTFail("unexpected \(error)") }
    }
}
