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

    /// Type-erased handle that keeps only what the manager needs: cancellation,
    /// and which registration owns the entry.
    private struct TaskHandle {
        let registration: KVTaskRegistration?
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
        handles[id] = TaskHandle(registration: nil, cancel: { task.cancel() })
    }

    public func register<T>(
        _ registration: KVTaskRegistration,
        task makeTask: () -> Task<T, any Error>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard handles[registration.id] == nil else { return false }

        // Creating the task under the lock is safe: `Task.init` only enqueues the work.
        let task = makeTask()
        canceledIds.remove(registration.id)
        handles[registration.id] = TaskHandle(registration: registration, cancel: { task.cancel() })
        return true
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

    public func complete(_ registration: KVTaskRegistration) {
        lock.lock()
        defer { lock.unlock() }
        switch handles[registration.id] {
        case .some(let handle) where handle.registration == registration:
            handles.removeValue(forKey: registration.id)
            canceledIds.remove(registration.id)
        case .none:
            // Canceled earlier (the handle is already gone): clear the canceled marker.
            canceledIds.remove(registration.id)
        case .some:
            // A newer request reused the id; its entry is not ours to remove.
            break
        }
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
