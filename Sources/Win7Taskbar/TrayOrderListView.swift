import AppKit

/// A small drag-to-reorder list of the tray elements. Dragging a row rearranges the order and calls
/// `onReorder` with the new id order (top→bottom in the list = left→right in the tray).
final class TrayOrderListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onReorder: (([String]) -> Void)?
    private var items: [(id: String, label: String)] = []
    private let table = NSTableView()
    private static let rowType = NSPasteboard.PasteboardType("de.batix.win7taskbar.trayRow")
    private let rowH: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = rowH
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType])
        table.draggingDestinationFeedbackStyle = .gap

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 260),
            heightAnchor.constraint(equalToConstant: rowH * 6 + 6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setItems(_ items: [(id: String, label: String)]) {
        self.items = items
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = id
                f.lineBreakMode = .byTruncatingTail
                return f
            }()
        // The ≡ handle hints that the row can be dragged.
        field.stringValue = "≡   " + items[row].label
        return field
    }

    // MARK: - Drag reordering

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        op == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let from = Int(s), from >= 0, from < items.count else { return false }
        var to = row
        let moved = items.remove(at: from)
        if from < to { to -= 1 }
        items.insert(moved, at: max(0, min(items.count, to)))
        table.reloadData()
        onReorder?(items.map { $0.id })
        return true
    }
}
