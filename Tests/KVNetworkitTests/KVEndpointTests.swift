//
//  KVEndpointTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

private struct TestEndpoint: KVAPIEndpointProtocol {
    var method: KVHTTPMethod = .get
    var path: String = "/users"
    var baseURL: String = "https://api.example.com"
    var apiVersion: String = "/api/v1"
    var headers: [String: String] = [:]
    var urlParams: [String: any CustomStringConvertible] = [:]
    var body: KVHTTPBody?
    var timeout: TimeInterval?
}

final class KVEndpointTests: XCTestCase {

    func testBuildsURLWithVersionAndPath() {
        let request = TestEndpoint().urlRequest
        XCTAssertEqual(request?.url?.absoluteString, "https://api.example.com/api/v1/users")
        XCTAssertEqual(request?.httpMethod, "GET")
    }

    func testQueryParamsAreAppendedSorted() {
        var endpoint = TestEndpoint()
        endpoint.urlParams = ["page": 2, "limit": 50]
        let url = endpoint.urlRequest?.url?.absoluteString
        XCTAssertEqual(url, "https://api.example.com/api/v1/users?limit=50&page=2")
    }

    func testContentTypeIsDerivedFromBody() {
        var endpoint = TestEndpoint()
        endpoint.method = .post
        endpoint.body = .json(Data("{}".utf8))
        let request = endpoint.urlRequest
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request?.httpBody, Data("{}".utf8))
    }

    func testExplicitContentTypeIsNotOverridden() {
        var endpoint = TestEndpoint()
        endpoint.method = .post
        endpoint.body = .json(Data("{}".utf8))
        endpoint.headers = ["Content-Type": "application/vnd.custom+json"]
        let request = endpoint.urlRequest
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/vnd.custom+json")
    }

    func testTimeoutOverrideIsApplied() {
        var endpoint = TestEndpoint()
        endpoint.timeout = 5
        XCTAssertEqual(endpoint.urlRequest?.timeoutInterval, 5)
    }

    func testMultipartBodySetsBoundaryContentType() {
        var form = KVMultipartFormData(boundary: "test-boundary")
        form.addField(name: "title", value: "hello")
        form.addFile(name: "file", fileName: "a.jpg", mimeType: .jpeg, data: Data([0x1]))

        var endpoint = TestEndpoint()
        endpoint.method = .post
        endpoint.body = .multipartFormData(form)

        let request = endpoint.urlRequest
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=test-boundary"
        )

        let bodyString = String(data: request?.httpBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"title\""))
        XCTAssertTrue(bodyString.contains("filename=\"a.jpg\""))
        XCTAssertTrue(bodyString.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(bodyString.hasSuffix("--test-boundary--\r\n"))
    }

    func testFormURLEncodedBody() {
        let body = KVHTTPBody.formURLEncoded(["name": "khanh vu", "age": "30"])
        let encoded = String(data: body.asData ?? Data(), encoding: .utf8)
        XCTAssertEqual(encoded, "age=30&name=khanh%20vu")
        XCTAssertEqual(body.contentType, "application/x-www-form-urlencoded")
    }
}
