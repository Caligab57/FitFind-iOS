import SwiftUI
import PhotosUI

struct ContentView: View {
    @EnvironmentObject private var store: OutfitStore
    @AppStorage("serviceURL") private var endpoint = "http://localhost:8787"
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var settings = false
    @State private var consent = false
    @State private var confirmAnalysis = false

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        photoSection
                        budgetSection
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your preferences").font(.headline)
                            TextField("Occasion, preferred fit, colors to avoid...", text: $store.context, axis: .vertical)
                                .lineLimit(2...4).padding(12)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                                .disabled(store.isAnalyzing)
                                .onChange(of: store.context) { value in
                                    if value.count > 600 { store.context = String(value.prefix(600)) }
                                    store.didSave = false
                                }
                        }
                        if let message = store.error {
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("errorMessage")
                        }
                        if store.isAnalyzing {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Reading your outfit...").font(.subheadline)
                                Spacer()
                                Button("Cancel", role: .cancel) { store.cancelAnalysis() }
                            }
                        } else if store.needsAnalysis {
                            Button {
                                if consent { store.analyze(endpoint: endpoint) } else { confirmAnalysis = true }
                            } label: {
                                Label(store.analysis == nil ? "Find my outfit" : "Update analysis", systemImage: "viewfinder")
                                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.photoData == nil || store.budgetCents == nil || store.isLoadingPhoto)
                        }
                        if let analysis = store.analysis, let cents = store.budgetCents {
                            if store.needsAnalysis {
                                Text("Preferences changed. Update the analysis to apply them.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            OutfitResults(analysis: analysis, budgetCents: cents)
                            if !analysis.garments.isEmpty {
                                Button { store.saveLook() } label: {
                                    Label(store.didSave ? "Saved" : "Save this look", systemImage: store.didSave ? "checkmark" : "bookmark")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered).disabled(store.didSave || store.needsAnalysis)
                            }
                        }
                    }
                    .padding(20)
                }
                .navigationTitle("FitFind")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { settings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
                .sheet(isPresented: $settings) { SettingsView() }
                .confirmationDialog("Analyze this photo?", isPresented: $confirmAnalysis, titleVisibility: .visible) {
                    Button("Send photo and analyze") {
                        consent = true
                        store.analyze(endpoint: endpoint)
                    }
                } message: {
                    Text("Your selected photo and preferences will be sent through your recognition server to Google Gemini. FitFind does not save the photo on the server. Google's data terms apply.")
                }
                .onChange(of: selectedPhoto) { item in
                    consent = false
                    Task { await store.load(item) }
                }
                .onChange(of: store.tier) { _ in store.didSave = false }
                .onChange(of: store.customDollars) { _ in store.didSave = false }
            }
            .tabItem { Label("Discover", systemImage: "viewfinder") }
            SavedLooksView().tabItem { Label("Saved", systemImage: "bookmark") }
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let photo = store.photo {
                Image(uiImage: photo).resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: 300)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Selected outfit photo")
            } else {
                VStack(spacing: 16) {
                    if store.isLoadingPhoto { ProgressView() }
                    else { Image(systemName: "photo.on.rectangle.angled").font(.system(size: 42)).foregroundStyle(.secondary) }
                    Text(store.isLoadingPhoto ? "Opening photo..." : "Your next outfit starts here")
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).frame(height: 220)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label(store.photo == nil ? "Choose outfit photo" : "Change photo", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).disabled(store.isAnalyzing)
        }
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Outfit budget").font(.headline)
                Spacer()
                Text(store.budgetCents.map(usd) ?? "--").font(.title2.weight(.semibold)).monospacedDigit()
            }
            ViewThatFits(in: .horizontal) {
                tierPicker.fixedSize(horizontal: true, vertical: false)
                Picker("Budget tier", selection: $store.tier) {
                    ForEach(BudgetTier.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
            }
            if store.tier == .custom {
                HStack {
                    Text("USD")
                    TextField("Whole dollars", text: $store.customDollars)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Custom budget in whole US dollars")
                }
                if store.budgetCents == nil {
                    Text("Enter a whole-dollar amount from $1 to $10,000.").font(.caption).foregroundStyle(.red)
                }
            }
            Text("Total for all pieces. Tax and shipping excluded.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tierPicker: some View {
        Picker("Budget tier", selection: $store.tier) {
            ForEach(BudgetTier.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented)
    }
}

struct OutfitResults: View {
    let analysis: Analysis
    let budgetCents: Int
    var body: some View {
        let allocations = Budget.allocate(budgetCents, garments: analysis.garments)
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            Text("The outfit").font(.title2.weight(.bold))
            Text(analysis.summary).font(.subheadline)
            if analysis.garments.isEmpty {
                Label("No clothing was clearly visible. Try another photo.", systemImage: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(analysis.garments.enumerated()), id: \.element.id) { index, garment in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: garment.category.symbol).font(.title3)
                                .frame(width: 28, height: 28).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(garment.name).font(.headline)
                                Text(garment.color).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                        }
                        Text(garment.details).font(.subheadline).foregroundStyle(.secondary)
                        if allocations.indices.contains(index) {
                            HStack {
                                Text("Target \(usd(allocations[index]))").font(.subheadline.weight(.semibold)).monospacedDigit()
                                Spacer()
                                if let url = garment.shoppingURL(budgetCents: allocations[index]) {
                                    Link(destination: url) { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.bordered)
                                        .accessibilityLabel("Search shopping for \(garment.name)")
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Targets are budget allocations, not product prices. Shopping searches may return items above your target; availability and matches are unverified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !analysis.limitations.isEmpty {
                Label(analysis.limitations, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct SavedLooksView: View {
    @EnvironmentObject private var store: OutfitStore
    var body: some View {
        NavigationStack {
            Group {
                if store.saved.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No saved looks yet").font(.title3.weight(.semibold))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.saved) { look in
                            NavigationLink {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 16) {
                                        Text(usd(look.budgetCents)).font(.title.bold())
                                        OutfitResults(analysis: look.analysis, budgetCents: look.budgetCents)
                                    }.padding(20)
                                }.navigationTitle("Saved look").navigationBarTitleDisplayMode(.inline)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(look.analysis.summary).font(.headline).lineLimit(2)
                                    Text("\(usd(look.budgetCents)) · \(look.analysis.garments.count) pieces")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text(look.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        }.onDelete(perform: store.delete)
                    }
                }
            }
            .navigationTitle("Saved looks")
            .toolbar { if !store.saved.isEmpty { EditButton() } }
        }
    }
}
