import CoreImage
import ImageIO
import LightTableCore
import LightTablePluginKit
import UniformTypeIdentifiers
import XCTest
@testable import FocusCheckPlugin

final class FocusCheckTests: XCTestCase {
  private let context = CIContext()

  func testOnlyAPhotoBlurredAllOverIsBelowTheLine() throws {
    let sharp = texture(contrast: 1)
    let sharpScore = try XCTUnwrap(FocusAnalyzer.sharpness(of: sharp))
    let dimScore = try XCTUnwrap(FocusAnalyzer.sharpness(of: texture(contrast: 0.15)))
    let blurredScore = try XCTUnwrap(FocusAnalyzer.sharpness(of: blur(sharp, radius: 3)))
    XCTAssertGreaterThan(sharpScore, FocusJudge.unusableBelow * 2)
    XCTAssertGreaterThan(dimScore, FocusJudge.unusableBelow * 2, "A low-contrast scene must not read as soft")
    XCTAssertLessThan(blurredScore, FocusJudge.unusableBelow, "A 3-pixel blur over the whole frame is unusable")
  }

  func testAnySharpPartKeepsAPhotoUnmarked() throws {
    // Blur everything, then put a sharp patch in the middle, like a player against a soft crowd.
    let size = 400
    let sharp = texture(size: size, contrast: 1)
    let background = blur(sharp, radius: 6)
    let canvas = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    canvas.draw(background, in: CGRect(x: 0, y: 0, width: size, height: size))
    let patch = CGRect(x: 140, y: 140, width: 120, height: 120)
    canvas.draw(try XCTUnwrap(sharp.cropping(to: patch)), in: patch)
    let player = try XCTUnwrap(FocusAnalyzer.sharpness(of: try XCTUnwrap(canvas.makeImage())))
    let crowdOnly = try XCTUnwrap(FocusAnalyzer.sharpness(of: background))
    XCTAssertGreaterThan(player, FocusJudge.unusableBelow * 2, "A sharp player keeps the photo")
    XCTAssertLessThan(crowdOnly, FocusJudge.unusableBelow, "With the player missing, the frame is unusable")
  }

  func testOnlyClearMissesAreMarkedAndBlankFramesAreLeftAlone() {
    func score(_ name: String, _ sharpness: Double?) -> FocusScore {
      FocusScore(file: URL(fileURLWithPath: "/x/\(name).jpg"), sharpness: sharpness)
    }
    let scores = [score("miss", 0.1), score("soft-but-usable", 0.39), score("sharp", 1.2), score("blank-sky", nil),
      score("another-miss", 0.33)]
    XCTAssertEqual(FocusJudge.outOfFocus(scores).map { $0.score.file.deletingPathExtension().lastPathComponent },
      ["another-miss", "miss"])
  }

  func testFocusMetricsSeparateMissesIndeterminateAndUnreadable() {
    let scores = [
      FocusScore(file: URL(fileURLWithPath: "/sharp.jpg"), sharpness: 0.8),
      FocusScore(file: URL(fileURLWithPath: "/soft.jpg"), sharpness: 0.1),
      FocusScore(file: URL(fileURLWithPath: "/blank.jpg"), sharpness: nil),
    ]
    let metrics = FocusMetrics(scores: scores, requested: 4)
    XCTAssertEqual(metrics.passed, 1)
    XCTAssertEqual(metrics.missed, 1)
    XCTAssertEqual(metrics.indeterminate, 1)
    XCTAssertEqual(metrics.unreadable, 1)
  }

  func testDeletionMarkPreservesOtherCullingValues() {
    let before = CullingState(rating: 4, color: .red, tagged: true)
    let mark = Mark(.deletion)
    let after = mark.applied(to: before)
    XCTAssertTrue(after.deletionMarked)
    XCTAssertEqual(after.rating, before.rating)
    XCTAssertEqual(after.color, before.color)
    XCTAssertEqual(after.tagged, before.tagged)
    XCTAssertEqual(mark.value(of: before), 0)
    XCTAssertEqual(mark.value(of: after), 1)
    XCTAssertTrue(mark.isShown(in: after))
  }

