//
//  KVHTTPMethod.swift
//  KVNetworkit
//

import Foundation

/// HTTP methods as defined in RFC 7231 §4.3.
public enum KVHTTPMethod: String, Sendable {
    case options = "OPTIONS"
    case get     = "GET"
    case head    = "HEAD"
    case post    = "POST"
    case put     = "PUT"
    case patch   = "PATCH"
    case delete  = "DELETE"
    case trace   = "TRACE"
    case connect = "CONNECT"
}
