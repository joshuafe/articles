import SwiftUI

struct RecordButton: View {
    @EnvironmentObject private var captureCoordinator: ReminderCaptureCoordinator

    var body: some View {
        Button(action: toggleRecording) {
            Label {
                Text(captureCoordinator.state.buttonTitle)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 12)
            } icon: {
                Image(systemName: captureCoordinator.state.buttonIcon)
                    .font(.title)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .tint(.accentColor)
        .buttonStyle(.borderedProminent)
        .disabled(captureCoordinator.state == .uploading || captureCoordinator.state == .transcribing)
        .accessibilityIdentifier("recordButton")
    }

    private func toggleRecording() {
        Task { @MainActor in
            switch captureCoordinator.state {
            case .idle, .ready:
                await captureCoordinator.startRecording()
            case .recording:
                await captureCoordinator.stopRecording()
            case .transcribing, .uploading:
                break
            }
        }
    }
}

struct RecordingVisualization: View {
    let state: ReminderCaptureCoordinator.State

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.3), lineWidth: 6)
                    .frame(width: 160, height: 160)
                Circle()
                    .fill(state.visualColor.gradient)
                    .frame(width: state.visualScale * 140, height: state.visualScale * 140)
                    .animation(.easeInOut(duration: 0.3), value: state)
                Image(systemName: state.visualIcon)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            Text(state.displayTitle)
                .font(.title.weight(.bold))
        }
    }
}

#Preview("Idle") {
    RecordingVisualization(state: .idle)
}

#Preview("Recording") {
    RecordingVisualization(state: .recording)
}

#Preview("Uploading") {
    RecordingVisualization(state: .uploading)
}