  func testCullingValuesAreReadTheWayLightTableReadsThem() {
    func state(_ tags: [String: String], locked: Bool = false) -> CullingState { CullingState(tags: tags, locked: locked) }
    XCTAssertEqual(state(["XMP-photomech:ColorClass": "2", "XMP-xmp:Rating": "4", "XMP-photomech:Tagged": "True"]),
      CullingState(rating: 4, color: .red, tagged: true))
    XCTAssertEqual(state(["XMP-xmp:Label": "Green"]).color, .green)
    XCTAssertEqual(state(["XMP-xmp:Label": "Trash"]).color, .gray, "Light Table's own label names count")
    XCTAssertEqual(state(["PhotoMechanic:ColorClass": "7", "PhotoMechanic:Rating": "2", "PhotoMechanic:Tagged": "yes"]),
      CullingState(rating: 2, color: .brown, tagged: true))
    XCTAssertEqual(state(["IPTC:Urgency": "5"]).color, .green, "Light Table falls back to the IPTC urgency")
    XCTAssertEqual(state(["XMP-xmp:Rating": "9"]).rating, 5)
    XCTAssertEqual(state([:]), CullingState())
    // Photo Mechanic's preferences string ("tag:color:rating:…") fills in what is missing.
    XCTAssertEqual(state(["XMP-photomech:Prefs": "1:3:4:0"]), CullingState(rating: 4, color: .orange, tagged: true))
    XCTAssertEqual(state(["XMP-photomech:Prefs": "1:3:4:0", "XMP-photomech:ColorClass": "8", "XMP-xmp:Rating": "2"]),
      CullingState(rating: 2, color: .gray, tagged: true))
    XCTAssertFalse(state(["XMP-photomech:Prefs": "1:3:4:0", "XMP-photomech:Tagged": "False"]).tagged, "A tag value wins")
    // A camera-protected (locked) photo is tagged until a tag value says otherwise.
    XCTAssertTrue(state([:], locked: true).tagged)
    XCTAssertFalse(state(["XMP-photomech:Tagged": "False"], locked: true).tagged)
    XCTAssertFalse(state(["XMP-photomech:Prefs": "0:0:0:0"], locked: true).tagged)
  }

  func testLockedFilesCountAsCameraProtected() throws {
    var file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try Data([0xFF, 0xD8]).write(to: file)
    defer {
      var unlocked = URLResourceValues(); unlocked.isUserImmutable = false
      try? file.setResourceValues(unlocked)
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
      try? FileManager.default.removeItem(at: file)
    }
    XCTAssertFalse(CullingState.isLocked(file))
    var locked = URLResourceValues(); locked.isUserImmutable = true
    try file.setResourceValues(locked)
    XCTAssertTrue(CullingState.isLocked(file), "The Finder lock a camera's protect setting leaves")
    var unlocked = URLResourceValues(); unlocked.isUserImmutable = false
    try file.setResourceValues(unlocked)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
    XCTAssertTrue(CullingState.isLocked(file), "No write permission at all")
  }

  func testTaggedAndHighlyRatedPhotosCanBeProtected() {
    let tagged = CullingState(tagged: true), rated = CullingState(rating: 4)
    let protection = Protection(skipTagged: true, minimumRating: 3)
    XCTAssertEqual(protection.reason(for: tagged, method: .colorLabel), "Tagged")
    XCTAssertEqual(protection.reason(for: rated, method: .oneStar), "Rated 4 stars")
    XCTAssertNil(protection.reason(for: CullingState(rating: 2), method: .colorLabel))
    XCTAssertNil(protection.reason(for: tagged, method: .untag), "Untagging is meant for tagged photos")
    XCTAssertEqual(protection.reason(for: CullingState(rating: 5, tagged: true), method: .untag), "Rated 5 stars")
    XCTAssertNil(Protection(skipTagged: false, minimumRating: 0).reason(for: CullingState(rating: 5, tagged: true), method: .colorLabel))
  }

  func testEachWayOfMarkingChangesOnlyItsOwnValue() {
    let before = CullingState(rating: 3, color: .red, tagged: true)
    XCTAssertEqual(Mark(.colorLabel, color: .gray).applied(to: before), CullingState(rating: 3, color: .gray, tagged: true))
    XCTAssertEqual(Mark(.oneStar).applied(to: before), CullingState(rating: 1, color: .red, tagged: true))
    XCTAssertEqual(Mark(.untag).applied(to: before), CullingState(rating: 3, color: .red, tagged: false))
    XCTAssertTrue(Mark(.untag).isShown(in: CullingState()))
    XCTAssertTrue(Mark(.colorLabel, color: .gray).isShown(in: CullingState(color: .gray)))
    XCTAssertFalse(Mark(.oneStar).isShown(in: before))
    // Light Table takes at most 500 photos per metadata request.
    XCTAssertEqual(Array(0..<450).chunked(FocusCheckModel.requestLimit).map(\.count), [200, 200, 50])
  }

