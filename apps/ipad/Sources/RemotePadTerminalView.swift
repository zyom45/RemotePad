import SwiftTerm
import SwiftUI
import UIKit

struct RemotePadTerminalView: UIViewRepresentable {
    @EnvironmentObject private var model: RemotePadModel
    let renderTick: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        _ = renderTick
        context.coordinator.model = model
        for chunk in model.drainTerminalOutputChunks() {
            let bytes = [UInt8](chunk)
            view.feed(byteArray: bytes[...])
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var model: RemotePadModel?

        init(model: RemotePadModel) {
            self.model = model
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            Task { @MainActor [weak model] in
                model?.sendTerminalData(payload)
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor [weak model] in
                model?.resizeTerminal(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
