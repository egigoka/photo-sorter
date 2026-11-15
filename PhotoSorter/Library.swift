import Photos
import SwiftUI

/// A short-lived banner that confirms an edit.
struct Toast: Equatable {
    /// Changes with every banner, so the same text can show two times in a row.
    let id: Int
    let text: String
    /// True when the banner can take the edit back.
    let canUndo: Bool
}

/// Results of a scan that the library did not take yet. The scan makes them on many threads.
private final class ScanResults: @unchecked Sendable {
    private let lock = NSLock()
    private var classified: [(String, Item)] = []
    private var processed = 0
    private var total = 0
    private var last: SortedPhoto?

    /// Adds the result for one photo. Nil when the photo was skipped.
    func add(_ item: Item?, for asset: PHAsset) {
        lock.lock()
        defer { lock.unlock() }
        if let item {
            classified.append((asset.localIdentifier, item))
            last = SortedPhoto(asset: asset, category: item.category)
        }
        processed += 1
        total += 1
    }

    /// Hands over the results since the last call, the number of photos that they come from, the
    /// number of photos since the start of the scan, and the photo that was sorted last.
    func take() -> (classified: [(String, Item)], processed: Int, total: Int, last: SortedPhoto?) {
        lock.lock()
        defer { lock.unlock() }
        let taken = (classified, processed, total, last)
        classified = []
        processed = 0
        return taken
    }
}

/// A photo that a scan put on a pile.
struct SortedPhoto {
    let asset: PHAsset
    let category: Category
}

@MainActor
@Observable
final class Library {
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var counts: [Category: Int] = [:]
    private(set) var scanning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var skipped = 0
    private(set) var rate = 0.0
    /// Number of photos that the scan sorted since it started.
    private(set) var scanned = 0
    /// True when the last scan ran to its end. False when it was stopped or failed.
    private(set) var finished = false
    /// The photo that the scan sorted last. No view observes it: it changes many times per second.
    @ObservationIgnored private(set) var lastSorted: SortedPhoto?
    /// Error text, shown as an alert.
    var message: String?
    /// Confirmation of the last edit, shown as a short-lived banner.
    private(set) var toast: Toast?

    @ObservationIgnored private(set) var items: [String: Item] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Number of photos that a scan sorted since the results were saved.
    @ObservationIgnored private var unsaved = 0
    /// Time when a scan saved its results last.
    @ObservationIgnored private var saved = Date()
    @ObservationIgnored private var toastCount = 0
    /// The photos as they were before the last edit. Empty when the edit cannot be undone.
    @ObservationIgnored private var beforeEdit: [String: Item] = [:]
    /// Takes back the last edit, when a view keeps that edit and not the library.
    @ObservationIgnored private var undoAction: (() -> Void)?

    private static let storeURL = URL.applicationSupportDirectory.appending(path: "items-v2.json")
    private static let saveQueue = DispatchQueue(label: "me.egigoka.photosorter.save", qos: .userInitiated)
    /// Seconds after which a running scan saves its results again.
    private static let saveInterval = 5.0
    /// Key of the user default that holds the signature of the models that made the results.
    private static let modelsKey = "models"