  func testTheActualPixelsViewStaysInsideThePhoto() {
    let photo = CGSize(width: 2736, height: 1824), view = CGSize(width: 600, height: 400)
    XCTAssertEqual(ActualPixels.origin(center: CGPoint(x: 0.5, y: 0.5), photo: photo, view: view), CGPoint(x: 1068, y: 712))
    XCTAssertEqual(ActualPixels.origin(center: CGPoint(x: 0.01, y: 0.02), photo: photo, view: view), .zero)
    XCTAssertEqual(ActualPixels.origin(center: CGPoint(x: 1, y: 1), photo: photo, view: view), CGPoint(x: 2136, y: 1424))
    XCTAssertEqual(ActualPixels.origin(center: CGPoint(x: 0.9, y: 0.1), photo: CGSize(width: 300, height: 200), view: view),
      CGPoint(x: -150, y: -100), "A photo smaller than the view is centered in it")
    // Dragged past the left edge, the view stays at the edge.
    let edge = ActualPixels.origin(center: CGPoint(x: -1, y: 0.5), photo: photo, view: view)
    XCTAssertEqual(ActualPixels.center(of: edge, photo: photo, view: view).x, 300 / 2736, accuracy: 1e-9)
    let visible = ActualPixels.visible(origin: CGPoint(x: 1068, y: 712), photo: photo, view: view)
    XCTAssertEqual(visible.width, 600 / 2736, accuracy: 1e-9)
    XCTAssertEqual(visible.midX, 0.5, accuracy: 1e-9); XCTAssertEqual(visible.midY, 0.5, accuracy: 1e-9)
  }

  func testTheReviewOpensAtFullSizeOnTheLockedFocusPoints() throws {
    let detail = try XCTUnwrap(FocusDetail.load(try canonPhoto(sharpZone: true)))
    XCTAssertEqual(detail.image.width, 600); XCTAssertEqual(detail.image.height, 400)
    XCTAssertLessThanOrEqual(max(detail.overview.width, detail.overview.height), FocusDetail.overviewLongSide)
    XCTAssertEqual(detail.locked.count, 1)
    XCTAssertEqual(detail.selected.count, 1, "Point 0 was selected but didn't lock")
    XCTAssertLessThan(detail.selected[0].midX, 0.5)
    let center = try XCTUnwrap(detail.focusCenter)
    XCTAssertEqual(center.x, 0.5, accuracy: 0.001); XCTAssertEqual(center.y, 0.5, accuracy: 0.001)
    let folder = try temporaryFolder()
    let plain = try jpeg(texture(size: 600, contrast: 1), named: "plain.jpg", in: folder, second: 0)
    XCTAssertNil(try XCTUnwrap(FocusDetail.load(plain)).focusCenter, "Without focus-point data it opens at the middle")
  }

  /// Real camera files from LIGHTTABLE_FOCUS_SAMPLES (skipped when unset, so no photos live here):
  /// every sharp sample stays unmarked on its own, and a blurred copy of each is marked.
  func testRealSharpPhotosStayUnmarkedAndBlurredCopiesAreCaught() throws {
    guard let path = ProcessInfo.processInfo.environment["LIGHTTABLE_FOCUS_SAMPLES"] else {
      throw XCTSkip("Set LIGHTTABLE_FOCUS_SAMPLES to a folder of sharp camera files to run this")
    }
    let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
      .filter { !$0.lastPathComponent.hasPrefix(".") }
    XCTAssertFalse(files.isEmpty)
    for file in files {
      let image = try XCTUnwrap(FocusAnalyzer.workingImage(file), file.lastPathComponent)
      let sharp = try XCTUnwrap(FocusAnalyzer.sharpness(of: image), file.lastPathComponent)
      let soft = try XCTUnwrap(FocusAnalyzer.sharpness(of: blur(image, radius: 3)), file.lastPathComponent)
      XCTAssertGreaterThanOrEqual(sharp, FocusJudge.unusableBelow * 1.5, "\(file.lastPathComponent) is sharp")
      XCTAssertLessThan(soft, FocusJudge.unusableBelow, "\(file.lastPathComponent) blurred all over")
    }
  }

