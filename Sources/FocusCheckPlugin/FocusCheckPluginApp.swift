import AppKit
import LightTableCore
import LightTablePluginKit
import SwiftUI

struct MarkedPhoto: Identifiable, Equatable, Sendable {
  let file: URL
  let score: FocusScore
  let miss: FocusMiss
  /// The values it had before, put back by Undo or Keep.
  let previous: CullingState
  /// It already showed the mark before Focus Check ran, so nothing was written to it.
  let alreadyMarked: Bool
  var id: String { file.path }
  /// The score that failed its test.
  var failedScore: Double { miss.failedScore(in: score) ?? 0 }
}

/// An out-of-focus photo left unmarked because the settings protect it.
struct ProtectedPhoto: Identifiable, Equatable, Sendable {
  let file: URL
  let miss: FocusMiss
  /// "Tagged" or "Rated 4 stars".
  let reason: String
  var id: String { file.path }
}

@MainActor final class FocusCheckModel: ObservableObject {
  @Published var files: [URL] = []
  @Published var allFolderFiles: [URL] = []
  @Published var selectedFiles: [URL] = []
  @Published var useWholeFolder = false { didSet {
    files = useWholeFolder ? allFolderFiles : selectedFiles
    marked = []; leftAlone = []; unreadable = []; metrics = nil; lastMark = nil
  } }
  var filterDeletionMarks: (() -> Void)?
  @Published var method: MarkMethod { didSet { defaults.set(method.rawValue, forKey: Keys.method) } }
  @Published var color: PhotoColor { didSet { defaults.set(color.rawValue, forKey: Keys.color) } }
  @Published var skipTagged: Bool { didSet { defaults.set(skipTagged, forKey: Keys.skipTagged) } }
  /// Photos rated this many stars or more are never marked; 0 turns this off.
  @Published var protectRating: Int { didSet { defaults.set(protectRating, forKey: Keys.protectRating) } }
  @Published var marked: [MarkedPhoto] = []
  @Published var leftAlone: [ProtectedPhoto] = []
  /// How the photos in `marked` were marked, which Undo and Keep reverse.
  @Published var lastMark: Mark?
  /// The marked photo shown at 100%, by id; nil shows the results.
  @Published var reviewing: String?
  @Published var checkedCount = 0
  @Published var metrics: FocusMetrics?
  @Published var unreadable: [String] = []
  @Published var busy = false
  @Published var status = "Select photos in Light Table, then open Focus Check."
  @Published var alert: String?
  var metadata: PluginMetadata?
  var progressChanged: ((Double, String, String) -> Void)?
  private var task: Task<Void, Never>?
  private var temporarySourceAccess: URL?
  private let sourceKey = "focus-check-source"
  private let defaults: UserDefaults
  /// Photos per metadata request; Light Table accepts up to 500.
  nonisolated static let requestLimit = 200

  private enum Keys {
    static let color = "focus-check-color", method = "focus-check-method-v2"
    static let skipTagged = "focus-check-skip-tagged", protectRating = "focus-check-protect-rating"
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.object(forKey: Keys.color) as? Int
    color = stored.flatMap(PhotoColor.init(rawValue:)).flatMap { $0 == PhotoColor.none ? nil : $0 } ?? .gray
    method = defaults.string(forKey: Keys.method).flatMap(MarkMethod.init(rawValue:)) ?? .deletion
    skipTagged = defaults.object(forKey: Keys.skipTagged) as? Bool ?? true
    protectRating = min(5, max(0, defaults.integer(forKey: Keys.protectRating)))
  }

  var protection: Protection { Protection(skipTagged: skipTagged, minimumRating: protectRating) }

  var sourceRoot: URL? {
    guard var components = files.first?.deletingLastPathComponent().standardizedFileURL.pathComponents else { return nil }
    for file in files.dropFirst() {
      let other = file.deletingLastPathComponent().standardizedFileURL.pathComponents
      while !components.isEmpty && (components.count > other.count || Array(other.prefix(components.count)) != components) {
        components.removeLast()
      }
    }
    guard !components.isEmpty else { return nil }
    return URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
  }

