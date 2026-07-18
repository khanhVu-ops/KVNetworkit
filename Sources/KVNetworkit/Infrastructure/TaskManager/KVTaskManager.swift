//
//  KVTaskManager.swift
//  KVNetworkit
//

import Foundation

/// Default implementation of ``KVTaskManagerProtocol``.
///
/// Tracks in-flight tasks by identifier so they can be canceled individually
/// or all at once. Entries are removed when a request completes, so the
/// manager never grows unbounded.
public final class KVTaskManager: KVTaskManagerProtocol, @unchecked Sendable {

    /// Type-erased handle that keeps only what the manager needs: cancellation.
    private struct TaskHandle {
        let cancel: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var handles: [String: TaskHandle] = [:]
    private var canceledIds: Set<String> = []

    public init() {}

    public var activeTaskCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handles.count
    }

    public func register<T>(_ task: Task<T, any Error>, for id: String) {
        lock.lock()
        defer { lock.unlock() }
        canceledIds.remove(id)
        handles[id] = TaskHandle(cancel: { task.cancel() })
    }

    public func status(for id: String) -> KVTaskStatus {
        lock.lock()
        defer { lock.unlock() }
        if canceledIds.contains(id) { return .canceled }
        return handles[id] != nil ? .inProgress : .unknown
    }

    public func complete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        handles.removeValue(forKey: id)
        canceledIds.remove(id)
    }

    public func cancel(id: String) {
        lock.lock()
        let handle = handles.removeValue(forKey: id)
        if handle != nil { canceledIds.insert(id) }
        lock.unlock()

        // Cancel outside the lock; Task.cancel may run cancellation handlers synchronously.
        handle?.cancel()
    }

    public func cancelAll() {
        lock.lock()
        let all = handles
        handles.removeAll()
        canceledIds.formUnion(all.keys)
        lock.unlock()

        for handle in all.values {
            handle.cancel()
        }
    }
}