  /// Runs Find & Mark against a stand-in for Light Table: the soft frame of a real burst must be
  /// sent to the host as a color write, and Undo must send its previous label back.
  @MainActor func testFindAndMarkAsksLightTableToLabelTheSoftFrame() async throws {
    // The temporary folder is reached through /var, a link to /private/var, which Light Table's
    // folder grant resolves; the plugin must still see that the grant covers the photos.
    let folder = try temporaryFolder()
    let files = try burst(in: folder, soft: [2])
    let host = FakeHost(tags: ["XMP-photomech:ColorClass": "2"])
    let model = makeModel(host)
    model.method = .colorLabel; model.color = .gray
    let grant = try folder.bookmarkData()
    var stale = false
    XCTAssertNotEqual(try URL(resolvingBookmarkData: grant, bookmarkDataIsStale: &stale).path, folder.path,
      "The test needs a grant whose path differs from the photos' path")
    model.receive(paths: files.map(\.path), fileAccessBookmark: grant.base64EncodedString())
    try await finish(model.findAndMark, model)
    XCTAssertNil(model.alert)
    XCTAssertEqual(model.marked.map(\.file.lastPathComponent), ["burst2.jpg"])
    XCTAssertEqual(host.writes, [FakeHost.Write(color: "8", files: ["burst2.jpg"])])
    try await finish(model.undo, model)
    XCTAssertEqual(host.writes.map(\.color), ["8", "2"], "Undo restores the label the photo had before")
    XCTAssertTrue(model.marked.isEmpty)
  }

  /// Light Table 1.3.3 can answer "saved" without writing (after a photo window closes). The plugin
  /// must read the labels back and say so instead of reporting photos as marked.
  @MainActor func testALabelLightTableDidNotSaveIsReportedNotCounted() async throws {
    let folder = try temporaryFolder()
    let files = try burst(in: folder, soft: [2])
    let host = FakeHost(tags: ["XMP-photomech:ColorClass": "0"], dropsWrites: true)
    let model = makeModel(host)
    model.method = .colorLabel; model.color = .brown
    model.receive(paths: files.map(\.path), fileAccessBookmark: try folder.bookmarkData().base64EncodedString())
    try await finish(model.findAndMark, model)
    XCTAssertEqual(host.writes.map(\.color), ["7"], "The write was sent")
    XCTAssertTrue(model.marked.isEmpty, "A label that didn't stick must not be listed as marked")
    XCTAssertTrue(model.alert?.contains("Quit and reopen Light Table") == true, model.alert ?? "no alert")
  }

  /// A tagged or highly rated photo is never marked, however soft: it's listed as left alone.
  @MainActor func testProtectedPhotosAreLeftAloneAndTheRestAreMarked() async throws {
    let folder = try temporaryFolder()
    let files = try burst(in: folder, soft: [1, 2])
    let host = FakeHost()
    host.set(["XMP-photomech:Tagged": "True"], for: "burst1.jpg")
    let model = makeModel(host)
    model.method = .colorLabel; model.color = .gray; model.skipTagged = true; model.protectRating = 0
    model.receive(paths: files.map(\.path), fileAccessBookmark: try folder.bookmarkData().base64EncodedString())
    try await finish(model.findAndMark, model)
    XCTAssertEqual(model.marked.map(\.file.lastPathComponent), ["burst2.jpg"])
    XCTAssertEqual(model.leftAlone.map(\.file.lastPathComponent), ["burst1.jpg"])
    XCTAssertEqual(model.leftAlone.first?.reason, "Tagged")
    XCTAssertEqual(host.writes, [FakeHost.Write(color: "8", files: ["burst2.jpg"])], "Nothing is written to the tagged photo")
    XCTAssertTrue(model.status.contains("Left 1 protected photo alone"), model.status)

    // Untagged but rated 4 stars, with photos rated 3 or more protected. The other photo already
    // has the label from the first run, so nothing more is written.
    host.set(["XMP-xmp:Rating": "4"], for: "burst1.jpg")
    model.protectRating = 3
    try await finish(model.findAndMark, model)
    XCTAssertEqual(model.leftAlone.map(\.reason), ["Rated 4 stars"])
    XCTAssertEqual(model.marked.map(\.alreadyMarked), [true])
    XCTAssertEqual(host.writes.count, 1)
    try await finish(model.undo, model)
    XCTAssertEqual(host.writes.count, 1, "Undo leaves a label that was there before Focus Check ran")
  }

