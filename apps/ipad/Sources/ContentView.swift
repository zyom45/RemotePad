import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: RemotePadModel
    @State private var reloadToken = UUID()
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
                    Button("Reload WebView") {
                        reloadToken = UUID()
                    }
                    .disabled(!model.isProxyRunning)
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
                BrowserWorkspaceView(reloadToken: reloadToken)
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
    let reloadToken: UUID

    var body: some View {
        if let url = model.browserURL, model.isProxyRunning {
                BrowserView(url: url, reloadToken: reloadToken)
                    .ignoresSafeArea()
        } else {
            ContentUnavailableView("Proxy Stopped", systemImage: "network", description: Text("Start the local proxy to open the Mac localhost target."))
        }
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
