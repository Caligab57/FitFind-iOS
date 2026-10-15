import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serviceURL") private var endpoint = "http://localhost:8787"
    @AppStorage("productSearchConsent") private var productConsent = false
    @State private var draftEndpoint = ""
    @State private var token = ""
    @State private var message: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Recognition & product service") {
                    TextField("Server address", text: $draftEndpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("FitFind server address")
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
                }.listRowBackground(FitStyle.surface)
                Section("Photo privacy") {
                    Text("Photos are sent to your recognition server and Google Gemini only when you request analysis. Saved looks stay on this device and contain descriptions, not photos.")
                        .font(.footnote)
                    Link("Google Gemini data terms", destination: URL(string: "https://ai.google.dev/gemini-api/terms")!)
                }.listRowBackground(FitStyle.surface)
                Section("Product search privacy") {
                    Text("Product searches send garment search descriptions through your server to SerpApi, a third-party Google Shopping search provider. Your photo and original preferences aren't sent to SerpApi. Searches return text-matched candidates; visual similarity, identity, and availability are unverified.")
                        .font(.footnote)
                    if productConsent {
                        Button("Ask before the next product search") { productConsent = false }
                    } else {
                        Text("You'll be asked before the first product search.").font(.footnote)
                    }
                    Link("SerpApi privacy policy", destination: URL(string: "https://serpapi.com/privacy")!)
                    Text("Saved looks store descriptions and your budget. Product results aren't saved; search again for fresh listings.")
                        .font(.footnote)
                }.listRowBackground(FitStyle.surface)
            }
            .scrollContentBackground(.hidden)
            .background(FitStyle.background)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FitStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
        .foregroundStyle(FitStyle.ink)
        .tint(FitStyle.accent)
        .preferredColorScheme(.dark)
    }
}