  @MainActor func testARatingMarkGivesOneStarAndUndoPutsTheRatingBack() async throws {
    let folder = try temporaryFolder()
    let files = try burst(in: folder, soft: [2])
    let host = FakeHost(tags: ["XMP-xmp:Rating": "3", "XMP-photomech:ColorClass": "2"])
    let model = makeModel(host)
    model.method = .oneStar; model.protectRating = 0
    model.receive(paths: files.map(\.path), fileAccessBookmark: try folder.bookmarkData().base64EncodedString())
    try await finish(model.findAndMark, model)
    XCTAssertNil(model.alert)
    XCTAssertEqual(model.marked.map(\.previous), [CullingState(rating: 3, color: .red)])
    XCTAssertEqual(host.writes, [FakeHost.Write(rating: "1", files: ["burst2.jpg"])], "Only the rating is written")
    try await finish(model.undo, model)
    XCTAssertEqual(host.writes.last, FakeHost.Write(rating: "3", files: ["burst2.jpg"]))
    XCTAssertEqual(host.tags("burst2.jpg")["XMP-photomech:ColorClass"], "2", "The label is untouched")
  }

  @MainActor func testUntaggingChangesOnlyTaggedPhotosAndUndoTagsThemAgain() async throws {
    let folder = try temporaryFolder()
    let files = try burst(in: folder, soft: [1, 2])
    let host = FakeHost()
    host.set(["XMP-photomech:Tagged": "True"], for: "burst1.jpg")
    let model = makeModel(host)
    model.method = .untag; model.skipTagged = true; model.protectRating = 0
    model.receive(paths: files.map(\.path), fileAccessBookmark: try folder.bookmarkData().base64EncodedString())
    try await finish(model.findAndMark, model)
    XCTAssertNil(model.alert)
    XCTAssertTrue(model.leftAlone.isEmpty, "Skip tagged photos doesn't apply to untagging")
    XCTAssertEqual(model.marked.map(\.file.lastPathComponent), ["burst1.jpg", "burst2.jpg"])
    XCTAssertEqual(model.marked.map(\.alreadyMarked), [false, true])
    XCTAssertEqual(host.writes, [FakeHost.Write(tagged: "false", files: ["burst1.jpg"])])
    try await finish(model.undo, model)
    XCTAssertEqual(host.writes.last, FakeHost.Write(tagged: "true", files: ["burst1.jpg"]))
  }

  /// Keep, from the 100% review, gives one photo its previous label back and moves to the next.
  @MainActor func testKeepPutsBackOnePhotoAndMovesTheReviewOn() async throws {
    let folder = try temporaryFolder()
    let files = try burst(in: folder, soft: [1, 2])
    let host = FakeHost(tags: ["XMP-photomech:ColorClass": "2"])
    let model = makeModel(host)
    model.method = .colorLabel; model.color = .gray
    model.receive(paths: files.map(\.path), fileAccessBookmark: try folder.bookmarkData().base64EncodedString())
    try await finish(model.findAndMark, model)
    XCTAssertEqual(model.marked.count, 2)
    model.reviewing = model.marked[0].id
    try await finish(model.keepReviewed, model)
    XCTAssertEqual(host.writes.last, FakeHost.Write(color: "2", files: ["burst1.jpg"]))
    XCTAssertEqual(model.marked.map(\.file.lastPathComponent), ["burst2.jpg"])
    XCTAssertEqual(model.reviewing, model.marked.first?.id, "The review moves to the next photo")
    try await finish(model.keepReviewed, model)
    XCTAssertTrue(model.marked.isEmpty)
    XCTAssertNil(model.reviewing, "With nothing left, the results show again")
    XCTAssertEqual(host.tags("burst2.jpg")["XMP-photomech:ColorClass"], "2")
  }

  func testABlurryFocusZoneIsMarkedEvenWhenTheRestOfTheFrameIsSharp() {
    func score(_ frame: Double?, _ zone: Double?) -> FocusScore {
      FocusScore(file: URL(fileURLWithPath: "/x/p.jpg"), sharpness: frame, focusZone: zone)
    }
    XCTAssertEqual(FocusJudge.miss(score(1.0, 0.2)), .missedFocusZone, "Focus landed on the background")
    XCTAssertNil(FocusJudge.miss(score(1.0, 0.31)), "A soft-but-usable subject is left alone")
    XCTAssertNil(FocusJudge.miss(score(1.0, nil)), "No focus-point data: only the whole-frame test")
    XCTAssertEqual(FocusJudge.miss(score(0.2, 0.2)), .nothingSharp, "The whole-frame reason wins")
    var softSubject = score(1.0, 0.9)
    softSubject.focusPoint = 0.3
    XCTAssertEqual(FocusJudge.miss(softSubject), .softAtFocusPoint, "A sharp crowd beside a soft subject doesn't save it")
    softSubject.focusPoint = 0.6
    XCTAssertNil(FocusJudge.miss(softSubject))
  }

