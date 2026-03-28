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
        AppState — TodoList app state tree.

        Single source of truth. All views bind to paths within this tree.

        ## State Tree

        todos — array of TodoItem objects
          todos.N.title (String)        — the todo text
          todos.N.isCompleted (Bool)    — whether the todo is done

        newTodoText (String) — text field for adding new todos

        ## Methods

        addTodo(title: String) → {"index": N}
          Creates a new TodoItem and appends it to `todos`.
          Returns the index of the new item.

        toggleTodo(index: Int)
          Toggles `isCompleted` on the todo at the given index.

        removeTodo(index: Int)
          Removes the todo at the given index.

        clearCompleted()
          Removes all completed todos.

        ## Common Workflows

        Add a todo:
          call addTodo {"title": "Buy milk"}

        Complete a todo:
          call toggleTodo {"index": 0}

        Edit a todo's title:
          set todos.0.title "Buy oat milk instead"

        Check all todos:
          get todos

        Remove completed:
          call clearCompleted
        """
    }

    var todos: [TodoItem] = []
    var newTodoText: String = ""

    // Computed
    var activeTodos: [TodoItem] {
        todos.filter { !$0.isCompleted }
    }

    var completedTodos: [TodoItem] {
        todos.filter { $0.isCompleted }
    }

    var activeCount: Int { activeTodos.count }

    // MARK: - Actions

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

    // Test Codable support
    func getStats() -> TodoStats {
        TodoStats(total: todos.count, active: activeTodos.count, completed: completedTodos.count)
    }

}

struct TodoStats: Codable {
    var total: Int
    var active: Int
    var completed: Int
}
