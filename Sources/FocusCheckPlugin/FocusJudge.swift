import Foundation

/// Why a photo was marked.
enum FocusMiss: Equatable, Sendable {
  /// Nothing anywhere in the frame is sharp.
  case nothingSharp
  /// Nothing near the camera's focus points is sharp: focus landed somewhere else.
  case missedFocusZone
  /// The subject right under the locked focus points is soft, even if something else is sharp.
  case softAtFocusPoint

  var explanation: String {
    switch self {
    case .nothingSharp: "Nothing in the frame is sharp"
    case .missedFocusZone: "Blurry where the camera focused"
    case .softAtFocusPoint: "Soft at the focus point"
    }
  }

  /// The score this test failed, and the line it fell below.
  func failedScore(in score: FocusScore) -> Double? {
    switch self {
    case .nothingSharp: score.sharpness
    case .missedFocusZone: score.focusZone
    case .softAtFocusPoint: score.focusPoint
    }
  }

  var threshold: Double {
    switch self {
    case .nothingSharp: FocusJudge.unusableBelow
    case .missedFocusZone: FocusJudge.focusZoneBelow
    case .softAtFocusPoint: FocusJudge.focusPointBelow
    }
  }
}

enum FocusJudge {
  /// Below this, nothing in the frame is sharp. Calibrated by eye on 2,835 real photos: every
  /// photo confirmed unusable scored 0.33 or less, the softest usable photo 0.39, and pregame smoke
  /// 0.40. The same photos blurred by 3 pixels at the working size scored at most 0.17.
  static let unusableBelow = 0.34
  /// Below this around the focus points, the subject the photographer focused on is blurry. On
  /// the same 2,835 photos, every photo below it was a missed, blurred, or blocked shot (0.08–0.28),
  /// while usable photos whose reported point landed just beside a sharp player scored 0.32 and up.
  static let focusZoneBelow = 0.30
  /// Below this, the subject right under the locked points is soft. On a game the photographer
  /// labeled in full (619 photos), it caught 11 of their 16 misses, including frames where the crowd
  /// or a player behind was sharp, and marked none of their keepers; usable photos whose points
  /// sat on a sharp subject scored well above it.
  static let focusPointBelow = 0.5

  /// Why a photo is unusable, or nil to leave it alone. Photos with no detail to judge are left alone.
  static func miss(_ score: FocusScore) -> FocusMiss? {
    if let frame = score.sharpness, frame < unusableBelow { return .nothingSharp }
    if let zone = score.focusZone, zone < focusZoneBelow { return .missedFocusZone }
    if let point = score.focusPoint, point < focusPointBelow { return .softAtFocusPoint }
    return nil
  }

  /// The photos to mark, in file-name order.
  static func outOfFocus(_ scores: [FocusScore]) -> [(score: FocusScore, miss: FocusMiss)] {
    scores.compactMap { score in miss(score).map { (score, $0) } }
      .sorted { $0.score.file.lastPathComponent.localizedStandardCompare($1.score.file.lastPathComponent) == .orderedAscending }
  }
}

/// Counts only photos for which the analyzer found detail; unreadable and indeterminate photos
/// are kept separate from photos that passed the available focus checks.
struct FocusMetrics: Equatable {
  let passed: Int
  let missed: Int
  let indeterminate: Int
  let unreadable: Int

  init(scores: [FocusScore], requested: Int) {
    missed = scores.filter { FocusJudge.miss($0) != nil }.count
    indeterminate = scores.filter { $0.sharpness == nil && $0.focusZone == nil && $0.focusPoint == nil }.count
    passed = scores.count - missed - indeterminate
    unreadable = max(0, requested - scores.count)
  }
}
