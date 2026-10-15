import SwiftUI
import PhotosUI
import ImageIO

@MainActor
final class OutfitStore: ObservableObject {
    @Published var photo: UIImage?
    @Published var photoData: Data?
    @Published var analysis: Analysis?
    @Published var isLoadingPhoto = false
    @Published var isAnalyzing = false
    @Published var error: String?
    @Published var context = "" {
        didSet {
            guard context != oldValue else { return }
            cancelAnalysis()
            didSave = false
        }
    }
    @Published var tier: BudgetTier = .balanced { didSet { didSave = false } }
    @Published var customDollars = "250" { didSet { didSave = false } }
    @Published var saved: [SavedLook] = []
    @Published var didSave = false
    private var photoRevision = UUID()
    private var recognitionTask: Task<Void, Never>?
    private var recognitionRevision = UUID()
    private var lastContext = ""
    private let saveURL: URL?

    var budgetCents: Int? { tier.resolvedCents(customDollars: customDollars) }
    var hasValidBudget: Bool { tier.isValid(customDollars: customDollars) }
    var budgetTitle: String { tier == .unlimited ? "No limit" : budgetCents.map(usd) ?? "—" }
    var needsAnalysis: Bool { analysis == nil || context != lastContext }

    init(preview: Bool = false) {
        // Canvas previews never read or write the user's saved looks.
        if preview { saveURL = nil; return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("saved-looks.json")
        saveURL = url
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                saved = try JSONDecoder().decode([SavedLook].self, from: Data(contentsOf: url))
            }
        } catch { self.error = "Saved looks could not be loaded. \(error.localizedDescription)" }
    }

    func load(_ item: PhotosPickerItem?) async {
        cancelAnalysis()
        let revision = UUID()
        photoRevision = revision
        analysis = nil; photo = nil; photoData = nil; error = nil; didSave = false; isLoadingPhoto = false
        guard let item = item else { return }
        isLoadingPhoto = true
        defer { if revision == photoRevision { isLoadingPhoto = false } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), data.count <= 25_000_000 else {
                throw ConnectionError.message("Choose a photo smaller than 25 MB.")
            }
            let prepared = try await Task.detached(priority: .userInitiated) { () -> Data in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1600
                      ] as CFDictionary),
                      let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.82),
                      jpeg.count <= 3_000_000 else {
                    throw ConnectionError.message("This photo could not be read. Try a JPEG or PNG screenshot.")
                }
                return jpeg
            }.value
            guard revision == photoRevision else { return }
            photoData = prepared; photo = UIImage(data: prepared)
        } catch { if revision == photoRevision { self.error = error.localizedDescription } }
    }

    func analyze(endpoint: String) {
        guard let data = photoData, hasValidBudget, !isAnalyzing else { return }
        if !needsAnalysis { return }
        error = nil; isAnalyzing = true; didSave = false
        let revision = photoRevision
        let recognition = UUID()
        recognitionRevision = recognition
        let submittedContext = context
        recognitionTask = Task {
            defer { if recognition == recognitionRevision { isAnalyzing = false } }
            do {
                let result = try await RecognitionClient(endpoint: endpoint, token: TokenStore.read())
                    .analyze(image: data, context: submittedContext)
                guard !Task.isCancelled, revision == photoRevision, recognition == recognitionRevision, context == submittedContext else { return }
                analysis = result; lastContext = submittedContext
            } catch {
                if !Task.isCancelled, revision == photoRevision, recognition == recognitionRevision {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func cancelAnalysis() {
        recognitionRevision = UUID()
        recognitionTask?.cancel(); recognitionTask = nil; isAnalyzing = false
    }

    func saveLook() {
        guard let result = analysis, hasValidBudget, !needsAnalysis else { return }
        var next = saved
        next.insert(SavedLook(id: UUID(), createdAt: Date(), analysis: result, budgetCents: budgetCents), at: 0)
        next = Array(next.prefix(100))
        if persist(next) { didSave = true }
    }

    func delete(at offsets: IndexSet) {
        var next = saved
        next.remove(atOffsets: offsets)
        _ = persist(next)
    }

    @discardableResult private func persist(_ next: [SavedLook]) -> Bool {
        do {
            if let saveURL = saveURL {
                try JSONEncoder().encode(next).write(to: saveURL, options: [.atomic, .completeFileProtection])
            }
            saved = next
            return true
        } catch { self.error = "Could not save changes: \(error.localizedDescription)"; return false }
    }
}


// Each results screen owns a search session; saved looks cannot replace Discover's listings.
@MainActor
final class ProductSearchStore: ObservableObject {
    @Published private(set) var result: ProductSearchResponse?
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    private var searchedAnalysis: Analysis?
    private var searchedBudget: Int?
    private var task: Task<Void, Never>?
    private var revision = UUID()

    func response(for analysis: Analysis, budgetCents: Int?) -> ProductSearchResponse? {
        guard analysis == searchedAnalysis, budgetCents == searchedBudget else { return nil }
        return result
    }

    func search(analysis: Analysis, budgetCents: Int?, endpoint: String) {
        invalidate()
        guard !analysis.garments.isEmpty else { return }
        let requestRevision = revision
        searchedAnalysis = analysis
        searchedBudget = budgetCents
        isSearching = true
        task = Task {
            defer { if revision == requestRevision { isSearching = false; task = nil } }
            do {
                let response = try await RecognitionClient(endpoint: endpoint, token: TokenStore.read())
                    .findProducts(analysis: analysis, budgetCents: budgetCents)
                guard !Task.isCancelled, revision == requestRevision else { return }
                result = response
            } catch {
                guard !Task.isCancelled, revision == requestRevision else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
        isSearching = false
    }

    func invalidate() {
        cancel()
        result = nil
        error = nil
        searchedAnalysis = nil
        searchedBudget = nil
    }
}
