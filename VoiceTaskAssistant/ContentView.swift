import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: TaskCaptureViewModel

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text(viewModel.transcriptionText.isEmpty ? "Tap to capture" : viewModel.transcriptionText)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(16)

                    if let status = viewModel.captureStatusMessage {
                        Text(status)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                CaptureButton(isRecording: viewModel.isRecording) {
                    viewModel.toggleCapture()
                }
                .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Start recording")

                if !viewModel.pendingTasks.isEmpty {
                    PendingTaskList(tasks: viewModel.pendingTasks)
                        .transition(.move(edge: .bottom))
                }
            }
            .padding(32)
        }
        .onAppear {
            viewModel.startup()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            viewModel.resume()
        }
    }
}

private struct CaptureButton: View {
    var isRecording: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                    .frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)

                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct PendingTaskList: View {
    var tasks: [CapturedTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Captured tasks")
                .font(.headline)

            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.rawText)
                        .font(.body)
                    Text(task.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView()
        .environmentObject(TaskCaptureViewModel(
            speechService: PreviewSpeechService(),
            syncCoordinator: PreviewSyncCoordinator()
        ))
}
