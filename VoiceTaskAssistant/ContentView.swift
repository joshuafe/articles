import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: TaskCaptureViewModel
    @State private var showingAddArticle = false

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

                ReadingListPanel(
                    sections: viewModel.readingSections,
                    suggestedTags: viewModel.suggestedTags,
                    errorMessage: viewModel.readingListError,
                    addAction: { showingAddArticle = true }
                )
            }
            .padding(32)
        }
        .onAppear {
            viewModel.startup()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            viewModel.resume()
        }
        .sheet(isPresented: $showingAddArticle) {
            AddArticleSheet()
                .environmentObject(viewModel)
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

private struct ReadingListPanel: View {
    var sections: [ReadingListSection]
    var suggestedTags: [String]
    var errorMessage: String?
    var addAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reading list")
                    .font(.headline)
                Spacer()
                Button(action: addAction) {
                    Label("Add article", systemImage: "plus")
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            if sections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save links to dig into later.")
                        .foregroundColor(.secondary)
                    if !suggestedTags.isEmpty {
                        TagSuggestionsView(tags: suggestedTags)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(12)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .textCase(.uppercase)

                            ForEach(section.items) { item in
                                ReadingItemRow(item: item)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TagSuggestionsView: View {
    var tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag.capitalized)
                        .font(.caption)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                }
            }
        }
    }
}

private struct ReadingItemRow: View {
    var item: ReadingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.body)
            Link(destination: item.url) {
                Text(item.url.absoluteString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !item.tags.isEmpty {
                Text(item.tags.map { $0.capitalized }.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(12)
    }
}

private struct AddArticleSheet: View {
    @EnvironmentObject private var viewModel: TaskCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var url: String = ""
    @State private var tagsInput: String = ""
    @State private var selectedTags: Set<String> = []
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Article") {
                    TextField("Title", text: $title)
                    TextField("Link", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                if !viewModel.suggestedTags.isEmpty {
                    Section("Suggested tags") {
                        FlexibleTagSelector(
                            tags: viewModel.suggestedTags,
                            selectedTags: $selectedTags
                        )
                    }
                }

                Section("Custom tags") {
                    TextField("Comma separated", text: $tagsInput)
                }

                if let error = viewModel.readingListError {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Add article")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear {
                title = ""
                url = ""
                tagsInput = ""
                selectedTags.removeAll()
                viewModel.clearReadingListError()
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let manualTags = tagsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let success = await viewModel.addArticle(
            title: title,
            urlString: url,
            tags: Array(selectedTags) + manualTags
        )
        if success {
            dismiss()
        }
    }
}

private struct FlexibleTagSelector: View {
    var tags: [String]
    @Binding var selectedTags: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 80), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                let isSelected = selectedTags.contains(tag)
                Text(tag.capitalized)
                    .font(.caption)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(isSelected ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                    .onTapGesture {
                        if isSelected {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                    }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TaskCaptureViewModel(
            speechService: PreviewSpeechService(),
            syncCoordinator: PreviewSyncCoordinator(),
            readingListManager: PreviewReadingListManager()
        ))
}
