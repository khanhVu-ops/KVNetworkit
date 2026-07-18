//
//  KVAuthTokenStoreProviding.swift
//  KVNetworkit
//

import Foundation

/// A store for authentication tokens (access / refresh), typically backed by the Keychain.
///
/// Implementations must be thread-safe: tokens are read from arbitrary
/// concurrent request contexts.
public protocol KVAuthTokenStoreProviding: Sendable {
    /// The access token used to authenticate API requests.
    var accessToken: String? { get }

    /// The refresh token used to obtain new access tokens when expired.
    var refreshToken: String? { get }

    /// Stores a new access token.
    func setAccessToken(_ token: String)

    /// Stores a new refresh token.
    func setRefreshToken(_ token: String)

    /// Clears all tokens. Typically called on logout or session expiration.
    func clear()
}
