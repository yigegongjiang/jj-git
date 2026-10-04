import AppKit
import SwiftUI

/// 字体与固定尺寸；配置在启动时读取，构建一次即可。
@MainActor
struct DiffMetrics {
    /// 勾选 24 + 行号 40×2 + 标记 25。
    static let gutter: CGFloat = 129
    static let headerHeight: CGFloat = 28
    static let noNewline = "  ⏎ 无末尾换行"

    let code: NSFont
    let header: NSFont
    let button: NSFont
    let small: NSFont
    let charWidth: CGFloat
    let rowHeight: CGFloat
    let spacing: CGFloat
    let textHeight: CGFloat
    let noNewlineWidth: CGFloat
    let measure = NSTextFieldCell(textCell: "")

    init() {
        let typography = Typography.shared
        code = typography.font(mono: true, size: typography.editorFontSize, weight: .regular)
        header = typography.font(mono: false, size: typography.fontSize - 1, weight: .semibold)
        button = typography.font(mono: false, size: typography.fontSize - 1, weight: .regular)
        small = typography.font(mono: true, size: typography.fontSize - 1, weight: .regular)
        charWidth = ("0" as NSString).size(withAttributes: [.font: code]).width
        spacing = typography.diffLineSpacing
        measure.wraps = true
        measure.lineBreakMode = .byWordWrapping
        measure.attributedStringValue = NSAttributedString(string: "0", attributes: [.font: code])
        textHeight = ceil(measure.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 1000)).height)
        rowHeight = max(typography.diffLineHeight, textHeight + spacing)
        noNewlineWidth = ceil((Self.noNewline as NSString).size(withAttributes: [.font: code]).width)
    }

    /// 不换行时的内容宽度：最长行 + 行首栏 + 截断 / 末尾换行提示与留白 200。
    func contentWidth(columns: Int) -> CGFloat {
        ceil(CGFloat(columns) * charWidth) + Self.gutter + 200
    }

    func text(_ line: DiffLine) -> NSAttributedString {
        let text = NSMutableAttributedString(string: line.display,
                                             attributes: [.font: code, .foregroundColor: NSColor.labelColor])
        if line.noNewline {
            let hint: [NSAttributedString.Key: Any] = [.font: code, .foregroundColor: NSColor.tertiaryLabelColor]
            text.append(NSAttributedString(string: Self.noNewline, attributes: hint))
        }
        return text
    }

    func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        measure.attributedStringValue = text
        return ceil(measure.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
            .height)
    }

    /// 换行模式的行高。纯 ASCII 且必然放得下一行时直接返回，其余按与绘制相同的 cell 实测。
    func wrappedHeight(_ line: DiffLine, width: CGFloat) -> CGFloat {
        let budget = width - 6 - (line.noNewline ? noNewlineWidth : 0)
        let bytes = line.raw.utf8.count - 1
        if CGFloat(bytes * 4) * charWidth <= budget {
            return rowHeight
        }
        var columns = 0
        var ascii = true
        for byte in line.raw.utf8.dropFirst().prefix(DiffLine.displayLimit) {
            if byte >= 0x80 {
                ascii = false
                break
            }
            columns += byte == 9 ? 4 : 1
        }
        if ascii, bytes <= DiffLine.displayLimit, CGFloat(columns) * charWidth <= budget {
            return rowHeight
        }
        return max(rowHeight, textHeight(text(line), width: width) + spacing)
    }
}

/// 窗口缩放结束后补算换行行高。
final class DiffScrollView: NSScrollView {
    var onResize: (() -> Void)?

    override func tile() {
        super.tile()
        onResize?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onResize?()
    }
}

struct DiffButton {
    let title: String
    let enabled: Bool
    let action: () -> Void
}

/// 标题 + 右侧按钮的固定高度头部；按钮按可视宽度排布，不随横向内容宽度外移。
class DiffHeaderCell: NSView {
    private let label = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var actions: [() -> Void] = []
    private var viewport: CGFloat = 0
    var inset: CGFloat {
        10
    }

    override var isFlipped: Bool {
        true
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.nsTitleBar.cgColor
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func configure(title: String, font: NSFont, buttons specs: [DiffButton], buttonFont: NSFont, viewport: CGFloat) {
        label.stringValue = title
        label.font = font
        while buttons.count < specs.count {
            let button = NSButton(title: "", target: self, action: #selector(press(_:)))
            button.isBordered = false
            button.contentTintColor = .controlAccentColor
            addSubview(button)
            buttons.append(button)
        }
        for (index, button) in buttons.enumerated() {
            button.isHidden = index >= specs.count
            guard index < specs.count else { continue }
            button.title = specs[index].title
            button.font = buttonFont
            button.isEnabled = specs[index].enabled
            button.tag = index
            button.sizeToFit()
        }
        actions = specs.map(\.action)
        self.viewport = viewport
        needsLayout = true
    }

    @objc
    private func press(_ sender: NSButton) {
        if sender.tag < actions.count {
            actions[sender.tag]()
        }
    }

    override func layout() {
        super.layout()
        var right = min(bounds.width, viewport) - inset
        for button in buttons.reversed() where !button.isHidden {
            let size = button.frame.size
            right -= size.width
            button.frame = NSRect(origin: NSPoint(x: right, y: (bounds.height - size.height) / 2), size: size)
            right -= 12
        }
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: inset, y: (bounds.height - height) / 2, width: max(0, right - inset), height: height)
    }
}

final class DiffFileCell: DiffHeaderCell {
    static let identifier = NSUserInterfaceItemIdentifier("diff.file")

