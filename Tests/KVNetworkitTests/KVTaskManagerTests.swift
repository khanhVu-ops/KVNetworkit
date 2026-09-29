//
//  KVTaskManagerTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

final class KVTaskManagerTests: XCTestCase {

    func testCancelActuallyCancelsTheTask() async {
        let manager = KVTaskManager()

        let task = Task<Int, Error> {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return 42
        }
        manager.register(task, for: "job")
        XCTAssertEqual(manager.status(for: "job"), .inProgress)

        manager.cancel(id: "job")
        XCTAssertEqual(manager.status(for: "job"), .canceled)

        do {
            _ = try await task.value
            XCTFail("Task should have been canceled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancelAllDoesNotDeadlockAndCancelsEverything() async {
        let manager = KVTaskManager()
        var tasks: [Task<Void, Error>] = []

        for index in 0..<10 {
            let task = Task<Void, Error> {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            tasks.append(task)
            manager.register(task, for: "job-\(index)")
        }
        XCTAssertEqual(manager.activeTaskCount, 10)

        manager.cancelAll()
        XCTAssertEqual(manager.activeTaskCount, 0)

        for task in tasks {
            do {
                try await task.value
                XCTFail("Task should have been canceled")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testRegistrationIsRejectedWhileTheIdIsInProgress() {
        let manager = KVTaskManager()
        let first = KVTaskRegistration(id: "job")
        XCTAssertTrue(manager.register(first) { Task<Void, Error> { try await Task.sleep(nanoseconds: 5_000_000_000) } })

        var madeSecondTask = false
        let accepted = manager.register(KVTaskRegistration(id: "job")) { () -> Task<Void, Error> in
            madeSecondTask = true
            return Task {}
        }
        XCTAssertFalse(accepted)
        XCTAssertFalse(madeSecondTask, "A rejected request must not start any work")
        manager.cancelAll()
    }

    func testCompletingAnOldRegistrationKeepsTheNewerOne() {
        let manager = KVTaskManager()
        let old = KVTaskRegistration(id: "job")
        XCTAssertTrue(manager.register(old) { Task<Void, Error> {} })

        manager.cancel(id: "job")
        let newer = KVTaskRegistration(id: "job")
        XCTAssertTrue(manager.register(newer) { Task<Void, Error> {} })

        manager.complete(old)
        XCTAssertEqual(manager.status(for: "job"), .inProgress)
        XCTAssertEqual(manager.activeTaskCount, 1)

        manager.complete(newer)
        XCTAssertEqual(manager.status(for: "job"), .unknown)
        XCTAssertEqual(manager.activeTaskCount, 0)
    }

    func testCompletingACanceledRegistrationClearsTheCanceledStatus() {
        let manager = KVTaskManager()
        let registration = KVTaskRegistration(id: "job")
        XCTAssertTrue(manager.register(registration) { Task<Void, Error> {} })

        manager.cancel(id: "job")
        XCTAssertEqual(manager.status(for: "job"), .canceled)
        manager.complete(registration)
        XCTAssertEqual(manager.status(for: "job"), .unknown)
    }

    func testCompleteRemovesTracking() {
        let manager = KVTaskManager()
        let task = Task<Void, Error> {}
        manager.register(task, for: "job")
        manager.complete(id: "job")
        XCTAssertEqual(manager.status(for: "job"), .unknown)
        XCTAssertEqual(manager.activeTaskCount, 0)
    }
}
