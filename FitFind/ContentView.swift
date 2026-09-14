import SwiftUI
import PhotosUI

// Shared styling for discovery, saved looks, and sheets.
enum FitStyle {
    static let background = Color(red: 0.045, green: 0.049, blue: 0.045)
    static let surface = Color(red: 0.085, green: 0.091, blue: 0.082)
    static let raised = Color(red: 0.12, green: 0.13, blue: 0.115)
    static let ink = Color(red: 0.94, green: 0.93, blue: 0.89)
    static let muted = Color(red: 0.63, green: 0.65, blue: 0.60)
    static let accent = Color(red: 0.80, green: 0.94, blue: 0.38)
    static let line = Color.white.opacity(0.13)

    static func headline(_ size: CGFloat) -> Font {
        .custom("AvenirNextCondensed-Heavy", size: size, relativeTo: .title)
    }

    static func caption() -> Font { .system(.caption2, design: .monospaced).weight(.medium) }
}

struct FitActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(prominent ? FitStyle.background : FitStyle.ink)
            .background(prominent ? FitStyle.accent : FitStyle.raised, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

struct SectionLabel: View {
    let number: String
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(number).foregroundStyle(FitStyle.accent)
            Text(title).foregroundStyle(FitStyle.muted)
        }
        .font(FitStyle.caption()).tracking(1.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}

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
                    VStack(alignment: .leading, spacing: 26) {
                        masthead
                        photoSection
                        budgetSection
                        preferencesSection
                        analysisSection
                        HStack {
                            Text("SEE IT. FIND IT. MAKE IT YOURS.")
                            Spacer()
                            Image(systemName: "viewfinder")
                        }
                        .font(FitStyle.caption()).tracking(1)
                        .foregroundStyle(FitStyle.muted)
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
                .background(FitStyle.background)
                .toolbar(.hidden, for: .navigationBar)
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
        .foregroundStyle(FitStyle.ink)
        .tint(FitStyle.accent)
        .preferredColorScheme(.dark)
        .toolbarBackground(FitStyle.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("fitfind").font(FitStyle.headline(54)).italic().tracking(-2)
                    .accessibilityLabel("FitFind").accessibilityAddTraits(.isHeader)
                Spacer()
                Button { settings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(FitStyle.ink)
                        .frame(width: 46, height: 46)
                        .background(FitStyle.surface, in: Circle())
                        .overlay(Circle().strokeBorder(FitStyle.line))
                }
                .accessibilityLabel("Settings")
            }
            Rectangle().fill(FitStyle.line).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text("GOOD TASTE.\nYOUR TAKE.").font(FitStyle.headline(32)).lineSpacing(-4)
                Spacer(minLength: 16)
                Text("OUTFIT\nDISCOVERY")
                    .font(FitStyle.caption()).tracking(1.7).lineSpacing(4)
                    .foregroundStyle(FitStyle.muted).multilineTextAlignment(.trailing)
            }
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(number: "01", title: "THE INSPIRATION")
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                if let photo = store.photo {
                    VStack(spacing: 0) {
                        Image(uiImage: photo).resizable().scaledToFit()
                            .frame(maxWidth: .infinity).frame(height: 270)
                            .accessibilityLabel("Selected outfit photo")
                        HStack {
                            Text("YOUR REFERENCE").font(FitStyle.caption()).tracking(1.3)
                            Spacer()
                            Label("Change", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold))
                        }.padding(16).foregroundStyle(FitStyle.ink)
                    }
                    .background(FitStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "viewfinder")
                            Spacer()
                            Text("FROM YOUR CAMERA ROLL").font(FitStyle.caption()).tracking(1)
                        }.foregroundStyle(FitStyle.muted)
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.isLoadingPhoto ? "OPENING PHOTO…" : "START WITH\nA LOOK.")
                                    .font(FitStyle.headline(32)).multilineTextAlignment(.leading)
                                    .foregroundStyle(FitStyle.ink)
                                Text("A saved fit. A screenshot. Your inspiration.")
                                    .font(.caption).foregroundStyle(FitStyle.muted)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Group {
                                if store.isLoadingPhoto { ProgressView().tint(FitStyle.background) }
                                else { Image(systemName: "plus").font(.system(size: 24, weight: .medium)) }
                            }
                            .frame(width: 50, height: 50)
                            .foregroundStyle(FitStyle.background)
                            .background(FitStyle.accent, in: Circle())
                        }
                        HStack {
                            Text("CHOOSE OUTFIT PHOTO")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(FitStyle.caption()).tracking(1.2).foregroundStyle(FitStyle.ink)
                        .padding(.top, 4)
                    }
                    .padding(20)
                    .background(FitStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FitStyle.line))
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isAnalyzing || store.isLoadingPhoto)
            .accessibilityLabel(store.photo == nil ? "Choose outfit photo" : "Change outfit photo")
            .accessibilityHint("Opens your photo library")
        }
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(number: "02", title: "THE BUDGET")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { budgetHeading; Spacer(minLength: 8); budgetAmount }
                VStack(alignment: .leading, spacing: 6) { budgetHeading; budgetAmount }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                ForEach([BudgetTier.value, .balanced, .premium]) { tier in budgetButton(tier) }
            }
            HStack(spacing: 8) {
                budgetButton(.custom)
                budgetButton(.unlimited)
            }
            if store.tier == .custom {
                HStack(spacing: 12) {
                    Text("USD").font(FitStyle.caption()).foregroundStyle(FitStyle.accent)
                    TextField("Whole dollars", text: $store.customDollars)
                        .keyboardType(.numberPad).font(.body.monospacedDigit())
                        .accessibilityLabel("Custom budget in whole US dollars")
                        .accessibilityIdentifier("customBudget")
                }
                .padding(16).background(FitStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                if !store.hasValidBudget {
                    Text("Enter a whole-dollar amount from $1 to $10,000.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Text(store.tier == .unlimited
                 ? "Follow the look, without a price cap. Exact matches aren't guaranteed."
                 : "A total spending target for the look. Tax and shipping excluded.")
                .font(.caption).foregroundStyle(FitStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var budgetHeading: some View { Text("Your fit. Your rules.").font(.title3.weight(.semibold)) }
    private var budgetAmount: some View {
        Text(store.budgetTitle).font(FitStyle.headline(28)).foregroundStyle(FitStyle.accent)
            .monospacedDigit().accessibilityIdentifier("budgetTotal")
    }

    private func budgetButton(_ tier: BudgetTier) -> some View {
        let selected = store.tier == tier
        return Button { store.tier = tier } label: {
            VStack(spacing: 5) {
                if let cents = tier.cents {
                    Text(usd(cents)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(tier.title.uppercased()).font(FitStyle.caption()).tracking(0.7)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: tier == .unlimited ? "infinity" : "slider.horizontal.3")
                        Text(tier.title).font(.subheadline.weight(.semibold))
                        if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                    }.padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: tier.cents == nil ? 44 : 64)
            .padding(.horizontal, 6)
            .foregroundStyle(selected ? FitStyle.accent : FitStyle.ink)
            .background(selected ? FitStyle.accent.opacity(0.09) : FitStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? FitStyle.accent : FitStyle.line, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tier.title + (tier.cents.map { ", \(usd($0)) total" } ?? ""))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("budget_\(tier.rawValue)")
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(number: "03", title: "YOUR DIRECTION")
                Spacer()
                Text("OPTIONAL").font(FitStyle.caption()).foregroundStyle(FitStyle.muted)
            }
            TextField("Oversized. Monochrome. After hours…", text: $store.context, axis: .vertical)
                .lineLimit(2...4).font(.subheadline).padding(16)
                .background(FitStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FitStyle.line))
                .accessibilityLabel("Style preferences, occasion, or colors to avoid")
                .disabled(store.isAnalyzing)
                .onChange(of: store.context) { value in
                    if value.count > 600 { store.context = String(value.prefix(600)) }
                    store.didSave = false
                }
        }
    }

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let message = store.error {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("errorMessage")
            }
            if store.isAnalyzing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the look…").font(.subheadline)
                    Spacer()
                    Button("Cancel", role: .cancel) { store.cancelAnalysis() }.frame(minHeight: 44)
                }.padding(16).background(FitStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            } else if store.needsAnalysis {
                Button {
                    if consent { store.analyze(endpoint: endpoint) } else { confirmAnalysis = true }
                } label: {
                    HStack {
                        Text(store.analysis == nil ? "Find my outfit" : "Update analysis")
                        Image(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(FitActionStyle(prominent: true))
                .disabled(store.photoData == nil || !store.hasValidBudget || store.isLoadingPhoto)
            }
            if let analysis = store.analysis, store.hasValidBudget {
                if store.needsAnalysis {
                    Text("Preferences changed. Update the analysis to apply them.")
                        .font(.footnote).foregroundStyle(FitStyle.muted)
                }
                OutfitResults(analysis: analysis, budgetCents: store.budgetCents)
                if !analysis.garments.isEmpty {
                    Button { store.saveLook() } label: {
                        Label(store.didSave ? "Look saved" : "Save this look", systemImage: store.didSave ? "checkmark" : "bookmark")
                    }
                    .buttonStyle(FitActionStyle()).disabled(store.didSave || store.needsAnalysis)
                }
            }
        }
    }
}

struct OutfitResults: View {
    let analysis: Analysis
    let budgetCents: Int?

    var body: some View {
        let allocations = budgetCents.map { Budget.allocate($0, garments: analysis.garments) } ?? []
        VStack(alignment: .leading, spacing: 18) {
            Rectangle().fill(FitStyle.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("THE BREAKDOWN").font(FitStyle.headline(32)).accessibilityAddTraits(.isHeader)
                Text(String(format: "%02d PIECES", analysis.garments.count))
                    .font(FitStyle.caption()).foregroundStyle(FitStyle.accent)
            }
            Text(analysis.summary).font(.subheadline).foregroundStyle(FitStyle.muted)
            if analysis.garments.isEmpty {
                Label("No clothing was clearly visible. Try another photo.", systemImage: "photo")
                    .foregroundStyle(FitStyle.muted)
            } else {
                ForEach(Array(analysis.garments.enumerated()), id: \.element.id) { index, garment in
                    garmentCard(garment, number: index + 1,
                                target: allocations.indices.contains(index) ? allocations[index] : nil)
                }
                Text(budgetCents == nil
                     ? "Searches have no price cap. Exact items, brands, availability, and prices are unverified."
                     : "Targets are budget allocations, not product prices. Search results may cost more; matches and availability are unverified.")
                    .font(.caption).foregroundStyle(FitStyle.muted)
            }
            if !analysis.limitations.isEmpty {
                Label(analysis.limitations, systemImage: "info.circle").font(.footnote).foregroundStyle(FitStyle.muted)
            }
        }
    }

    private func garmentCard(_ garment: Garment, number: Int, target: Int?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Text(String(format: "%02d", number)).font(FitStyle.headline(28)).foregroundStyle(FitStyle.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(garment.name).font(.headline)
                    Text(garment.color).font(.subheadline).foregroundStyle(FitStyle.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: garment.category.symbol).foregroundStyle(FitStyle.muted).accessibilityHidden(true)
            }
            Text(garment.details).font(.subheadline).foregroundStyle(FitStyle.muted)
            Rectangle().fill(FitStyle.line).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack { targetLabel(target); Spacer(minLength: 12); shoppingLink(garment, target: target) }
                VStack(alignment: .leading, spacing: 8) { targetLabel(target); shoppingLink(garment, target: target) }
            }
        }
        .padding(18).background(FitStyle.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FitStyle.line))
    }

    private func targetLabel(_ target: Int?) -> some View {
        Text(target.map { "Target \(usd($0))" } ?? "No price limit")
            .font(.subheadline.weight(.semibold)).monospacedDigit()
    }

    @ViewBuilder private func shoppingLink(_ garment: Garment, target: Int?) -> some View {
        if let url = garment.shoppingURL(budgetCents: target) {
            Link(destination: url) {
                Label("Search piece", systemImage: "arrow.up.right")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(FitStyle.accent).frame(minHeight: 44)
            }.accessibilityLabel("Search shopping for \(garment.name)")
        }
    }
}