  func receive(paths: [String], selectedCount: Int? = nil, fileAccessBookmark: String? = nil) {
    if let encoded = fileAccessBookmark, let data = Data(base64Encoded: encoded) {
      var stale = false
      if let granted = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
        temporarySourceAccess?.stopAccessingSecurityScopedResource()
        _ = granted.startAccessingSecurityScopedResource()
        temporarySourceAccess = granted
      }
    }
    guard !busy else { return }
    var seen = Set<String>()
    files = paths.compactMap { path in
      let url = URL(fileURLWithPath: path).standardizedFileURL
      return seen.insert(url.path).inserted ? url : nil
    }
    allFolderFiles = files
    selectedFiles = Array(files.prefix(max(0, min(selectedCount ?? files.count, files.count))))
    files = useWholeFolder ? allFolderFiles : selectedFiles
    marked = []; leftAlone = []; unreadable = []; checkedCount = 0; metrics = nil; lastMark = nil; reviewing = nil
    status = files.isEmpty ? "No photos are selected in Light Table."
      : "\(files.count) photo\(files.count == 1 ? "" : "s") ready to check."
  }

  func findAndMark() {
    guard !files.isEmpty, let metadata, !busy else { return }
    guard grantAccess() else { return }
    let selected = files, mark = Mark(method, color: color), protection = protection
    busy = true; marked = []; leftAlone = []; unreadable = []; checkedCount = 0; metrics = nil; reviewing = nil; lastMark = mark
    status = "Checking focus on \(selected.count) photo\(selected.count == 1 ? "" : "s")…"
    progressChanged?(0.01, status, "running")
    task = Task {
      do {
        let scores = try await score(selected)
        metrics = FocusMetrics(scores: scores, requested: selected.count)
        let soft = FocusJudge.outOfFocus(scores)
        let states = try await read(soft.map(\.score.file), metadata: metadata)
        var found: [MarkedPhoto] = [], protected: [ProtectedPhoto] = []
        for (photo, state) in zip(soft, states) {
          if let reason = protection.reason(for: state, method: mark.method) {
            protected.append(ProtectedPhoto(file: photo.score.file, miss: photo.miss, reason: reason))
          } else {
            found.append(MarkedPhoto(file: photo.score.file, score: photo.score, miss: photo.miss, previous: state,
              alreadyMarked: mark.isShown(in: state)))
          }
        }
        let changing = found.filter { !$0.alreadyMarked }
        // The values are read back after writing: only what the files really say is reported.
        let missed = try await write(changing.map { ($0.file, mark.applied(to: $0.previous)) }, mark: mark, metadata: metadata)
        marked = found.filter { !missed.contains($0.file) }
        leftAlone = protected
        unreadable = selected.filter { file in !scores.contains { $0.file == file } }.map(\.lastPathComponent)
        if !missed.isEmpty {
          status = "Light Table didn't save the \(mark.valueName) on \(missed.count) of \(changing.count) photos."
          alert = "Light Table reported the changes as saved, but \(missed.count) of \(changing.count) photos still show their old \(mark.valueName). Quit and reopen Light Table, then run Focus Check again."
          progressChanged?(0, status, "failed")
        } else {
          let alone = protected.isEmpty ? "" : " Left \(protected.count) protected photo\(protected.count == 1 ? "" : "s") alone."
          status = !marked.isEmpty ? mark.summary(marked.count, of: scores.count) + alone
            : protected.isEmpty ? "None of the \(scores.count) photos is clearly out of focus." : "Nothing marked.\(alone)"
          progressChanged?(1, status, "complete")
        }
      } catch is CancellationError {
        status = "Cancelled. Nothing was marked."
        progressChanged?(0, status, "cancelled")
      } catch {
        status = error.localizedDescription; alert = error.localizedDescription
        progressChanged?(0, status, "failed")
      }
      busy = false
    }
  }

  /// Puts back each marked photo's previous label, rating, or tag.
  func undo() {
    guard let metadata, let mark = lastMark, !marked.isEmpty, !busy else { return }
    let restoring = marked.filter { !$0.alreadyMarked }
    busy = true; reviewing = nil
    Task {
      do {
        let missed = try await write(restoring.map { ($0.file, $0.previous) }, mark: mark, metadata: metadata)
        if missed.isEmpty {
          status = restoring.isEmpty ? "Nothing to undo: those photos already had that \(mark.valueName)."
            : "Put back the previous \(mark.valueName) of \(restoring.count) photo\(restoring.count == 1 ? "" : "s")."
          marked = []
        } else {
          marked = marked.filter { missed.contains($0.file) }
          alert = "Light Table reported the changes as undone, but \(missed.count) photo\(missed.count == 1 ? " still shows" : "s still show") the mark. Quit and reopen Light Table, then choose Undo again."
        }
      } catch { alert = error.localizedDescription }
      busy = false
    }
  }

  /// Puts back one marked photo's previous value and takes it off the list: for a photo the
  /// photographer finds usable at 100%.
  func keep(_ photo: MarkedPhoto) {
    guard let metadata, let mark = lastMark, !busy, marked.contains(photo) else { return }
    busy = true
    Task {
      do {
        var missed: Set<URL> = []
        if !photo.alreadyMarked { missed = try await write([(photo.file, photo.previous)], mark: mark, metadata: metadata) }
        if missed.isEmpty {
          let position = marked.firstIndex(of: photo) ?? 0
          marked.removeAll { $0.id == photo.id }
          if reviewing == photo.id { reviewing = marked.isEmpty ? nil : marked[min(position, marked.count - 1)].id }
          status = "Kept \(photo.file.lastPathComponent) (back to \(mark.describe(photo.previous)))."
        } else {
          alert = "Light Table reported the change as saved, but \(photo.file.lastPathComponent) still shows the mark. Quit and reopen Light Table, then choose Keep again."
        }
      } catch { alert = error.localizedDescription }
      busy = false
    }
  }

  /// Keeps the photo under review, unless it had the mark before Focus Check ran.
  func keepReviewed() {
    guard let photo = marked.first(where: { $0.id == reviewing }), !photo.alreadyMarked else { return }
    keep(photo)
  }

  /// Moves the review to the previous (-1) or next (+1) marked photo.
  func review(step: Int) {
    guard let position = marked.firstIndex(where: { $0.id == reviewing }), marked.indices.contains(position + step) else { return }
    reviewing = marked[position + step].id
  }

  func cancel() { task?.cancel() }

  /// Writes each photo's value for this mark, grouped by value in requests Light Table accepts,
  /// then reads the values back. Returns the photos whose files don't show the value written.
  private func write(_ targets: [(file: URL, state: CullingState)], mark: Mark, metadata: PluginMetadata) async throws -> Set<URL> {
    guard !targets.isEmpty else { return [] }
    let groups = Dictionary(grouping: targets) { mark.value(of: $0.state) }
    for value in groups.keys.sorted() {
      for chunk in groups[value, default: []].chunked(Self.requestLimit) {
        let files = chunk.map(\.file)
        switch mark.method {
        case .deletion: try await metadata.write(fields: ["LightTable:MarkedForDeletion": value != 0 ? "true" : "false"], to: files)
        case .colorLabel: try await metadata.write(color: value, to: files)
        case .oneStar: try await metadata.write(rating: value, to: files)
        case .untag: try await metadata.write(tagged: value != 0, to: files)
        }
      }
    }
    let saved = try await read(targets.map(\.file), metadata: metadata)
    return Set(zip(targets, saved).filter { mark.value(of: $0.1) != mark.value(of: $0.0.state) }.map { $0.0.file })
  }

  /// Each photo's rating, label, and tag as Light Table shows them.
  private func read(_ files: [URL], metadata: PluginMetadata) async throws -> [CullingState] {
    var states: [CullingState] = []
    for chunk in files.chunked(Self.requestLimit) {
      let tags = try await metadata.tags(for: Array(chunk))
      guard tags.count == chunk.count else {
        throw PluginMetadata.Failure.host("Light Table answered for \(tags.count) of \(chunk.count) photos.")
      }
      states += zip(chunk, tags).map { file, tags in
        var state = CullingState(tags: tags, locked: CullingState.isLocked(file))
        state.deletionMarked = PhotoState.load(file).markedForDeletion == true
        return state
      }
    }
    return states
  }

  /// Scores photos a few at a time, reporting progress as each finishes.
  private func score(_ files: [URL]) async throws -> [FocusScore] {
    var scores: [FocusScore] = []
    var done = 0
    try await withThrowingTaskGroup(of: FocusScore?.self) { group in
      var next = 0
      func addNext() {
        guard next < files.count else { return }
        let file = files[next]; next += 1
        group.addTask(priority: .userInitiated) {
          try Task.checkCancellation()
          return FocusAnalyzer.score(file)
        }
      }
      for _ in 0..<min(4, files.count) { addNext() }
      while let result = try await group.next() {
        if let result { scores.append(result) }
        done += 1
        checkedCount = done
        progressChanged?(0.95 * Double(done) / Double(files.count), status, "running")
        addNext()
      }
    }
    return scores
  }

  private var hasAccess: Bool {
    guard let root = sourceRoot else { return false }
    if let granted = temporarySourceAccess, Self.folder(granted, covers: root) { return true }
    guard let restored = PluginBookmarks.restore(sourceKey) else { return false }
    return Self.folder(restored, covers: root)
  }

  /// Compares real locations: a resolved folder grant names /private/var for a folder reached
  /// through /var, or a linked folder by its target.
  nonisolated static func folder(_ granted: URL, covers root: URL) -> Bool {
    let grantedPath = granted.resolvingSymlinksInPath().standardizedFileURL.path
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    return rootPath == grantedPath || rootPath.hasPrefix(grantedPath + "/")
  }

  @discardableResult private func grantAccess() -> Bool {
    if hasAccess { return true }
    guard let root = sourceRoot else { alert = "The selected photos do not share an accessible folder."; return false }
    let panel = NSOpenPanel()
    panel.title = "Allow access to selected photos"
    panel.message = "Choose \(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent) so Focus Check can read the selected photos. This access is remembered."
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.directoryURL = root.deletingLastPathComponent()
    guard panel.runModal() == .OK, let selected = panel.url else { return false }
    guard Self.folder(selected, covers: root) else {
      alert = "Choose the selected photos’ shared folder or one of its parent folders."
      return false
    }
    PluginBookmarks.remember(selected, key: sourceKey)
    return true
  }
}

