import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: RemotePadModel
    @State private var workspace = WorkspaceView.terminal

    var body: some View {
        NavigationSplitView {
            Form {
                Section {
                    Picker("Workspace", selection: $workspace) {
                        ForEach(WorkspaceView.allCases, id: \.self) { view in
                            Text(view.title).tag(view)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Connection") {
                    TextField("Agent host", text: $model.agentHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Agent port", text: $model.agentPort)
                        .keyboardType(.numberPad)
                    TextField("Local port", text: $model.localPort)
                        .keyboardType(.numberPad)
                    TextField("Mac target port", text: $model.targetPort)
                        .keyboardType(.numberPad)
                    TextField("Path", text: $model.browserPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button("Request Pairing") {
                        model.requestPairing()
                    }
                    Button("Check Pairing Status") {
                        model.checkPairingStatus()
                    }
                    Button(model.isTerminalConnected ? "Disconnect Terminal" : "Connect Terminal") {
                        model.isTerminalConnected ? model.disconnectTerminal() : model.connectTerminal()
                    }
                    Button(model.isProxyRunning ? "Stop Proxy" : "Start Proxy") {
                        model.isProxyRunning ? model.stopProxy() : model.startProxy()
                    }
                }

                Section("Status") {
                    LabeledContent("Pairing", value: model.pairingStatus)
                    LabeledContent("Terminal", value: model.terminalStatus)
                    Text(model.status)
                    if let url = model.browserURL {
                        Text(url.absoluteString)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }

                Section("Device Identity") {
                    LabeledContent("Device ID", value: model.identity.deviceID.uuidString)
                    LabeledContent("Public Key", value: model.identity.publicKey.base64EncodedString())
                    LabeledContent("Fingerprint", value: model.identity.fingerprint)
                }
            }
            .navigationTitle("RemotePad")
        } detail: {
            switch workspace {
            case .terminal:
                TerminalWorkspaceView()
            case .browser:
                BrowserWorkspaceView()
            }
        }
    }
}

private enum WorkspaceView: CaseIterable {
    case terminal
    case browser

    var title: String {
        switch self {
        case .terminal:
            "Terminal"
        case .browser:
            "Browser"
        }
    }
}

private struct BrowserWorkspaceView: View {
    @EnvironmentObject private var model: RemotePadModel
    @StateObject private var browserState = BrowserViewState()

    private let presets: [(label: String, port: UInt16)] = [
        ("3000", 3000),
        ("5173", 5173),
        ("8080", 8080),
        ("18080", 18080)
    ]

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            Divider()

            if let url = model.browserURL, model.isProxyRunning {
                BrowserView(url: url, state: browserState)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView("Proxy Stopped", systemImage: "network", description: Text("Start the local proxy to open the Mac localhost target."))
            }
        }
    }

    private var browserToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Back") {
                    browserState.goBack()
                }
                .disabled(!browserState.canGoBack || !model.isProxyRunning)

                Button("Forward") {
                    browserState.goForward()
                }
                .disabled(!browserState.canGoForward || !model.isProxyRunning)

                Button("Reload") {
                    browserState.reload()
                }
                .disabled(!model.isProxyRunning)

                Button(model.isProxyRunning ? "Stop Proxy" : "Start Proxy") {
                    model.isProxyRunning ? model.stopProxy() : startProxyAndLoad()
                }

                Spacer()

                if browserState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                TextField("Mac port", text: $model.targetPort)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                TextField("Path", text: $model.browserPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        startProxyAndLoad()
                    }
                Button("Open") {
                    startProxyAndLoad()
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.port) { preset in
                        Button(preset.label) {
                            model.setBrowserTarget(port: preset.port)
                            startProxyAndLoad()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .padding(12)
    }

    private var statusLine: String {
        if !model.isProxyRunning {
            return model.status
        }
        if !browserState.title.isEmpty {
            return "\(browserState.title) - \(browserState.currentURL)"
        }
        return browserState.currentURL.isEmpty ? model.browserURL?.absoluteString ?? model.status : browserState.currentURL
    }

    private func startProxyAndLoad() {
        model.startProxyIfNeeded()
        browserState.loadCurrentTarget()
    }
}

private struct TerminalWorkspaceView: View {
    @EnvironmentObject private var model: RemotePadModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.terminalStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    model.clearTerminalOutput()
                }
                Button(model.isTerminalConnected ? "Disconnect" : "Connect") {
                    model.isTerminalConnected ? model.disconnectTerminal() : model.connectTerminal()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            RemotePadTerminalView(renderTick: model.terminalRenderTick)
                .overlay {
                    if model.terminalOutput.isEmpty && !model.isTerminalConnected {
                        ContentUnavailableView("Terminal Disconnected", systemImage: "terminal", description: Text("Connect to start a Mac terminal."))
                    }
                }

            Divider()

            TerminalKeyBar()

            HStack(spacing: 8) {
                TextField("Command", text: $model.terminalInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.sendTerminalInput()
                    }
                Button("Send") {
                    model.sendTerminalInput()
                }
                .disabled(model.terminalInput.isEmpty || !model.isTerminalConnected)
            }
            .padding(12)
        }
    }
}

private struct TerminalKeyBar: View {
    @EnvironmentObject private var model: RemotePadModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("Esc") {
                    model.sendTerminalEscape()
                }
                Button("Tab") {
                    model.sendTerminalTab()
                }
                Button("Ctrl-C") {
                    model.sendTerminalInterrupt()
                }
                Button("Clear") {
                    model.clearTerminalOutput()
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .disabled(!model.isTerminalConnected)
    }
}
