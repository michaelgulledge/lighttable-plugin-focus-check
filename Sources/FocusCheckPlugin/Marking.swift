import Darwin
import Foundation
import LightTableCore

/// A photo's rating, color label, and tag as Light Table shows them.
struct CullingState: Equatable, Hashable, Sendable {
  var rating = 0
  var color = PhotoColor.none
  var tagged = false
  var deletionMarked = false

  init(rating: Int = 0, color: PhotoColor = .none, tagged: Bool = false) {
    self.rating = rating; self.color = color; self.tagged = tagged
  }

  /// Reads the values the way Light Table does: Photo Mechanic's own rating, color class, and tag
  /// first; its preferences string ("tag:color:rating:…") fills in what they leave out; and a
  /// photo with no tag value at all counts as tagged when its file is locked, as the camera's
  /// protect setting leaves it. `tags` are the photo's tags as Light Table reports them.
  init(tags: [String: String], locked: Bool) {
    // The first of the keys present, as Light Table's reader takes it (even when empty).
    func string(_ keys: String...) -> String { keys.lazy.compactMap { tags[$0] }.first ?? "" }
    rating = max(0, min(5, Int(string("XMP-xmp:Rating", "PhotoMechanic:Rating")) ?? 0))
    let code = Int(string("XMP-photomech:ColorClass", "PhotoMechanic:ColorClass", "IPTC:Urgency")) ?? 0
    color = code > 0 ? (PhotoColor(rawValue: code) ?? .none) : PhotoColor.from(label: string("XMP-xmp:Label"))
    let tag = string("XMP-photomech:Tagged", "PhotoMechanic:Tagged").lowercased()
    tagged = ["1", "true", "yes"].contains(tag)
    let prefs = string("XMP-photomech:Prefs").components(separatedBy: ":")
    if tag.isEmpty, prefs.count >= 3 {
      tagged = prefs[0] == "1"
      if code == 0 { color = PhotoColor(rawValue: Int(prefs[1]) ?? 0) ?? .none }
      if rating == 0 { rating = min(5, max(0, Int(prefs[2]) ?? 0)) }
    }
    if tag.isEmpty && prefs.count < 3 { tagged = locked }
  }

  /// Whether Light Table treats the file as camera-protected: locked (the flag a camera's protect
  /// setting leaves on a card), on a read-only volume, or with no write permission at all. These
  /// are the file's own attributes, so the answer doesn't depend on the plugin's sandbox.
  static func isLocked(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isUserImmutableKey, .volumeIsReadOnlyKey])
    var status = stat()
    let noWritePermission = lstat(url.path, &status) == 0 && Int(status.st_mode) & 0o222 == 0
    return values?.isUserImmutable == true || values?.volumeIsReadOnly == true || noWritePermission
  }
}

/// How Focus Check marks a photo it finds out of focus.
enum MarkMethod: String, CaseIterable, Identifiable, Sendable {
  case deletion, colorLabel, oneStar, untag
  var id: String { rawValue }
  var title: String {
    switch self {
    case .deletion: "Mark for deletion"
    case .colorLabel: "Color label"
    case .oneStar: "1-star rating"
    case .untag: "Untagging"
    }
  }
}

/// What one run of Find & Mark gives each photo: a color label, a 1-star rating, or no tag.
struct Mark: Equatable, Sendable {
  let method: MarkMethod
  /// The label, for a color-label mark.
  let color: PhotoColor

  init(_ method: MarkMethod, color: PhotoColor = .gray) {
    self.method = method; self.color = color
  }

  /// The values a photo has once marked.
  func applied(to state: CullingState) -> CullingState {
    var marked = state
    switch method {
    case .deletion: marked.deletionMarked = true
    case .colorLabel: marked.color = color
    case .oneStar: marked.rating = 1
    case .untag: marked.tagged = false
    }
    return marked
  }

  /// Whether a photo with these values already shows the mark, so nothing needs writing.
  func isShown(in state: CullingState) -> Bool { value(of: state) == value(of: applied(to: state)) }

  /// The one value this mark changes, as Light Table stores it; photos that share it are written
  /// together.
  func value(of state: CullingState) -> Int {
    switch method {
    case .deletion: state.deletionMarked ? 1 : 0
    case .colorLabel: state.color.rawValue
    case .oneStar: state.rating
    case .untag: state.tagged ? 1 : 0
    }
  }

  /// The value's name for messages: "label", "rating", or "tag".
  var valueName: String {
    switch method {
    case .deletion: "deletion mark"
    case .colorLabel: "label"
    case .oneStar: "rating"
    case .untag: "tag"
    }
  }

  /// The results heading.
  var resultTitle: String {
    switch method {
    case .deletion: "Marked for deletion"
    case .colorLabel: "Marked \(color.name)"
    case .oneStar: "Rated 1 star"
    case .untag: "Untagged"
    }
  }

  /// "Marked 3 of 120 photos Trash.", "Rated 3 of 120 photos 1 star.", "Untagged 3 of 120 photos."
  func summary(_ count: Int, of total: Int) -> String {
    let photos = "\(count) of \(total) photo\(total == 1 ? "" : "s")"
    switch method {
    case .deletion: return "Marked \(photos) for deletion."
    case .colorLabel: return "Marked \(photos) \(color.name)."
    case .oneStar: return "Rated \(photos) 1 star."
    case .untag: return "Untagged \(photos)."
    }
  }

  /// How a photo's value reads before or after marking: "Trash", "no label", "3 stars", "tagged".
  func describe(_ state: CullingState) -> String {
    switch method {
    case .deletion: state.deletionMarked ? "marked for deletion" : "not marked for deletion"
    case .colorLabel: state.color == .none ? "no label" : state.color.name
    case .oneStar: state.rating == 0 ? "no rating" : "\(state.rating) star\(state.rating == 1 ? "" : "s")"
    case .untag: state.tagged ? "tagged" : "not tagged"
    }
  }
}

/// The photos Focus Check never marks, so a pick is never labeled a reject.
struct Protection: Equatable, Sendable {
  var skipTagged = true
  /// Photos rated this many stars or more are left alone; 0 turns this off.
  var minimumRating = 0

  /// Why a photo with these values is left alone, or nil to mark it. Untagging only changes tagged
  /// photos, so skipping tagged ones doesn't apply to it.
  func reason(for state: CullingState, method: MarkMethod) -> String? {
    if skipTagged, method != .untag, state.tagged { return "Tagged" }
    if minimumRating > 0, state.rating >= minimumRating { return "Rated \(state.rating) star\(state.rating == 1 ? "" : "s")" }
    return nil
  }
}

extension Array {
  /// The array in consecutive pieces of at most `size` elements.
  func chunked(_ size: Int) -> [ArraySlice<Element>] {
    stride(from: 0, to: count, by: Swift.max(1, size)).map { self[$0..<Swift.min($0 + size, count)] }
  }
}