  func testCanonFocusPointsAreReadWithTheirSelectedZone() throws {
    let url = try canonPhoto(sharpZone: true)
    let points = try XCTUnwrap(CanonFocusPoints.read(from: url))
    XCTAssertEqual(points.mode, 7)
    XCTAssertEqual(points.points.count, 3)
    XCTAssertEqual(points.inFocus, [1])
    XCTAssertEqual(points.selected, [0, 1])
    // Point 1 is at the center; point 0 is up and to the left (y grows upward in Canon's table).
    let center = try XCTUnwrap(points.inFocusRects.first)
    XCTAssertEqual(center.midX, 0.5, accuracy: 0.001); XCTAssertEqual(center.midY, 0.5, accuracy: 0.001)
    let upperLeft = points.selectedRects[0]
    XCTAssertLessThan(upperLeft.midX, 0.5); XCTAssertLessThan(upperLeft.midY, 0.5)
    // Turned upright: orientation 6 (rotate right) moves the upper-left point to the upper right.
    let turned = FocusAnalyzer.displayed(upperLeft, orientation: 6)
    XCTAssertGreaterThan(turned.midX, 0.5); XCTAssertLessThan(turned.midY, 0.5)
    XCTAssertEqual(FocusAnalyzer.displayed(upperLeft, orientation: 8).midY, 1 - upperLeft.midX, accuracy: 0.001)
  }

