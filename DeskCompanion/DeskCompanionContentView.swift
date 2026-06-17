import SwiftUI

struct DeskCompanionContentView: View {
    @ObservedObject var viewModel: DeskCompanionViewModel
    @State private var newTitle: String = ""
    @State private var newURL: String = ""
    @State private var newTags: String = ""
    @State private var selectedTags: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Today's plan")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                Button("Refresh") {
                    viewModel.refresh()
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if viewModel.tasks.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Waiting for today's sync…")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(viewModel.tasks) { task in
                            TaskCard(task: task)
                        }
                    }

                    ReadingDashboard(
                        sections: viewModel.readingSections,
                        suggestedTags: viewModel.suggestedTags,
                        errorMessage: viewModel.readingListError,
                        newTitle: $newTitle,
                        newURL: $newURL,
                        newTags: $newTags,
                        selectedTags: $selectedTags,
                        addAction: addArticle
                    )
                }
                .padding(.vertical, 8)
            }
        }
        .padding(24)
        .task {
            await viewModel.loadDailySummary()
            await viewModel.loadReadingList()
        }
    }

    private func addArticle() {
        let manualTags = newTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        viewModel.addArticle(
            title: newTitle,
            url: newURL,
            tags: Array(selectedTags) + manualTags
        )
        if viewModel.readingListError == nil {
            newTitle = ""
            newURL = ""
            newTags = ""
            selectedTags.removeAll()
        }
    }
}

private struct TaskCard: View {
    var task: DailySummary.TaskEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.summary)
                .font(.title2.weight(.medium))
            Text("Captured at " + task.capturedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundColor(.secondary)

            if !task.topics.isEmpty {
                Text(task.topics.map { $0.capitalized }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !task.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Subtasks")
                        .font(.headline)
                    ForEach(task.subtasks) { subtask in
                        HStack {
                            Image(systemName: "circle")
                            Text(subtask.title)
                            if let due = subtask.dueDate {
                                Spacer()
                                Text(due, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            if !task.reminders.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reminders")
                        .font(.headline)
                    ForEach(task.reminders) { reminder in
                        Text("\(reminder.title) – \(reminder.fireDate.formatted(date: .omitted, time: .shortened))")
                            .font(.callout)
                    }
                }
            }
        }
        .padding()
        .background(.thinMaterial)
        .cornerRadius(16)
    }
}

private struct ReadingDashboard: View {
    var sections: [ReadingSection]
    var suggestedTags: [String]
    var errorMessage: String?
    @Binding var newTitle: String
    @Binding var newURL: String
    @Binding var newTags: String
    @Binding var selectedTags: Set<String>
    var addAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reading list")
                .font(.title2.weight(.semibold))

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.footnote)
            }

            if sections.isEmpty {
                Text("Add articles you want to read and they’ll be sorted by topic tags.")
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                            ForEach(section.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.body)
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    if !item.tags.isEmpty {
                                        Text(item.tags.map { $0.capitalized }.joined(separator: ", "))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding()
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(12)
                            }
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add article")
                    .font(.headline)

                TextField("Title", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("Link", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Custom tags (comma separated)", text: $newTags)
                    .textFieldStyle(.roundedBorder)

                if !suggestedTags.isEmpty {
                    TagSelectionView(tags: suggestedTags, selectedTags: $selectedTags)
                }

                Button(action: addAction) {
                    Label("Save to reading list", systemImage: "tray.and.arrow.down")
                }
                .disabled(newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(.thinMaterial)
        .cornerRadius(16)
    }
}

private struct TagSelectionView: View {
    var tags: [String]
    @Binding var selectedTags: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                let isSelected = selectedTags.contains(tag)
                Text(tag.capitalized)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
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
