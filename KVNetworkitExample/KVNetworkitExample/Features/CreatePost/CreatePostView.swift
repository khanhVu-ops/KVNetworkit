import SwiftUI

struct CreatePostView: View {
    @State private var vm = PostsViewModel()
    @State private var title = ""
    @State private var body_ = ""
    @FocusState private var focusedField: Field?

    enum Field { case title, body }

    var body: some View {
        NavigationStack {
            Form {
                Section("Post Details") {
                    TextField("Title", text: $title)
                        .focused($focusedField, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .body }

                    TextField("Body", text: $body_, axis: .vertical)
                        .focused($focusedField, equals: .body)
                        .lineLimit(4...8)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if vm.isSending {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(vm.isSending ? "Sending…" : "Create Post")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(vm.isSending || title.isEmpty || body_.isEmpty)
                }
            }
            .navigationTitle("Create Post")
            .alert("Error", isPresented: .constant(vm.errorMessage != nil)) {
                Button("OK") { vm.clearMessages() }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .alert("Success", isPresented: .constant(vm.successMessage != nil)) {
                Button("Great!") {
                    vm.clearMessages()
                    title = ""
                    body_ = ""
                }
            } message: {
                Text(vm.successMessage ?? "")
            }
        }
    }

    private func submit() {
        focusedField = nil
        Task { await vm.createPost(title: title, body: body_) }
    }
}