@MainActor final class FocusCheckBridge: ObservableObject {
  let model = FocusCheckModel()
  let channel = PluginChannel(input: .standardInput, output: .standardOutput)
  let metadata: PluginMetadata
  @Published var appearance = "dark"
  var openWindow: (() -> Void)?

  init() {
    metadata = PluginMetadata(channel: channel)
    model.metadata = metadata
    model.filterDeletionMarks = { [weak self] in
      self?.channel.send(PluginMessage("result", payload: ["filterDeletionMarks": "true"]))
    }
    model.progressChanged = { [weak self] progress, detail, state in
      self?.channel.send(PluginMessage("progress", title: "Focus Check", detail: detail, progress: progress, state: state))
    }
    let metadata = metadata
    channel.listen(onDisconnect: { Task { @MainActor in NSApp.terminate(nil) } }) { [weak self] result in
      // Metadata replies are delivered here, off the main actor, so a waiting read can finish.
      if case .success(let message) = result, metadata.handle(message) { return }
      Task { @MainActor in
        guard let self, case .success(let message) = result else { return }
        if let appearance = message.appearance { self.appearance = appearance }
        switch message.command {
        case "shutdown": NSApp.terminate(nil)
        case "cancel": self.model.cancel()
        case "open", "settings", "details", nil:
          if let files = message.files {
            self.model.receive(paths: files, selectedCount: message.payload?["focusSelectedCount"].flatMap(Int.init), fileAccessBookmark: message.fileAccessBookmark)
          }
          self.openWindow?(); NSApp.activate(ignoringOtherApps: true)
          NSApp.windows.first?.makeKeyAndOrderFront(nil)
        // Newer hosts may send events this version does not know.
        default: return
        }
      }
    }
    channel.send(PluginMessage("ready"))
  }
}

