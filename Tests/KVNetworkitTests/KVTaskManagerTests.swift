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

    func testCompleteRemovesTracking() {
        let manager = KVTaskManager()
        let task = Task<Void, Error> {}
        manager.register(task, for: "job")
        manager.complete(id: "job")
        XCTAssertEqual(manager.status(for: "job"), .unknown)
        XCTAssertEqual(manager.activeTaskCount, 0)
    }
}
