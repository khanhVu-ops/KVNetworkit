import SwiftUI

struct PostsView: View {
    @State private var vm = PostsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.posts.isEmpty {
                    ProgressView("Loading posts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.posts.isEmpty {
                    ContentUnavailableView(
                        "No Posts",
                        systemImage: "doc.text",
                        description: Text("Pull down or tap Refresh.")
                    )
                } else {
                    List(vm.posts) { post in
                        NavigationLink(destination: PostDetailView(post: post, vm: vm)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(post.title.capitalized)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(post.body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .refreshable { await vm.fetchPosts() }
                }
            }
            .navigationTitle("Posts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await vm.fetchPosts() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isLoading)
                }
            }
            .alert("Error", isPresented: .constant(vm.errorMessage != nil)) {
                Button("OK") { vm.clearMessages() }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .task { await vm.fetchPosts() }
        }
    }
}
