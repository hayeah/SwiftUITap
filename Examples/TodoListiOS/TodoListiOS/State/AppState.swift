import Foundation
import SwiftUI
import SwiftAgentSDK

#if DEBUG
@AgentSDK
#endif
@Observable
final class AppState {
    var __doc__: String {
        """
        AppState — TodoList iOS app state tree.

        ## State Tree

        todos — array of TodoItem objects
          todos.N.title (String)        — the todo text
          todos.N.isCompleted (Bool)    — whether the todo is done

        newTodoText (String) — text field for adding new todos

        ## Methods

        addTodo(title: String) → {"index": N}
        toggleTodo(index: Int)
        removeTodo(index: Int)
        clearCompleted()
        """
    }

    var todos: [TodoItem] = []
    var newTodoText: String = ""

    var activeTodos: [TodoItem] {
        todos.filter { !$0.isCompleted }
    }

    var completedTodos: [TodoItem] {
        todos.filter { $0.isCompleted }
    }

    var activeCount: Int { activeTodos.count }

    func addTodo(title: String) -> [String: Any]? {
        let item = TodoItem(title: title)
        todos.append(item)
        return ["index": todos.count - 1]
    }

    func toggleTodo(index: Int) {
        guard index >= 0 && index < todos.count else { return }
        todos[index].isCompleted.toggle()
    }

    func removeTodo(index: Int) {
        guard index >= 0 && index < todos.count else { return }
        todos.remove(at: index)
    }

    func clearCompleted() {
        todos.removeAll { $0.isCompleted }
    }
}