struct SavedLooksView: View {
    @EnvironmentObject private var store: OutfitStore

    var body: some View {
        NavigationStack {
            Group {
                if store.saved.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        Image(systemName: "bookmark").font(.system(size: 36, weight: .light)).foregroundStyle(FitStyle.accent)
                        Text("BUILD YOUR\nROTATION.").font(FitStyle.headline(46))
                        Text("Save a look from Discover.\nKeep the ones that feel like you.")
                            .font(.subheadline).foregroundStyle(FitStyle.muted)
                    }
                    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    List {
                        Section {
                            ForEach(store.saved) { look in
                                NavigationLink {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 16) {
                                            SectionLabel(number: "↗", title: "SAVED LOOK")
                                            Text(look.budgetCents.map(usd) ?? "No limit")
                                                .font(FitStyle.headline(42)).foregroundStyle(FitStyle.accent)
                                            OutfitResults(analysis: look.analysis, budgetCents: look.budgetCents)
                                        }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
                                    }
                                    .background(FitStyle.background)
                                    .navigationTitle("Saved look").navigationBarTitleDisplayMode(.inline)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(look.analysis.summary).font(.headline).lineLimit(2).foregroundStyle(FitStyle.ink)
                                        Text("\(look.budgetCents.map(usd) ?? "No limit") · \(look.analysis.garments.count) pieces")
                                            .font(.subheadline).foregroundStyle(FitStyle.accent)
                                        Text(look.createdAt, style: .date).font(FitStyle.caption()).foregroundStyle(FitStyle.muted)
                                    }.padding(.vertical, 12)
                                }
                                .listRowBackground(FitStyle.surface)
                                .listRowSeparatorTint(FitStyle.line)
                            }.onDelete { offsets in store.delete(at: offsets) }
                        } header: {
                            Text("YOUR PERSONAL EDIT").font(FitStyle.caption()).tracking(1.4).foregroundStyle(FitStyle.muted)
                        }
                    }.scrollContentBackground(.hidden)
                }
            }
            .background(FitStyle.background)
            .navigationTitle("Saved looks").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FitStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { if !store.saved.isEmpty { EditButton() } }
            .overlay(alignment: .bottom) {
                if let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(.red).padding()
                        .background(FitStyle.surface, in: RoundedRectangle(cornerRadius: 8)).padding()
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    @MainActor static var previews: some View {
        ContentView().environmentObject(OutfitStore(preview: true))
            .previewDisplayName("Discover · dark")
    }
}
