//
//  KVTaskStatus.swift
//  KVNetworkit
//

/// The lifecycle status of a request task tracked by ``KVTaskManager``.
public enum KVTaskStatus: Sendable, Equatable {
    /// No task is (or has been) tracked for the identifier.
    case unknown
    /// The task is currently being executed.
    case inProgress
    /// The task was canceled before completion.
    case canceled
}
