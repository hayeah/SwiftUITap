import SwiftUI
import SwiftAgentSDK

struct ContentView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var state = appState

        NavigationStack {
            VStack(spacing: 0) {
                // Input
                HStack {
                    TextField("What needs to be done?", text: $state.newTodoText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTodo() }
                        .agentID("input")

                    Button {
                        addTodo()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(appState.newTodoText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .agentID("addButton")
                }
                .padding()
                .agentID("inputBar")

                // List
                if appState.todos.isEmpty {
                    Spacer()
                    Text("No todos yet")
                        .foregroundStyle(.secondary)
                        .agentID("emptyLabel")
                    Spacer()
                } else {
                    List {
                        ForEach(Array(appState.todos.enumerated()), id: \.element.id) { index, item in
                            TodoRow(item: item) {
                                appState.toggleTodo(index: index)
                            } onDelete: {
                                appState.removeTodo(index: index)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .agentID("todoList")
                }

                // Footer
                if !appState.completedTodos.isEmpty {
                    HStack {
                        Text("\(appState.activeCount) item\(appState.activeCount == 1 ? "" : "s") left")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                        Spacer()
                        Button("Clear completed") {
                            appState.clearCompleted()
                        }
                        .font(.footnote)
                        .agentID("clearButton")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .agentID("footer")
                }
            }
            .navigationTitle("Todos")
            .agentID("root")
        }
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
    }
}