  func testAPhotoBlurryWhereTheCameraFocusedIsMarked() throws {
    let score = try XCTUnwrap(FocusAnalyzer.score(try canonPhoto(sharpZone: false)))
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(score.sharpness), FocusJudge.unusableBelow, "The rest of the frame is sharp")
    XCTAssertLessThan(try XCTUnwrap(score.focusZone), FocusJudge.focusZoneBelow)
    XCTAssertEqual(FocusJudge.miss(score), .missedFocusZone)
  }

  func testASoftSubjectUnderTheFocusPointIsMarkedThoughTheCrowdIsSharp() throws {
    let score = try XCTUnwrap(FocusAnalyzer.score(try canonPhoto(sharpZone: true, softSubjectAtPoint: true)))
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(score.focusZone), FocusJudge.focusZoneBelow, "Sharp detail around the point")
    XCTAssertLessThan(try XCTUnwrap(score.focusPoint), FocusJudge.focusPointBelow)
    XCTAssertEqual(FocusJudge.miss(score), .softAtFocusPoint)
    XCTAssertNotNil(try XCTUnwrap(FocusAnalyzer.score(try canonPhoto(sharpZone: true))).focusPoint,
      "A sharp subject under the point is judged, and kept")
  }

  func testASharpSubjectJustBesideTheFocusPointKeepsThePhoto() throws {
    let score = try XCTUnwrap(FocusAnalyzer.score(try canonPhoto(sharpZone: false, sharpBesidePoint: true)))
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(score.focusZone), FocusJudge.focusZoneBelow)
    XCTAssertNil(FocusJudge.miss(score))
    XCTAssertNil(FocusJudge.miss(try XCTUnwrap(FocusAnalyzer.score(try canonPhoto(sharpZone: true)))))
  }

  // MARK: Helpers

  /// A model with its own settings, so tests never share or change the plugin's saved settings.
  @MainActor private func makeModel(_ host: FakeHost) -> FocusCheckModel {
    let suite = "focus-check-tests-" + UUID().uuidString
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    let model = FocusCheckModel(defaults: UserDefaults(suiteName: suite)!)
    model.metadata = host.metadata
    return model
  }

  /// Starts an action and waits until the model is idle again.
  @MainActor private func finish(_ action: () -> Void, _ model: FocusCheckModel) async throws {
    action()
    for _ in 0..<600 where model.busy { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertFalse(model.busy, "Timed out")
  }

  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder
  }

  /// Four frames, burst0…burst3.jpg, sharp except the ones listed, which are blurred all over.
  private func burst(in folder: URL, soft: Set<Int>) throws -> [URL] {
    let sharp = texture(size: 600, contrast: 1), blurred = blur(sharp, radius: 4)
    return try (0..<4).map { try jpeg(soft.contains($0) ? blurred : sharp, named: "burst\($0).jpg", in: folder, second: $0) }
  }

  /// A 600 × 400 JPEG of crisp shapes carrying a Canon maker note whose focus points are a 3-point
  /// table: point 0 up and to the left, point 1 (locked) at the center, point 2 down and to the right,
  /// with points 0 and 1 selected. The area around the points is blurred unless `sharpZone`;
  /// `sharpBesidePoint` keeps a sharp patch just right of the center point, inside the zone margin.
  private func canonPhoto(sharpZone: Bool, sharpBesidePoint: Bool = false, softSubjectAtPoint: Bool = false) throws -> URL {
    let size = CGSize(width: 600, height: 400)
    let sharp = texture(size: 600, contrast: 1).cropping(to: CGRect(x: 0, y: 0, width: 600, height: 400))!
    let canvas = try XCTUnwrap(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    canvas.draw(sharp, in: CGRect(origin: .zero, size: size))
    if !sharpZone {
      // The zone is the two selected points plus the margin: x 32–368 and y 32–268 from the top
      // left. Blur it and the 24 px the measuring squares reach past it, leaving the right side and
      // the bottom of the frame sharp. (Core Graphics measures y from the bottom.)
      let blurred = CGRect(x: 0, y: 100, width: 400, height: 300)
      canvas.draw(try XCTUnwrap(blur(sharp, radius: 6).cropping(to: CGRect(x: blurred.minX, y: 400 - blurred.maxY,
        width: blurred.width, height: blurred.height))), in: blurred)
      if sharpBesidePoint {
        // Right of the center point (which ends at x 320), still inside the zone's margin.
        let patch = CGRect(x: 300, y: 138, width: 92, height: 132)
        canvas.draw(try XCTUnwrap(sharp.cropping(to: CGRect(x: patch.minX, y: 400 - patch.maxY,
          width: patch.width, height: patch.height))), in: patch)
      }
    }
    if softSubjectAtPoint {
      // Bold jersey-like stripes, out of focus, over everything the squares under the center point
      // reach (x 240–360, y 144–240 from the top left), with the sharp shapes all around them.
      let stripes = try XCTUnwrap(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
      for x in stride(from: 0, to: 600, by: 20) {
        stripes.setFillColor(gray: 0.05, alpha: 1); stripes.fill(CGRect(x: x, y: 0, width: 10, height: 400))
        stripes.setFillColor(gray: 0.95, alpha: 1); stripes.fill(CGRect(x: x + 10, y: 0, width: 10, height: 400))
      }
      let soft = blur(try XCTUnwrap(stripes.makeImage()), radius: 3)
      let subject = CGRect(x: 230, y: 400 - 252, width: 140, height: 120)
      canvas.draw(try XCTUnwrap(soft.cropping(to: CGRect(x: subject.minX, y: 400 - subject.maxY,
        width: subject.width, height: subject.height))), in: subject)
    }
    let encoded = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    var jpeg = Data(encoded)
    jpeg.insert(contentsOf: canonExifSegment(), at: 2)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try jpeg.write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// An APP1 Exif segment: IFD0 → Exif IFD → Canon maker note → AFInfo2 (tag 0x0026), little-endian.
  private func canonExifSegment() -> Data {
    let count = 3
    let xs = [-200, 0, 200], ys = [100, 0, -100]
    var table: [Int] = [0, 7, count, count, 600, 400, 600, 400]
    table += [40, 40, 40] + [40, 40, 40] + xs + ys
    table += [0b010]          // AFPointsInFocus: point 1
    table += [0b011]          // AFPointsSelected: points 0 and 1
    table[0] = table.count * 2
    var tiff = Data()
    func u16(_ v: Int) { tiff.append(UInt8(v & 0xFF)); tiff.append(UInt8((v >> 8) & 0xFF)) }
    func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
    func entry(_ tag: Int, _ type: Int, _ items: Int, _ value: Int) { u16(tag); u16(type); u32(items); u32(value) }
    tiff.append(contentsOf: [0x49, 0x49]); u16(42); u32(8)
    u16(1); entry(0x8769, 4, 1, 26); u32(0)                      // IFD0 at 8 → Exif IFD at 26
    u16(1); entry(0x927C, 7, 18 + table.count * 2, 44); u32(0)  // Exif IFD → maker note at 44
    u16(1); entry(0x0026, 3, table.count, 62); u32(0)           // Canon IFD → AFInfo2 at 62
    for value in table { u16(value & 0xFFFF) }
    var segment = Data([0xFF, 0xE1])
    let length = 2 + 6 + tiff.count
    segment.append(UInt8(length >> 8)); segment.append(UInt8(length & 0xFF))
    segment.append(contentsOf: Array("Exif".utf8) + [0, 0])
    segment.append(tiff)
    return segment
  }

  private func jpeg(_ image: CGImage, named name: String, in folder: URL, second: Int) throws -> URL {
    let url = folder.appendingPathComponent(name)
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:08 19:00:00",
        kCGImagePropertyExifSubsecTimeOriginal: String(format: "%02d", second * 20)],
      kCGImageDestinationLossyCompressionQuality: 0.95,
    ] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }

  /// Crisp-edged shapes at a given contrast around mid gray. Edges, not noise, are what a camera's
  /// focus shows up in, and they blur the way real photos do.
  private func texture(size: Int = 300, contrast: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    var random = SeededRandom(seed: 7)
    for _ in 0..<400 {
      let level = 0.5 + (CGFloat(random.next() % 100) / 100 - 0.5) * contrast
      context.setFillColor(gray: level, alpha: 1)
      let width = CGFloat(4 + random.next() % 30), height = CGFloat(4 + random.next() % 30)
      context.fill(CGRect(x: CGFloat(random.next() % UInt64(size)), y: CGFloat(random.next() % UInt64(size)),
        width: width, height: height))
    }
    return context.makeImage()!
  }

  private func blur(_ image: CGImage, radius: Double) -> CGImage {
    let input = CIImage(cgImage: image).clampedToExtent()
    let output = input.applyingGaussianBlur(sigma: radius)
    let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    return context.createCGImage(output.cropped(to: extent), from: extent)!
  }
}

