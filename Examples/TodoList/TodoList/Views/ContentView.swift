import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            // Header
            Text("Todos")
                .font(.largeTitle.bold())
                .padding()

            // Input
            HStack {
                TextField("What needs to be done?", text: $state.newTodoText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTodo() }

                Button("Add") { addTodo() }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.newTodoText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom)

            // List
            if (appState.todos as! [TodoItem]).isEmpty {
                Spacer()
                Text("No todos yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(Array((appState.todos as! [TodoItem]).enumerated()), id: \.element.id) { index, item in
                        TodoRow(item: item) {
                            appState.toggleTodo(index: index)
                        } onDelete: {
                            appState.removeTodo(index: index)
                        }
                    }
                }
            }

            // Footer
            if !appState.completedTodos.isEmpty {
                HStack {
                    Text("\(appState.activeCount) item\(appState.activeCount == 1 ? "" : "s") left")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear completed") {
                        appState.clearCompleted()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }

    private func addTodo() {
        let text = appState.newTodoText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        _ = appState.addTodo(title: text)
        appState.newTodoText = ""
    }
}

struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Text(item.title)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? .secondary : .primary)

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