@main struct FocusCheckPluginApp: App {
  @StateObject private var bridge = FocusCheckBridge()
  @Environment(\.openWindow) private var openWindow
  var body: some Scene {
    Window("Focus Check", id: "focus-check") {
      FocusCheckView().environmentObject(bridge.model)
        .frame(minWidth: 520, minHeight: 520).background(PluginStyle.canvas)
        .tint(PluginStyle.control)
        .preferredColorScheme(bridge.appearance == "light" ? .light : bridge.appearance == "system" ? nil : .dark)
        .onAppear { let action = openWindow; bridge.openWindow = { action(id: "focus-check") } }
    }.defaultSize(width: 620, height: 700)
  }
}

struct FocusCheckView: View {
  @EnvironmentObject var model: FocusCheckModel
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    Group {
      if model.reviewing != nil, model.marked.contains(where: { $0.id == model.reviewing }) {
        ReviewView()
      } else {
        results
      }
    }
    .alert("Focus Check", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
      Button("OK") { model.alert = nil }
    } message: { Text(model.alert ?? "") }
  }

  private var results: some View {
    VStack(spacing: 0) {
      PluginHeader(title: "Focus Check",
        subtitle: "Find photos in your selection that missed focus and mark them.",
        symbol: "scope").padding(.horizontal, 22)
      Divider()
      Form {
        Section {
          Toggle("Check all photos in current folder", isOn: $model.useWholeFolder)
            .disabled(model.busy || model.allFolderFiles.isEmpty)
          LabeledContent("To check", value: model.files.isEmpty ? "None" : "\(model.files.count)")
          if model.busy && model.checkedCount > 0 {
            LabeledContent("Checked", value: "\(model.checkedCount) of \(model.files.count)")
          }
        } header: { Text("Photos") } footer: {
          Text("Marks a photo when nothing in the frame is sharp, when nothing is sharp where the camera focused (the Canon AF zone with a margin), or when the subject right under the locked focus points is soft even though something else is sharp. Photos without Canon focus-point data get only the first test. Motion blur often keeps some crisp edges, so it isn't marked.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let metrics = model.metrics {
          Section("Focus results") {
            LabeledContent("Passed available checks", value: "\(metrics.passed)")
            LabeledContent("Out of focus", value: "\(metrics.missed)")
            LabeledContent("Not enough detail to judge", value: "\(metrics.indeterminate)")
            LabeledContent("Could not read", value: "\(metrics.unreadable)")
          }
        }
        Section {
          Picker("Mark by", selection: $model.method) {
            ForEach(MarkMethod.allCases) { Text($0.title).tag($0) }
          }
          if model.method == .colorLabel {
            Picker("Label", selection: $model.color) {
              ForEach(PhotoColor.allCases.filter { $0 != .none }) { Text($0.name).tag($0) }
            }
          }
        } header: { Text("Marking") } footer: {
          Text(methodNote).font(.caption).foregroundStyle(.secondary)
        }
        Section {
          Toggle("Skip tagged photos", isOn: $model.skipTagged).disabled(model.method == .untag)
          Picker("Skip photos rated", selection: $model.protectRating) {
            Text("Off").tag(0)
            ForEach(1...5, id: \.self) { stars in
              Text(String(repeating: "★", count: stars) + (stars < 5 ? " or more" : "")).tag(stars)
            }
          }
        } header: { Text("Protect your picks") } footer: {
          Text(model.method == .untag
            ? "Untagging changes only tagged photos, so it can't skip them; protect your best ones by rating instead. Protected photos are listed under Left alone."
            : "Protected photos are never marked; they're listed under Left alone.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if !model.marked.isEmpty, let mark = model.lastMark {
          Section {
            ForEach(model.marked) { photo in
              Button { model.reviewing = photo.id } label: { markedRow(photo, mark: mark) }
                .buttonStyle(.plain)
                .help("See \(photo.file.lastPathComponent) at 100% where the camera focused")
            }
          } header: { Text(mark.resultTitle) } footer: {
            Text("Click a photo to see it at 100% where the camera focused, and keep it if it's usable.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if !model.leftAlone.isEmpty {
          Section {
            ForEach(model.leftAlone) { photo in
              HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(photo.file.lastPathComponent).font(.callout)
                  Text(photo.miss.explanation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(photo.reason).font(.caption).foregroundStyle(.secondary)
              }
            }
          } header: { Text("Left alone") } footer: {
            Text("Out of focus, but protected by your settings, so not marked.").font(.caption).foregroundStyle(.secondary)
          }
        }
        if !model.unreadable.isEmpty {
          Section("Not checked") {
            Text(model.unreadable.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
          }
        }
      }.formStyle(.grouped).scrollContentBackground(.hidden)
      Divider()
      HStack(spacing: 12) {
        if model.busy { ProgressView().controlSize(.small) }
        Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
        if model.busy {
          Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
        } else {
          if !model.marked.isEmpty, let mark = model.lastMark {
            Button("Undo", action: model.undo).help("Put back each photo's previous \(mark.valueName)")
          }
          if model.lastMark?.method == .deletion && model.metrics != nil {
            Button("Close & Hide Deletion Marks") { model.filterDeletionMarks?(); close() }
              .help("Return to Light Table and hide photos marked for deletion")
          }
          Button("Close", action: close).keyboardShortcut(.cancelAction)
            .help("Close Focus Check and go back to Light Table")
        }
        Button("Find & Mark", action: model.findAndMark).buttonStyle(.borderedProminent)
          .disabled(model.busy || model.files.isEmpty)
      }.padding(16)
    }
  }

  private func markedRow(_ photo: MarkedPhoto, mark: Mark) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(photo.file.lastPathComponent).font(.callout)
        Text(photo.alreadyMarked
          ? "\(photo.miss.explanation) · already \(mark.describe(mark.applied(to: photo.previous)))"
          : photo.miss.explanation)
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text(photo.failedScore.formatted(.number.precision(.fractionLength(2))))
        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        .help(scoreHelp(photo.miss))
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
    }.contentShape(Rectangle())
  }

  private var methodNote: String {
    switch model.method {
    case .deletion: "Marks photos for later deletion. No photos are deleted."
    case .colorLabel: "Gives each out-of-focus photo the label. Ratings and tags stay as they are."
    case .oneStar: "Gives each out-of-focus photo a 1-star rating in place of any rating it had. Labels and tags stay as they are."
    case .untag: "Removes the tag from each out-of-focus photo. Ratings and labels stay as they are."
    }
  }

  private func scoreHelp(_ miss: FocusMiss) -> String {
    switch miss {
    case .nothingSharp: "Whole-frame focus score: usable photos score 0.39 and up; below 0.34 nothing is sharp"
    case .missedFocusZone: "Focus-zone score: below 0.30 nothing near the focus points is sharp"
    case .softAtFocusPoint: "Focus-point score: below 0.5 the subject under the locked points is soft"
    }
  }

  /// Closes the window and hides Focus Check, so Light Table is in front again. Light Table opens
  /// the window again from the Plugins menu.
  private func close() {
    dismissWindow(id: "focus-check")
    NSApp.hide(nil)
  }
}
