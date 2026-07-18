import Foundation
import KVNetworkit

@Observable
final class PostsViewModel {
    private(set) var posts: [Post] = []
    private(set) var selectedPost: Post?
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?

    private let client: KVAPIClient

    init(client: KVAPIClient = AppNetworkClient.shared) {
        self.client = client
    }

    func fetchPosts() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            posts = try await client.request(PostEndpoint.fetchAll)
        } catch {
            errorMessage = errorDescription(error)
        }
    }

    func fetchPost(id: Int) async {
        errorMessage = nil
        do {
            selectedPost = try await client.request(PostEndpoint.fetchOne(id: id))
        } catch {
            errorMessage = errorDescription(error)
        }
    }

    func createPost(title: String, body: String) async {
        guard !title.isEmpty, !body.isEmpty else {
            errorMessage = "Title and body are required."
            return
        }

        isSending = true
        errorMessage = nil
        successMessage = nil
        defer { isSending = false }

        do {
            let created: Post = try await client.request(
                PostEndpoint.create(title: title, body: body, userId: 1)
            )
            successMessage = "Created post #\(created.id): \"\(created.title)\""
        } catch {
            errorMessage = errorDescription(error)
        }
    }

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    private func errorDescription(_ error: Error) -> String {
        if let apiError = error as? KVAPIClientError {
            return apiError.localizedDescription
        }
        return error.localizedDescription
    }
}
