import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var captureCoordinator: ReminderCaptureCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                RecordingVisualization(state: captureCoordinator.state)
                Text(captureCoordinator.statusMessage)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                Spacer()
                RecordButton()
                if let lastReminder = captureCoordinator.lastSuccessfulReminder {
                    VStack(spacing: 12) {
                        Text("Last reminder")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(lastReminder)
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Reminder Board")
        }
        .onAppear {
            captureCoordinator.bindToIntentNotifications()
        }
        .onDisappear {
            captureCoordinator.unbindFromIntentNotifications()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ReminderCaptureCoordinator(preview: true))
}
