import SwiftUI

struct DeskCompanionContentView: View {
    @ObservedObject var viewModel: DeskCompanionViewModel

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

            if viewModel.tasks.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for today's sync…")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(viewModel.tasks) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(task.summary)
                                    .font(.title2.weight(.medium))
                                Text("Captured at " + task.capturedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)

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
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(24)
        .task {
            await viewModel.loadDailySummary()
        }
    }
}
