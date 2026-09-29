//
//  KVTaskManagerProtocol.swift
//  KVNetworkit
//

import Foundation

/// One claim on a request identifier.
///
/// Identifiers are reusable: once a request finishes, a new one may run under the same id.
/// The registration tells those runs apart, so a finishing request only ever removes its
/// own entry — never that of a newer request that has since reused the id.
public struct KVTaskRegistration: Hashable, Sendable {
    /// The request identifier this registration claims.
    public let id: String

    private let token = UUID()

    public init(id: String) {
        self.id = id
    }
}

/// Tracks in-flight request tasks so they can be queried and canceled by identifier.
public protocol KVTaskManagerProtocol: Sendable {
    /// Registers a running task under the given identifier.
    func register<T>(_ task: Task<T, any Error>, for id: String)

    /// Atomically claims `registration.id` and registers the task built by `makeTask`.
    ///
    /// `makeTask` is only called when no task is in progress for the identifier, so a
    /// rejected request never starts any work.
    ///
    /// - Returns: `false` when a task is already in progress under the identifier.
    func register<T>(
        _ registration: KVTaskRegistration,
        task makeTask: () -> Task<T, any Error>
    ) -> Bool

    /// The current status of the task with the given identifier.
    /// Returns `.unknown` when no task is tracked for the identifier.
    func status(for id: String) -> KVTaskStatus

    /// Removes the task with the given identifier from tracking.
    func complete(id: String)

    /// Removes the task of this registration from tracking.
    /// Called by the client when a request finishes (successfully or not). A no-op when
    /// the identifier has since been claimed by a newer registration.
    func complete(_ registration: KVTaskRegistration)

    /// Cancels the task with the given identifier, if it is in progress.
    func cancel(id: String)

    /// Cancels all in-flight tasks.
    func cancelAll()

    /// The number of currently tracked tasks.
    var activeTaskCount: Int { get }
}

// MARK: - Defaults

public extension KVTaskManagerProtocol {
    /// Fallback for conformers written against 2.0, built on the identifier-only methods.
    /// It is not atomic; ``KVTaskManager`` overrides it with an atomic implementation.
    func register<T>(
        _ registration: KVTaskRegistration,
        task makeTask: () -> Task<T, any Error>
    ) -> Bool {
        guard status(for: registration.id) != .inProgress else { return false }
        register(makeTask(), for: registration.id)
        return true
    }

    /// Fallback for conformers written against 2.0: removes whatever is tracked under the id.
    func complete(_ registration: KVTaskRegistration) {
        complete(id: registration.id)
    }
}
