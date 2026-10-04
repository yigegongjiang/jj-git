import SwiftUI

struct EmptyState: View {
    let title: String
    let symbol: String
    var detail = ""

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !detail.isEmpty {
                Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NamePrompt: View {
    let title: String
    let initial: String
    let submit: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
        .onAppear { name = initial }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submit(name)
        dismiss()
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            ScrollView { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 80)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭错误提示")
        }
        .font(.system(size: 12)).padding(8).background(.orange.opacity(0.09))
    }
}

/// 隐藏标题栏后的顶部条：与窗口按钮同一行，左侧让出窗口按钮（实测右缘 70pt）。
struct WindowBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 8) { content() }.padding(.leading, 78).padding(.trailing, 10).frame(height: 32)
            .windowDragArea()
    }
}

extension View {
    /// 标题栏隐藏后由空白处接管：拖动移动窗口，双击按系统「双击窗口标题栏」设置缩放或最小化。
    /// SwiftUI 手势会让窗口无法拖动，因此用 AppKit 视图处理。
    func windowDragArea() -> some View {
        background(WindowDragArea())
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        DragView()
    }

    func updateNSView(_: NSView, context _: Context) {
    }

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { return window.performDrag(with: event) }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        }
    }
}

struct SectionHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10).frame(height: 28).background(.quaternary.opacity(0.4))
    }
}
