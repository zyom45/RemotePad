import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: RemotePadModel
    @State private var reloadToken = UUID()

    var body: some View {
        NavigationSplitView {
            Form {
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
            if let url = model.browserURL, model.isProxyRunning {
                BrowserView(url: url, reloadToken: reloadToken)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView("Proxy Stopped", systemImage: "network", description: Text("Start the local proxy to open the Mac localhost target."))
            }
        }
    }
}
