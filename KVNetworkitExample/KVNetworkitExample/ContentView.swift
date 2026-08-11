//
//  ContentView.swift
//  KVNetworkitExample
//
//  Created by KhanhVu on 18/7/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            PostsView()
                .tabItem { Label("Posts", systemImage: "list.bullet") }

            CreatePostView()
                .tabItem { Label("Create", systemImage: "plus.circle") }

            LiveStreamView()
                .tabItem { Label("Stream", systemImage: "dot.radiowaves.left.and.right") }

            NetworkStatusView()
                .tabItem { Label("Status", systemImage: "antenna.radiowaves.left.and.right") }
        }
    }
}

#Preview {
    ContentView()
}
