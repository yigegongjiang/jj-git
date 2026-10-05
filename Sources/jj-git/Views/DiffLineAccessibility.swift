import AppKit

/// 可勾选的变更行暴露为复选框：AXPress = 点击勾选框，命名动作 = ⇧ 点击（连选到此行）。
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
        return ([line.kind == "+" ? "新增行" : "删除行"] + number + [line.display]).joined(separator: "，")
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: selected)
    }

    override func accessibilityPerformPress() -> Bool {
        toggle?(false)
        return toggle != nil
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "连选到此行") { [weak self] in
            self?.toggle?(true)
            return self?.toggle != nil
        }]
    }
}
