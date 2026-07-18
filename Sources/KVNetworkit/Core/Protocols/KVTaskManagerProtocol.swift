//
//  KVTaskManagerProtocol.swift
//  KVNetworkit
//

import Foundation

/// Tracks in-flight request tasks so they can be queried and canceled by identifier.
public protocol KVTaskManagerProtocol: Sendable {
    /// Registers a running task under the given identifier.
    func register<T>(_ task: Task<T, any Error>, for id: String)

    /// The current status of the task with the given identifier.
    /// Returns `.unknown` when no task is tracked for the identifier.
    func status(for id: String) -> KVTaskStatus

    /// Removes the task with the given identifier from tracking.
    /// Called by the client when a request finishes (successfully or not).
    func complete(id: String)

    /// Cancels the task with the given identifier, if it is in progress.
    func cancel(id: String)

    /// Cancels all in-flight tasks.
    func cancelAll()

    /// The number of currently tracked tasks.
    var activeTaskCount: Int { get }
}