/// Repeatable pseudo-random numbers, so the synthetic photos are the same every run.
private struct SeededRandom {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return state >> 33
  }
}

/// Plays Light Table's side of the plugin protocol over real pipes: it advertises metadata
/// requests, answers reads with each photo's stored tags, and records and applies every write.
private final class FakeHost: @unchecked Sendable {
  struct Write: Equatable {
    var color: String? = nil, rating: String? = nil, tagged: String? = nil
    /// File names.
    let files: [String]
  }
  let metadata: PluginMetadata
  private let lock = NSLock()
  private var recorded: [Write] = []
  /// Each photo's tags by file name; photos not listed have `initial`. A host that drops writes
  /// answers "saved" but never changes them.
  private var stored: [String: [String: String]] = [:]
  private let initial: [String: String]
  private let dropsWrites: Bool
  private let toPlugin = Pipe(), toHost = Pipe()
  private let hostChannel: PluginChannel
  private let pluginChannel: PluginChannel

  var writes: [Write] { lock.lock(); defer { lock.unlock() }; return recorded }
  func tags(_ name: String) -> [String: String] { lock.lock(); defer { lock.unlock() }; return stored[name] ?? initial }
  func set(_ tags: [String: String], for name: String) { lock.lock(); stored[name] = tags; lock.unlock() }

  init(tags initial: [String: String] = [:], dropsWrites: Bool = false) {
    self.initial = initial
    self.dropsWrites = dropsWrites
    pluginChannel = PluginChannel(input: toPlugin.fileHandleForReading, output: toHost.fileHandleForWriting)
    hostChannel = PluginChannel(input: toHost.fileHandleForReading, output: toPlugin.fileHandleForWriting)
    metadata = PluginMetadata(channel: pluginChannel)
    let metadata = metadata
    pluginChannel.listen { result in if case .success(let message) = result { _ = metadata.handle(message) } }
    hostChannel.listen { [weak self] result in
      guard let self, case .success(let message) = result, message.type == "metadata-request",
        let id = message.payload?["id"] else { return }
      var payload = ["id": id]
      let names = (message.files ?? []).map { URL(fileURLWithPath: $0).lastPathComponent }
      self.lock.lock()
      if message.command == "read" {
        let rows = names.map { self.stored[$0] ?? self.initial }
        payload["tags"] = String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
      } else {
        let values = message.payload ?? [:]
        self.recorded.append(Write(color: values["color"], rating: values["rating"], tagged: values["tagged"], files: names))
        if !self.dropsWrites {
          for name in names {
            var tags = self.stored[name] ?? self.initial
            if let color = values["color"] { tags["XMP-photomech:ColorClass"] = color }
            if let rating = values["rating"] { tags["XMP-xmp:Rating"] = rating }
            if let tagged = values["tagged"] { tags["XMP-photomech:Tagged"] = tagged == "true" ? "True" : "False" }
            self.stored[name] = tags
          }
        }
      }
      self.lock.unlock()
      self.hostChannel.send(PluginMessage("metadata-response", payload: payload))
    }
    // Light Table names the metadata engine on every command, which tells the plugin it may ask.
    _ = metadata.handle(PluginMessage("command", command: "open", payload: [PluginMetadataEngine.payloadKey: "exiftool"]))
  }
}
