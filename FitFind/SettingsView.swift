import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serviceURL") private var endpoint = "http://localhost:8787"
    @State private var draftEndpoint = ""
    @State private var token = ""
    @State private var message: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Recognition service") {
                    TextField("Server address", text: $draftEndpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Recognition server address")
                    SecureField("Local access token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        checking = true; message = nil
                        Task {
                            defer { checking = false }
                            do {
                                message = try await RecognitionClient(endpoint: draftEndpoint, token: token).checkConnection()
                            } catch { message = error.localizedDescription }
                        }
                    } label: {
                        HStack { Label("Test connection", systemImage: "network"); if checking { Spacer(); ProgressView() } }
                    }.disabled(checking)
                    if let message = message { Text(message).font(.footnote) }
                }
                Section("Photo privacy") {
                    Text("Photos are sent to your recognition server and Google Gemini only when you request analysis. Saved looks stay on this device and contain descriptions, not photos.")
                        .font(.footnote)
                    Link("Google Gemini data terms", destination: URL(string: "https://ai.google.dev/gemini-api/terms")!)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try TokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
                            endpoint = draftEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                            dismiss()
                        } catch { message = error.localizedDescription }
                    }.disabled(checking)
                }
            }
            .onAppear { draftEndpoint = endpoint; token = TokenStore.read() }
        }
    }
}
