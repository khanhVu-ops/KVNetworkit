//
//  KVErrorResponseTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

private struct TestEndpoint: KVAPIEndpointProtocol {
    var method: KVHTTPMethod = .post
    var path: String = "/chat"
    var baseURL: String = "https://api.example.com"
}

private struct CreditsError: Decodable, Error {
    struct Extra: Decodable {
        let currentCredits: Int
        let requiredCredits: Int
    }
    let detail: String
    let extra: Extra
}

private let testURL = URL(string: "https://api.example.com/chat")!

private let creditsBody = Data(
    #"{"status_code":402,"detail":"Insufficient credits","extra":{"currentCredits":67,"requiredCredits":120}}"#.utf8
)

final class KVErrorResponseTests: XCTestCase {

    private func client(
        status: Int,
        body: Data,
        headers: [String: String]? = nil,
        mapper: KVErrorResponseMapper? = nil
    ) -> KVAPIClient {
        let session = KVMockNetworkSession()
        session.enqueue(.success((body, KVMockNetworkSession.httpResponse(url: testURL, statusCode: status, headers: headers))))
        return KVAPIClient(session: session, interceptors: [], errorResponseMapper: mapper)
    }

    func testDefaultMappingIsUnchanged() async {
        do {
            try await client(status: 402, body: creditsBody).request(TestEndpoint())
            XCTFail("Expected serverMessage")
        } catch {
            guard case let KVAPIClientError.serverMessage(message, statusCode) = error else {
                return XCTFail("Expected serverMessage, got \(error)")
            }
            XCTAssertEqual(message, "Insufficient credits")
            XCTAssertEqual(statusCode, 402)
        }
    }

    func testRawBodyAndStatusAreAvailableThroughTheMapper() async throws {
        let client = client(
            status: 402,
            body: creditsBody,
            headers: ["Content-Type": "application/json"],
            mapper: { $0.statusCode == 402 ? $0 : nil }
        )

        do {
            try await client.request(TestEndpoint())
            XCTFail("Expected KVHTTPErrorResponse")
        } catch let error as KVHTTPErrorResponse {
            XCTAssertEqual(error.statusCode, 402)
            XCTAssertEqual(error.data, creditsBody)
            XCTAssertEqual(error.message, "Insufficient credits")
            XCTAssertEqual(error.headers["Content-Type"], "application/json")
            XCTAssertEqual(error.url, testURL)
            XCTAssertEqual(error.localizedDescription, "Insufficient credits")

            let credits = try error.decode(CreditsError.self)
            XCTAssertEqual(credits.extra.currentCredits, 67)
            XCTAssertEqual(credits.extra.requiredCredits, 120)
        }
    }

    func testMapperReturningNilFallsBackToTheDefault() async {
        let client = client(status: 422, body: Data(#"{"message":"Bad"}"#.utf8), mapper: { $0.statusCode == 402 ? $0 : nil })

        do {
            try await client.request(TestEndpoint())
            XCTFail("Expected serverMessage")
        } catch {
            guard case KVAPIClientError.serverMessage("Bad", 422) = error else {
                return XCTFail("Expected serverMessage, got \(error)")
            }
        }
    }

    func testMappedDomainErrorIsThrownUnwrapped() async {
        let client = client(status: 402, body: creditsBody, mapper: { response in
            try? response.decode(CreditsError.self)
        })

        do {
            try await client.request(TestEndpoint())
            XCTFail("Expected CreditsError")
        } catch let error as CreditsError {
            XCTAssertEqual(error.extra.requiredCredits, 120)
        } catch {
            XCTFail("Expected CreditsError, got \(error)")
        }
    }

    func testPlainTextErrorBodyBecomesAStatusCodeError() async {
        let traceback = Data("Traceback (most recent call last):\n  File \"app.py\", line 1\nKeyError: 'x'\n".utf8)
        let client = client(status: 500, body: traceback, headers: ["Content-Type": "text/plain"])

        do {
            try await client.request(TestEndpoint())
            XCTFail("Expected statusCode(500)")
        } catch {
            guard case KVAPIClientError.statusCode(500) = error else {
                return XCTFail("Expected statusCode(500), got \(error)")
            }
        }
    }

    func testPlainTextErrorBodyIsReadableThroughTheMapper() async {
        let client = client(status: 500, body: Data("Internal Server Error".utf8), mapper: { $0 })

        do {
            try await client.request(TestEndpoint())
            XCTFail("Expected KVHTTPErrorResponse")
        } catch let error as KVHTTPErrorResponse {
            XCTAssertNil(error.message)
            XCTAssertEqual(error.text, "Internal Server Error")
            guard case .statusCode(500) = error.clientError else {
                return XCTFail("Expected statusCode(500), got \(error.clientError)")
            }
        } catch {
            XCTFail("Expected KVHTTPErrorResponse, got \(error)")
        }
    }

    func testUnrecovered401SurfacesItsStatusCode() async {
        do {
            try await client(status: 401, body: Data(#"{"detail":"Not authenticated"}"#.utf8)).request(TestEndpoint())
            XCTFail("Expected an error")
        } catch let error as KVAPIClientError {
            // Documented behavior: a 401 is reported like any other status, not as `.unauthorized`.
            XCTAssertEqual(error.statusCode, 401)
        } catch {
            XCTFail("Expected KVAPIClientError, got \(error)")
        }
    }

    // MARK: - Mock client

    func testMockStubbedErrorIsSafeToMutateConcurrently() async {
        let mock = KVMockAPIClient()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        mock.stubbedError = index.isMultiple(of: 4) ? KVAPIClientError.timeout : nil
                    } else {
                        _ = try? await mock.request(TestEndpoint(), id: "\(index)")
                    }
                }
            }
        }

        mock.stubbedError = KVAPIClientError.networkUnavailable
        do {
            try await mock.request(TestEndpoint())
            XCTFail("Expected the stubbed error")
        } catch {
            guard case KVAPIClientError.networkUnavailable = error else {
                return XCTFail("Expected networkUnavailable, got \(error)")
            }
        }
    }
}
