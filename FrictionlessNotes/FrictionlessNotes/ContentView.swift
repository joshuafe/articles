//
//  ContentView.swift
//  FrictionlessNotes
//
//  Created by Joshua Fein on 12/29/25.
//  Round 1: thin passthrough — HomeView is the app. File kept so existing
//  project references stay valid.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        HomeView()
    }
}

#Preview {
    NavigationStack {
        ContentView()
    }
    .environment(CaptureStore())
    .preferredColorScheme(.dark)
}
