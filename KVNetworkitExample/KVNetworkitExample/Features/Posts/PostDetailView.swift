import SwiftUI

struct PostDetailView: View {
    let post: Post
    var vm: PostsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Label("Post #\(post.id)", systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(post.title.capitalized)
                        .font(.title2.bold())
                    Divider()
                    Text(post.body)
                        .font(.body)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
        }
        .navigationTitle("Post Detail")
        .navigationBarTitleDisplayMode(.inline)
    }
}
