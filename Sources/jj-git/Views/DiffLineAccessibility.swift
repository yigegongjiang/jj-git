import AppKit

/// 可勾选的变更行暴露为复选框：AXPress = 点击勾选框；⇧ 点击（连选到此行）= 命名动作 + 子按钮。
/// 其余行不作为元素，只保留正文文本；复用行状态由 configure 更新。
extension DiffLineCell {
    override func isAccessibilityElement() -> Bool {
        selectable
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .checkBox
    }

    override func accessibilityLabel() -> String? {
        guard let line else { return nil }
        let number = [line.oldLine.map { "旧 \($0)" }, line.newLine.map { "新 \($0)" }].compactMap(\.self)
        let kind = line.kind == "+" ? "新增行" : line.kind == "-" ? "删除行" : "上下文行"
        return ([kind] + number + [line.display]).joined(separator: "，")
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: selected)
    }

    override func accessibilityHelp() -> String? {
        guard let line, !line.emphasis.isEmpty else { return nil }
        let display = line.display as NSString
        let changes = line.emphasis.filter { NSMaxRange($0) <= display.length }.map {
            let text = display.substring(with: $0)
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? "空白" : text
        }
        return "行内变化：" + changes.joined(separator: " / ")
    }

    override func accessibilityPerformPress() -> Bool {
        toggle?(false)
        return toggle != nil
    }

    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + (selectable ? [rangeButton] : [])
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "连选到此行") { [weak self] in
            self?.toggle?(true)
            return self?.toggle != nil
        }]
    }
}

/// 「连选到此行」子按钮：只认 AXPress 的工具（Peekaboo 等）无法调用命名动作。
final class DiffLineRangeButton: NSAccessibilityElement {
    private weak var cell: DiffLineCell?

    init(cell: DiffLineCell) {
        self.cell = cell
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel("连选到此行")
        setAccessibilityEnabled(true)
    }

    override func accessibilityParent() -> Any? {
        cell
    }

    override func accessibilityFrame() -> NSRect {
        cell.flatMap { cell in cell.window.map { $0.convertToScreen(cell.convert(cell.bounds, to: nil)) } } ?? .zero
    }

    override func accessibilityPerformPress() -> Bool {
        cell?.toggle?(true)
        return cell?.toggle != nil
    }
}