    @MainActor
    func configure(title: String, buttons: [DiffButton], metrics: DiffMetrics, viewport: CGFloat) {
        configure(title: title, font: metrics.header, buttons: buttons, buttonFont: metrics.button, viewport: viewport)
    }
}

final class DiffHunkCell: DiffHeaderCell {
    static let identifier = NSUserInterfaceItemIdentifier("diff.hunk")

    override var inset: CGFloat {
        8
    }

    @MainActor
    func configure(title: String, buttons: [DiffButton], metrics: DiffMetrics, viewport: CGFloat) {
        configure(title: title, font: metrics.small, buttons: buttons, buttonFont: metrics.button, viewport: viewport)
    }
}

final class DiffMessageCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("diff.message")
    private let label = NSTextField(wrappingLabelWithString: "")

    override var isFlipped: Bool {
        true
    }

    init() {
        super.init(frame: .zero)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    @MainActor
    func configure(_ text: String, metrics: DiffMetrics) {
        let style: [NSAttributedString.Key: Any] = [.font: metrics.small, .foregroundColor: NSColor.secondaryLabelColor]
        label.attributedStringValue = NSAttributedString(string: text, attributes: style)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 12, dy: 12)
    }
}

/// 差异行：底色 / 勾选框 / 行号 / 标记直接绘制，正文用可选中的 NSTextField；不使用 Auto Layout。
final class DiffLineCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("diff.line")
    private static let checked = symbol("checkmark.square.fill", color: Theme.nsForeground)
    private static let unchecked = symbol("square", color: Theme.nsForeground.withAlphaComponent(0.5))
    private static let added = Theme.nsAdded
    private static let deleted = Theme.nsDeleted
    private static let highlight = Theme.nsForeground.withAlphaComponent(0.25)
    private static let dimmed = Theme.nsForeground.withAlphaComponent(0.5)
    private static let right = paragraph(.right)
    private static let center = paragraph(.center)

    private let field = NSTextField(labelWithString: "")
    private var line: DiffLine?
    private var selected = false
    private var selectable = false
    private var wrap = false
    private var font = NSFont.systemFont(ofSize: 12)
    private var textHeight: CGFloat = 0
    private var spacing: CGFloat = 0
    private var toggle: ((Bool) -> Void)?

    override var isFlipped: Bool {
        true
    }

    init() {
        super.init(frame: .zero)
        field.isSelectable = true
        field.drawsBackground = false
        field.cell?.wraps = true
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        return style
    }

    private static func symbol(_ name: String, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [color])))
    }

    struct Content {
        let line: DiffLine
        let text: NSAttributedString
        let selected: Bool
        let selectable: Bool
        let wrap: Bool
    }

    @MainActor
    func configure(_ content: Content, metrics: DiffMetrics, toggle: @escaping (Bool) -> Void) {
        line = content.line
        selected = content.selected
        selectable = content.selectable
        wrap = content.wrap
        self.toggle = toggle
        font = metrics.code
        textHeight = metrics.textHeight
        spacing = metrics.spacing
        field.cell?.wraps = wrap
        field.cell?.lineBreakMode = wrap ? .byWordWrapping : .byClipping
        field.usesSingleLineMode = !wrap
        field.attributedStringValue = content.text
        needsLayout = true
        needsDisplay = true
    }

    /// 换行时正文从半个行间距处开始；不换行时单行垂直居中。
    private var top: CGFloat {
        wrap ? spacing / 2 : max(0, (bounds.height - textHeight) / 2)
    }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: DiffMetrics.gutter, y: top, width: max(0, bounds.width - DiffMetrics.gutter),
                             height: wrap ? max(textHeight, bounds.height - spacing) : textHeight)
    }

    override func draw(_: NSRect) {
        guard let line else { return }
        if line.kind == "+" {
            Self.added.setFill()
            bounds.fill()
        } else if line.kind == "-" {
            Self.deleted.setFill()
            bounds.fill()
        }
        if selectable, let image = selected ? Self.checked : Self.unchecked {
            let size = image.size
            image.draw(in: NSRect(x: 12 - size.width / 2, y: top + (textHeight - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor,
                                                     .paragraphStyle: Self.right]
        let height = textHeight
        if let old = line.oldLine {
            ("\(old)" as NSString).draw(in: NSRect(x: 24, y: top, width: 40, height: height), withAttributes: number)
        }
        if let new = line.newLine {
            ("\(new)" as NSString).draw(in: NSRect(x: 64, y: top, width: 40, height: height), withAttributes: number)
        }
        let kind: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: Self.center,
                                                   .foregroundColor: line.changed ? Theme.nsForeground : Self.dimmed]
        (String(line.kind) as NSString).draw(in: NSRect(x: 104, y: top, width: 25, height: height),
                                             withAttributes: kind)
        if selected {
            Self.highlight.setFill()
            bounds.fill(using: .sourceOver)
        }
    }

    /// 窗口未激活时，点击勾选框同样直接生效。
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if selectable, point.x < 24 {
            toggle?(event.modifierFlags.contains(.shift))
        } else {
            super.mouseDown(with: event)
        }
    }
}
