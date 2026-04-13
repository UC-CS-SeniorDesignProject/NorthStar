// radxa wifi setup UI - hotspot connect, token, wifi picker
import SwiftUI

struct RadxaSetupView: View {
    @Bindable var viewModel: RadxaSetupViewModel

    var body: some View {
        NavigationStack {
            Form {
                switch viewModel.phase {
                case .detecting:
                    detectingSection

                case .onHotspot, .tokenSetup:
                    tokenSection

                case .tokenEntry:
                    tokenEntrySection

                case .wifiSelect:
                    wifiSelectSection

                case .wifiPassword:
                    wifiPasswordSection

                case .connecting:
                    statusSection(
                        title: "Connecting",
                        message: "Sending Wi-Fi credentials to Radxa...",
                        showSpinner: true
                    )

                case .reconnecting:
                    statusSection(
                        title: "Reconnecting",
                        message: "Radxa is joining the Wi-Fi network. Switch your iPhone to the same network, then wait for reconnection via mDNS...",
                        showSpinner: true
                    )

                case .connected:
                    connectedSection

                case .failed:
                    failedSection
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Radxa Setup")
            .onAppear {
                Task { await viewModel.detectRadxa() }
            }
        }
    }


    private var detectingSection: some View {
        Section {
            HStack {
                ProgressView()
                    .padding(.trailing, 8)
                Text("Looking for Radxa...")
            }
        } footer: {
            Text("Checking if the Radxa is reachable via mDNS or hotspot.")
        }
    }

    private var tokenSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connected to Radxa hotspot", systemImage: "wifi")
                    .foregroundStyle(.green)

                Text("Set a security token that will be used to authenticate all future requests. Minimum 8 characters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                SecureField("Security token", text: $viewModel.newToken)
                    .textContentType(.password)

                Button {
                    Task { await viewModel.submitToken() }
                } label: {
                    HStack {
                        Text("Set Token")
                        Spacer()
                        if viewModel.isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.newToken.count < 8 || viewModel.isLoading)
            }
        } header: {
            Text("Token Setup")
        }
    }

    private var tokenEntrySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connected to Radxa hotspot", systemImage: "wifi")
                    .foregroundStyle(.green)

                Text("The Radxa already has a token configured. Enter your existing token to continue to Wi-Fi setup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                SecureField("Existing token", text: $viewModel.newToken)
                    .textContentType(.password)

                Button {
                    Task { await viewModel.submitExistingToken() }
                } label: {
                    HStack {
                        Text("Authenticate")
                        Spacer()
                        if viewModel.isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.newToken.isEmpty || viewModel.isLoading)
            }
        } header: {
            Text("Enter Token")
        }
    }

    private var wifiSelectSection: some View {
        Group {
            Section {
                Label("Token configured", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Section {
                if viewModel.networks.isEmpty && viewModel.isLoading {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Scanning for networks...")
                    }
                } else if viewModel.networks.isEmpty {
                    Text("No networks found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.networks) { network in
                        Button {
                            viewModel.selectNetwork(network)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    HStack(spacing: 6) {
                                        Text(network.ssid)
                                            .foregroundStyle(.primary)
                                        if network.isEnterprise {
                                            Text("EAP")
                                                .font(.system(size: 8, weight: .bold))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.blue.opacity(0.15))
                                                .foregroundStyle(.blue)
                                                .cornerRadius(3)
                                        }
                                    }
                                    Text(network.security)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                wifiSignalIcon(signal: network.signalInt)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Button {
                    Task { await viewModel.scanNetworks() }
                } label: {
                    HStack {
                        Label("Rescan", systemImage: "arrow.clockwise")
                        Spacer()
                        if viewModel.isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isLoading)
            } header: {
                Text("Select Wi-Fi Network")
            } footer: {
                Text("Choose the Wi-Fi network the Radxa should join. Your iPhone must be on the same network.")
            }
        }
    }

    private var wifiPasswordSection: some View {
        Group {
            if let network = viewModel.selectedNetwork {
                Section {
                    LabeledContent("Network", value: network.ssid)
                    LabeledContent("Security", value: network.security)

                    Toggle("Enterprise Login (WPA2-EAP)", isOn: $viewModel.isEnterpriseMode)

                    if viewModel.isEnterpriseMode {
                        TextField("Username", text: $viewModel.enterpriseUsername)
                            .textContentType(.username)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }

                    SecureField(viewModel.isEnterpriseMode ? "Password" : "Wi-Fi Password", text: $viewModel.wifiPassword)
                        .textContentType(.password)

                    if viewModel.isEnterpriseMode {
                        Picker("EAP Method", selection: $viewModel.enterpriseEAPMethod) {
                            Text("PEAP").tag("peap")
                            Text("TTLS").tag("ttls")
                            Text("TLS").tag("tls")
                        }

                        Picker("Inner Auth", selection: $viewModel.enterprisePhase2) {
                            Text("MSCHAPv2").tag("mschapv2")
                            Text("PAP").tag("pap")
                            Text("CHAP").tag("chap")
                        }
                    }

                    Button {
                        Task { await viewModel.submitWifiCredentials() }
                    } label: {
                        HStack {
                            Text("Connect")
                            Spacer()
                            if viewModel.isLoading {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isLoading || (viewModel.isEnterpriseMode && viewModel.enterpriseUsername.isEmpty))

                    Button("Back to Network List") {
                        viewModel.phase = .wifiSelect
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text(viewModel.isEnterpriseMode ? "Enterprise Login" : "Enter Password")
                } footer: {
                    if viewModel.isEnterpriseMode {
                        Text("Enter your university/organization credentials. PEAP with MSCHAPv2 is the most common configuration.")
                    }
                }
            }
        }
    }

    private func statusSection(title: String, message: String, showSpinner: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if showSpinner {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text(title)
                            .font(.headline)
                    }
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectedSection: some View {
        Group {
            Section {
                Label("Radxa Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)

                if let status = viewModel.radxaStatus {
                    LabeledContent("Status", value: status.status)
                    if let camera = status.camera {
                        LabeledContent("Camera", value: camera)
                    }
                    if let net = status.network {
                        LabeledContent("Network Mode", value: net.mode)
                        if let conn = net.connection {
                            LabeledContent("Connected To", value: conn)
                        }
                        if let ip = net.ip {
                            LabeledContent("IP Address", value: ip)
                        }
                    }
                }
            } header: {
                Text("Connection Status")
            } footer: {
                Text("The Radxa is reachable at radxa.local:8080. The app's server settings have been updated automatically.")
            }

            Section {
                Button("Re-run Setup") {
                    viewModel.startOver()
                    Task { await viewModel.detectRadxa() }
                }
            }
        }
    }

    private var failedSection: some View {
        Section {
            Button {
                viewModel.startOver()
                Task { await viewModel.detectRadxa() }
            } label: {
                Label("Retry Detection", systemImage: "arrow.clockwise")
            }
        } footer: {
            Text("Make sure your iPhone is connected to the \"radxa-setup\" Wi-Fi network (password: radxa1234), or that the Radxa is on the same network as your iPhone.")
        }
    }


    private func wifiSignalIcon(signal: Int) -> Image {
        switch signal {
        case 75...: return Image(systemName: "wifi")
        case 50..<75: return Image(systemName: "wifi")
        case 25..<50: return Image(systemName: "wifi")
        default: return Image(systemName: "wifi.exclamationmark")
        }
    }
}