    init() {
        // Results in a category that no longer exists are dropped, so the next scan sorts those photos again.
        struct Stored: Decodable {
            let category: String
            let confidence: Float
            let before: String?
            let ignoredAt: Date?
        }
        if let data = try? Data(contentsOf: Self.storeURL),
           let saved = try? JSONDecoder().decode([String: Stored].self, from: data) {
            items = saved.compactMapValues { stored in
                Category(rawValue: stored.category).map {
                    Item(
                        category: $0, confidence: stored.confidence,
                        before: stored.before.flatMap(Category.init(rawValue:)), ignoredAt: stored.ignoredAt
                    )
                }
            }
            recount()
        }
    }

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }

    /// Number of photos that have a category.
    var sorted: Int { counts.values.reduce(0, +) }

    func count(in category: Category) -> Int { counts[category] ?? 0 }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func identifiers(in category: Category) -> [String] {
        items.compactMap { $0.value.category == category ? $0.key : nil }
    }

    /// The photos of a category in the order that the app shows them: newest photo first.
    /// Ignored photos are in the order of the ignore action, last ignored first.
    func photos(in category: Category, limit: Int? = nil) async -> [PHAsset] {
        let ids = identifiers(in: category)
        guard !ids.isEmpty else { return [] }
        var ignoreTimes: [String: Date] = [:]
        if category == .ignored {
            for id in ids { ignoreTimes[id] = items[id]?.ignoredAt }
        }
        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            // Photos with an ignore time are sorted below, so the fetch cannot stop early.
            if ignoreTimes.isEmpty, let limit { options.fetchLimit = limit }
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
            var assets = result.objects(at: IndexSet(integersIn: 0..<result.count))
            if !ignoreTimes.isEmpty {
                // Photos with the same ignore time, or with none, stay newest photo first.
                assets = assets.enumerated().sorted { left, right in
                    let leftTime = ignoreTimes[left.element.localIdentifier] ?? .distantPast
                    let rightTime = ignoreTimes[right.element.localIdentifier] ?? .distantPast
                    return leftTime == rightTime ? left.offset < right.offset : leftTime > rightTime
                }.map(\.element)
            }
            return limit.map { Array(assets.prefix($0)) } ?? assets
        }.value
    }

    // MARK: Scan

    func startScan() {
        guard !scanning, hasAccess else { return }
        scanning = true
        saved = Date()
        finished = false
        skipped = 0
        rate = 0
        scanned = 0
        lastSorted = nil
        UIApplication.shared.isIdleTimerDisabled = true
        let known = Set(items.keys)

        task = Task.detached(priority: .userInitiated) { [weak self] in
            // True when the scan sorted every photo that it had to sort.
            var completed = false
            do {
                let all = PHAsset.fetchAssets(with: .image, options: nil)
                var present = Set<String>()
                var pending: [PHAsset] = []
                all.enumerateObjects { asset, _, _ in
                    present.insert(asset.localIdentifier)
                    if !known.contains(asset.localIdentifier) { pending.append(asset) }
                }
                guard !pending.isEmpty else {
                    // No photo is new. The models take seconds to load, so they stay unloaded.
                    await self?.finishEmpty(present: present)
                    return
                }
                let classifiers = try Classifier.loadAll()
                await self?.begin(present: present, pending: pending.count)

                let started = Date()
                let results = ScanResults()
                // The library takes the results when a batch is done. A batch can take seconds:
                // then the library also takes them each half second, so the progress keeps moving.
                let reporter = Task.detached(priority: .userInitiated) { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        await self?.take(results, started: started)
                    }
                }
                defer { reporter.cancel() }

                let batchSize = 24
                var index = 0
                while index < pending.count, !Task.isCancelled {
                    let batch = Array(pending[index..<min(index + batchSize, pending.count)])
                    DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                        autoreleasepool {
                            results.add(Analyzer.analyze(batch[i], classifiers: classifiers), for: batch[i])
                        }
                    }
                    index += batch.count
                    await self?.take(results, started: started)
                }
                reporter.cancel()
                await self?.take(results, started: started)
                completed = !Task.isCancelled
            } catch {
                await self?.report(String(localized: "Scan failed: \(error.localizedDescription)"))
            }
            await self?.finish(completed: completed)
        }
    }

    func stopScan() {
        task?.cancel()
    }

    /// Sorts the photos that came to the library since the last scan. Call once after launch.
    /// When no photo is new, the scan does not start and the piles stay on the screen.
    /// A library with no results waits for the scan button.
    func scanNewPhotos() async {
        guard hasAccess, !scanning, sorted > 0 else { return }
        let known = Set(items.keys)
        let found = await Task.detached(priority: .userInitiated) {
            var found = false
            PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, stop in
                guard !known.contains(asset.localIdentifier) else { return }
                found = true
                stop.pointee = true
            }
            return found
        }.value
        if found { startScan() }
    }

    /// True when a scan has results to forget.
    var canResetScan: Bool { !scanning && sorted > count(in: .ignored) }

    /// Forgets every result and every move between piles, then sorts the library again.
    /// Ignored photos stay ignored.
    func resetScan() {
        guard canResetScan else { return }
        forgetResults()
        startScan()
    }

    /// Sorts the library again when this version has other models than the version that made the
    /// results. Ignored photos stay ignored. Call once after launch.
    func checkModels() async {
        let signature = await Task.detached(priority: .userInitiated) { Classifier.signature() }.value
        // A scan that started in the meantime has the new models. The next launch checks again.
        guard let signature, !scanning else { return }
        let defaults = UserDefaults.standard
        let before = defaults.string(forKey: Self.modelsKey)
        defaults.set(signature, forKey: Self.modelsKey)
        // A version that did not record its models leaves no value. Its results stay.
        guard let before, before != signature, canResetScan else { return }
        forgetResults()
        startScan()
        confirm(String(localized: "The models changed. Sorting every photo again."))
    }

    private func forgetResults() {
        // Undo must not bring back a forgotten result.
        dismissToast()
        items = items.filter { $0.value.category == .ignored }
        recount()
        persist()
    }

    private func begin(present: Set<String>, pending: Int) {
        // Drop results for photos that no longer exist.
        items = items.filter { present.contains($0.key) }
        recount()
        total = present.count
        done = present.count - pending
    }

    /// Takes the results that the scan made since the last call.
    private func take(_ results: ScanResults, started: Date) {
        let new = results.take()
        // No photo is done since the last call. The speed stays, so the time that is left does not jump.
        guard new.processed > 0 else { return }
        for (id, item) in new.classified {
            items[id] = item
            counts[item.category, default: 0] += 1
        }
        done += new.classified.count
        scanned += new.classified.count
        lastSorted = new.last
        skipped += new.processed - new.classified.count
        rate = Double(new.total) / max(Date().timeIntervalSince(started), 0.001)
        unsaved += new.processed
        // The scan saves as it goes. A crash loses the last seconds only.
        if Date().timeIntervalSince(saved) >= Self.saveInterval { saveProgress(inBackground: true) }
    }

    /// Saves the results that a running scan made since it saved last. The app calls this when it
    /// leaves the screen: iOS can end an app in the background without a warning.
    func saveProgress(inBackground: Bool = false) {
        guard unsaved > 0 else { return }
        unsaved = 0
        saved = Date()
        persist(inBackground: inBackground)
    }

    /// Ends a scan that found no new photo.
    private func finishEmpty(present: Set<String>) {
        begin(present: present, pending: 0)
        finish(completed: true)
    }

    private func finish(completed: Bool) {
        finished = completed
        scanning = false
        task = nil
        unsaved = 0
        UIApplication.shared.isIdleTimerDisabled = false
        persist()
    }

    private func report(_ text: String) {
        message = text
    }

    // MARK: Edits

    func move(_ ids: [String], to category: Category) {
        let before = snapshot(ids)
        for id in ids {
            items[id]?.category = category
            items[id]?.before = nil
        }
        recount()
        persist()
        confirm(String(localized: "Moved \(ids.count) photos to \(category.title)"), before: before)
    }

    /// Keeps the photos out of every cleanup pile. A later scan does not sort them again.
    func ignore(_ ids: [String]) {
        let before = snapshot(ids)
        let now = Date.now
        for id in ids {
            guard var item = items[id], item.category != .ignored else { continue }
            item.before = item.category
            item.category = .ignored
            item.ignoredAt = now
            items[id] = item
        }
        recount()
        persist()
        confirm(String(localized: "Ignored \(ids.count) photos"), before: before)
    }

    /// Returns ignored photos to the category they had before.
    func unignore(_ ids: [String]) {
        let before = snapshot(ids)
        var unknown = false
        for id in ids {
            guard let item = items[id], item.category == .ignored else { continue }
            if let before = item.before {
                items[id] = Item(category: before, confidence: item.confidence)
            } else {
                // The earlier category is unknown, so a scan sorts the photo again.
                items[id] = nil
                unknown = true
            }
        }
        recount()
        persist()
        confirm(String(localized: "Unignored \(ids.count) photos"), before: before)
        if unknown { startScan() }
    }

    /// Returns true when the photos were deleted.
    @discardableResult
    func delete(_ assets: [PHAsset]) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            for asset in assets { items[asset.localIdentifier] = nil }
            recount()
            persist()
            confirm(String(localized: "Deleted \(assets.count) photos"))
            return true
        } catch let error as PHPhotosError where error.code == .userCancelled {
            // User declined the system confirmation.
        } catch {
            message = String(localized: "Delete failed: \(error.localizedDescription)")
        }
        return false
    }

    func addToAlbum(_ assets: [PHAsset], named name: String) async {
        var existing: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, stop in
                if collection.localizedTitle == name {
                    existing = collection
                    stop.pointee = true
                }
            }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = existing.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                    ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                request.addAssets(assets as NSArray)
            }
            confirm(String(localized: "Added \(assets.count) photos to “\(name)”"))
        } catch {
            message = String(localized: "Album update failed: \(error.localizedDescription)")
        }
    }

    /// Takes back the last move, ignore, unignore or mark. A deleted photo cannot come back from here.
    func undo() {
        if let undoAction {
            dismissToast()
            undoAction()
            return
        }
        guard !beforeEdit.isEmpty else { return }
        let count = beforeEdit.count
        for (id, item) in beforeEdit { items[id] = item }
        recount()
        persist()
        confirm(String(localized: "Put back \(count) photos"))
    }

    func dismissToast() {
        toast = nil
        beforeEdit = [:]
        undoAction = nil
    }

    /// Shows a banner for an edit that a view keeps, such as a mark in the viewer.
    /// Undo in the banner runs the given action.
    func confirm(_ text: String, undo: @escaping () -> Void) {
        confirm(text)
        undoAction = undo
        toast = Toast(id: toastCount, text: text, canUndo: true)
    }

    /// Shows a banner. With the photos as they were before the edit, the banner offers Undo.
    private func confirm(_ text: String, before: [String: Item] = [:]) {
        toastCount += 1
        beforeEdit = before
        undoAction = nil
        toast = Toast(id: toastCount, text: text, canUndo: !before.isEmpty)
    }

    private func snapshot(_ ids: [String]) -> [String: Item] {
        ids.reduce(into: [:]) { result, id in result[id] = items[id] }
    }

    // MARK: Storage

    private func recount() {
        var fresh: [Category: Int] = [:]
        for item in items.values { fresh[item.category, default: 0] += 1 }
        counts = fresh
    }

    /// Saves the results. All saves go through one queue, so an older save never replaces a newer one.
    /// A running scan saves in the background: the save of a large library takes a part of a second,
    /// and the screen must not stop for it.
    private func persist(inBackground: Bool = false) {
        let items = items
        let url = Self.storeURL
        let save: @Sendable () -> String? = {
            do {
                try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(items).write(to: url, options: .atomic)
                return nil
            } catch {
                return String(localized: "Could not save results: \(error.localizedDescription)")
            }
        }
        if inBackground {
            Self.saveQueue.async { [weak self] in
                guard let failure = save() else { return }
                Task { @MainActor [weak self] in self?.message = failure }
            }
        } else if let failure = Self.saveQueue.sync(execute: save) {
            message = failure
        }
    }
}
