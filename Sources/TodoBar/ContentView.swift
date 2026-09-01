import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: TodoBarModel
    @ObservedObject var store: TodoStore
    var compact: Bool = true
    var onOpenWindow: (() -> Void)? = nil
    var onCloseWindow: (() -> Void)? = nil

    @State private var query = ""
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var newTodoText = ""
    @State private var showAddField = false
    @State private var showAddList = false
    @State private var addListPath = ""
    @State private var showFilter = false
    @State private var showCompleted = false
    @FocusState private var newTodoFocused: Bool
    @FocusState private var addListFocused: Bool
    @FocusState private var filterFocused: Bool

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var completedCount: Int {
        store.sections.reduce(0) { $0 + $1.items.filter(\.isCompleted).count }
    }

    private var filtered: [TodoSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.sections.compactMap { section in
            var items = section.items.filter { showCompleted || !$0.isCompleted }
            if !q.isEmpty {
                items = items.filter {
                    $0.text.localizedCaseInsensitiveContains(q)
                        || section.title.localizedCaseInsensitiveContains(q)
                }
            }
            guard !items.isEmpty else { return nil }
            return TodoSection(id: section.id, title: section.title, items: items)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private let compactWidth: CGFloat = 460
    private let compactHeight: CGFloat = 560

    private var compactListHeight: CGFloat {
        guard compact else { return 320 }
        var used: CGFloat = 44 + 2 + 50 // top bar, dividers, footer
        if showAddField { used += 48 }
        if showAddList { used += 48 }
        if showFilter { used += 44 }
        if store.lastError != nil || store.lastStatus != nil { used += 28 }
        return max(180, compactHeight - used)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if showAddField {
                addField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            if showAddList {
                addListField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            if let err = store.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .lineLimit(2)
            } else if let status = store.lastStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .lineLimit(1)
            }
            list
                .frame(maxWidth: .infinity)
                .frame(height: compact ? compactListHeight : nil)
                .frame(maxHeight: compact ? compactListHeight : .infinity)
            Divider()
            footer
        }
        .frame(width: compact ? compactWidth : nil, height: compact ? compactHeight : nil)
        .frame(minWidth: 400, minHeight: 480)
        .clipped()
        .background(keyboardShortcuts)
        .onAppear { store.syncFromRemote() }
        .sheet(item: $renameID) { id in
            RenameSheet(
                title: renameText,
                onCancel: { renameID = nil },
                onSave: { name in
                    model.renameSource(id, title: name)
                    renameID = nil
                }
            )
        }
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("") { focusAdd() }.keyboardShortcut("n", modifiers: [])
            Button("") { focusFilter() }.keyboardShortcut("/", modifiers: [])
            Button("") { store.syncFromRemote() }.keyboardShortcut("r", modifiers: [])
            if compact, onOpenWindow != nil {
                Button("") { onOpenWindow?() }.keyboardShortcut("w", modifiers: [])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.sources) { source in
                        tabChip(source)
                    }
                    addListTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showAddField.toggle()
                    if showAddField { showAddList = false }
                }
                if showAddField {
                    DispatchQueue.main.async { newTodoFocused = true }
                } else {
                    newTodoText = ""
                    newTodoFocused = false
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(
                        showAddField ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                showAddField ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.15),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .layoutPriority(1)
            .help(showAddField ? "Hide New To-Do (n)" : "Add To-Do (n)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tabLabel(_ source: TodoSource) -> String {
        let title = TodoSource.tabTitle(source.title)
        if source.id == model.selectedID {
            return "\(title) \(store.itemCount)"
        }
        return title
    }

    private var addListTab: some View {
        Button {
            showAddList.toggle()
            showAddField = false
            if showAddList {
                DispatchQueue.main.async { addListFocused = true }
            } else {
                addListPath = ""
                addListFocused = false
            }
        } label: {
            Text("+")
                .font(.caption.weight(showAddList ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(showAddList ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(showAddList ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Add another markdown todo file")
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("New To-Do", text: $newTodoText)
                .textFieldStyle(.plain)
                .focused($newTodoFocused)
                .onSubmit { submitNewTodo() }
            if !newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add") { submitNewTodo() }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }
            Button {
                showAddField = false
                newTodoText = ""
                newTodoFocused = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var addListField: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .foregroundStyle(.secondary)
            TextField("Path to .md — e.g. ~/books.md", text: $addListPath)
                .textFieldStyle(.plain)
                .focused($addListFocused)
                .onSubmit { submitAddList() }
            Button {
                showAddList = false
                addListPath = ""
                addListFocused = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tabChip(_ source: TodoSource) -> some View {
        let selected = source.id == model.selectedID
        return Button {
            query = ""
            model.select(source.id)
        } label: {
            Text(tabLabel(source))
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") {
                renameText = source.title
                renameID = source.id
            }
            Button("Reveal In Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([source.url.deletingLastPathComponent()])
            }
            if model.sources.count > 1 {
                Divider()
                Button("Remove Tab", role: .destructive) {
                    model.removeSource(source.id)
                }
            }
        }
        .help(source.path)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { section in
                    let openItems = section.items.filter { !$0.isCompleted }
                    let doneItems = section.items.filter(\.isCompleted)

                    if section.title != "To-Dos" {
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }

                    ForEach(Array(openItems.enumerated()), id: \.element.id) { index, item in
                        TodoRow(
                            item: item,
                            striped: index % 2 == 1,
                            draggable: !isFiltering && !store.isBusy,
                            onComplete: { store.complete(item) },
                            onSave: { store.updateItem(item, text: $0) },
                            onDelete: { store.deleteItem(item) },
                            onDrop: { draggedID in
                                reorderOpen(item: item, draggedID: draggedID, openItems: openItems)
                            }
                        )
                        .padding(.horizontal, 8)
                    }

                    if showCompleted {
                        ForEach(Array(doneItems.enumerated()), id: \.element.id) { index, item in
                            TodoRow(
                                item: item,
                                striped: (openItems.count + index) % 2 == 1,
                                draggable: false,
                                onComplete: { store.complete(item) },
                                onSave: { store.updateItem(item, text: $0) },
                                onDelete: { store.deleteItem(item) },
                                onDrop: { _ in false }
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                }

                if filtered.isEmpty {
                    Text(isFiltering ? "No matches" : "No open todos in this file")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 12)
        }
        .id(model.selectedID)
    }

    private func reorderOpen(item: TodoItem, draggedID: String, openItems: [TodoItem]) -> Bool {
        guard !item.isCompleted, !isFiltering else { return false }
        guard let from = openItems.firstIndex(where: { $0.id == draggedID }),
              let to = openItems.firstIndex(where: { $0.id == item.id }),
              from != to else { return false }
        store.moveItems(in: item.section, from: IndexSet(integer: from), to: to)
        return true
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if showFilter {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter", text: $query)
                        .textFieldStyle(.plain)
                        .focused($filterFocused)
                    Button {
                        showFilter = false
                        query = ""
                        filterFocused = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                FooterIconButton(
                    systemName: "magnifyingglass",
                    selected: showFilter || isFiltering,
                    help: showFilter ? "Hide filter" : "Filter (/)"
                ) {
                    if showFilter && !isFiltering {
                        showFilter = false
                        filterFocused = false
                    } else {
                        focusFilter()
                    }
                }
                FooterIconButton(systemName: "arrow.clockwise", help: "Refresh (r)") {
                    store.syncFromRemote()
                }
                FooterIconButton(systemName: "doc.text", help: "Open file") {
                    store.openInEditor()
                }
                if compact, onOpenWindow != nil {
                    FooterIconButton(systemName: "macwindow", help: "Open window (w)") {
                        onOpenWindow?()
                    }
                }
                if completedCount > 0 {
                    FooterIconButton(
                        systemName: showCompleted ? "eye.slash" : "eye",
                        selected: showCompleted,
                        help: showCompleted
                            ? "Hide completed (\(completedCount))"
                            : "Show completed (\(completedCount))"
                    ) {
                        showCompleted.toggle()
                    }
                }
                if compact {
                    FooterIconButton(systemName: "power", help: "Quit (q)") {
                        NSApp.terminate(nil)
                    }
                } else if let onCloseWindow {
                    FooterIconButton(systemName: "xmark.circle", help: "Close window") {
                        onCloseWindow()
                    }
                }
                Spacer(minLength: 4)
                Text("v\(appVersion)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func focusAdd() {
        showAddField = true
        showAddList = false
        DispatchQueue.main.async { newTodoFocused = true }
    }

    private func focusFilter() {
        showFilter = true
        DispatchQueue.main.async { filterFocused = true }
    }

    private func submitNewTodo() {
        let text = newTodoText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        newTodoText = ""
        store.addItem(text: text)
        newTodoFocused = true
    }

    private func submitAddList() {
        let path = addListPath
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addListPath = ""
        showAddList = false
        addListFocused = false
        model.addSource(path: path)
    }
}

// MARK: - Footer icon

private struct FooterIconButton: View {
    let systemName: String
    var selected = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(
                    selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Rename

private struct RenameSheet: View {
    @State var title: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tab")
                .font(.headline)
            TextField("Name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSave(title) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(title) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

private struct TodoRow: View {
    let item: TodoItem
    let striped: Bool
    let draggable: Bool
    let onComplete: () -> Void
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let onDrop: (String) -> Bool

    @State private var expanded = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(item.isCompleted ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onTapGesture { onComplete() }
                .help(item.isCompleted ? "Reopen" : "Mark Complete")

            if editing {
                TextField("To-Do", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(item.text)
                    .font(.system(size: 13))
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEdit() }
                    .onTapGesture(count: 1) {
                        withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
                    }
                    .help(expanded ? "Double-Click To Edit" : "Click To Expand · Double-Click To Edit")
            }
        }
        .padding(.leading, CGFloat(min(item.indent, 8)) * 4)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(striped ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 6))
        .opacity(item.isCompleted ? 0.75 : 1)
        .contextMenu {
            Button(item.isCompleted ? "Reopen" : "Mark Complete") { onComplete() }
            Button("Edit…") { beginEdit() }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
        .onChange(of: item.text) { _ in
            if editing { cancelEdit() }
            expanded = false
        }
        .if(draggable && !item.isCompleted) { view in
            view
                .onDrag { NSItemProvider(object: item.id as NSString) }
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first else { return false }
                    return onDrop(dragged)
                }
        }
    }

    private func beginEdit() {
        draft = item.text
        editing = true
        expanded = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitEdit() {
        let value = draft
        editing = false
        fieldFocused = false
        onSave(value)
    }

    private func cancelEdit() {
        editing = false
        fieldFocused = false
        draft = item.text
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
