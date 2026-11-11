import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// What the review shows for one photo: the photo at full resolution, a small copy for the
/// whole-frame overview, and where the camera's focus points were.
struct FocusDetail: @unchecked Sendable {
  /// The photo at full resolution, turned upright.
  let image: CGImage
  let overview: CGImage
  /// The focus points that locked, and the other selected points, in 0…1 of the upright frame from
  /// the top left. Both are empty without Canon focus-point data.
  let locked: [CGRect]
  let selected: [CGRect]

  static let overviewLongSide = 480

  /// Where the 100% view opens: the middle of the locked points (of the selected ones when none
  /// locked). Nil without focus-point data.
  var focusCenter: CGPoint? {
    let anchors = locked.isEmpty ? selected : locked
    guard let first = anchors.first else { return nil }
    let union = anchors.dropFirst().reduce(first) { $0.union($1) }
    return CGPoint(x: union.midX, y: union.midY)
  }

  static func load(_ url: URL) -> FocusDetail? {
    guard let image = fullImage(url), let overview = scaled(image, longSide: overviewLongSide) else { return nil }
    var locked: [CGRect] = [], selected: [CGRect] = []
    if let points = CanonFocusPoints.read(from: url) {
      let orientation = FocusAnalyzer.orientation(of: url)
      locked = points.inFocusRects.map { FocusAnalyzer.displayed($0, orientation: orientation) }
      selected = points.rects(points.selected.filter { !points.inFocus.contains($0) })
        .map { FocusAnalyzer.displayed($0, orientation: orientation) }
    }
    return FocusDetail(image: image, overview: overview, locked: locked, selected: selected)
  }

  /// The photo at full resolution, upright. A RAW file's embedded preview is used when it has
  /// (nearly) every pixel, as the camera rendered it; otherwise the file itself is decoded.
  static func fullImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    let longSide = max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    guard longSide > 0 else { return nil }
    var options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: longSide,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    if let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      max(preview.width, preview.height) * 10 >= longSide * 9 { return preview }
    options[kCGImageSourceCreateThumbnailFromImageAlways] = true
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  static func scaled(_ image: CGImage, longSide: Int) -> CGImage? {
    let scale = min(1, Double(longSide) / Double(max(image.width, image.height)))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: width,
      height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
}

/// Geometry of the 100% view, which shows one photo pixel per screen pixel, as Light Table's 100%
/// zoom does. Sizes are in points: the photo's pixels divided by the screen's scale.
enum ActualPixels {
  /// The top-left corner, in the photo's points, of a `view`-sized window centered on `center` (0…1
  /// of the photo) and kept inside the photo. Along a side where the photo is smaller than the view,
  /// the photo is centered instead (a negative origin).
  static func origin(center: CGPoint, photo: CGSize, view: CGSize) -> CGPoint {
    func axis(_ middle: CGFloat, _ length: CGFloat, _ window: CGFloat) -> CGFloat {
      guard length > window else { return (length - window) / 2 }
      return min(max(middle * length - window / 2, 0), length - window)
    }
    return CGPoint(x: axis(center.x, photo.width, view.width), y: axis(center.y, photo.height, view.height))
  }

  /// The part of the photo a window at `origin` shows, in 0…1 of the photo.
  static func visible(origin: CGPoint, photo: CGSize, view: CGSize) -> CGRect {
    CGRect(x: origin.x / photo.width, y: origin.y / photo.height, width: view.width / photo.width,
      height: view.height / photo.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  /// The center the window at `origin` really has, so a drag past an edge stops there instead of
  /// storing a center the view can't reach.
  static func center(of origin: CGPoint, photo: CGSize, view: CGSize) -> CGPoint {
    CGPoint(x: (origin.x + view.width / 2) / photo.width, y: (origin.y + view.height / 2) / photo.height)
  }
}

/// Draws focus points over a photo: the points that locked in red, the other selected points in
/// white. Rectangles are in 0…1 of the photo, from the top left.
struct FocusPointsOverlay: View {
  let locked: [CGRect]
  let selected: [CGRect]
  var lineWidth: CGFloat = 1

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        outline(selected, in: geometry.size).stroke(Color.white.opacity(0.8), lineWidth: lineWidth)
        outline(locked, in: geometry.size).stroke(Color.red, lineWidth: lineWidth * 1.5)
      }.shadow(color: .black.opacity(0.5), radius: 1)
    }.allowsHitTesting(false)
  }

  private func outline(_ rects: [CGRect], in size: CGSize) -> Path {
    Path { path in
      for rect in rects {
        path.addRect(CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
          width: rect.width * size.width, height: rect.height * size.height))
      }
    }
  }
}

/// Handles ←, → and K while the review is on screen. Light Table's own windows use the same kind of
/// key monitor; SwiftUI shortcuts without a modifier key aren't dependable on macOS.
@MainActor final class ReviewKeys {
  private var monitor: Any?

  func start(_ handle: @escaping (NSEvent) -> Bool) {
    stop()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handle(event) ? nil : event }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}

/// A marked photo at 100% where the camera focused, with the whole frame below it, so the
/// photographer can see why it was marked and keep it if it's usable.
struct ReviewView: View {
  @EnvironmentObject var model: FocusCheckModel
  @Environment(\.displayScale) private var displayScale
  @AppStorage("focus-check-show-points") private var showsPoints = true
  @State private var loaded: [String: FocusDetail] = [:]
  @State private var failed: Set<String> = []
  /// Where the 100% view is centered, in 0…1 of the photo; nil opens it at the focus points.
  @State private var center: CGPoint?
  @State private var dragStart: CGPoint?
  @State private var viewport = CGSize(width: 1, height: 1)
  @State private var keys = ReviewKeys()

  private var photo: MarkedPhoto? { model.marked.first { $0.id == model.reviewing } }
  private var index: Int { model.marked.firstIndex { $0.id == model.reviewing } ?? 0 }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button { model.reviewing = nil } label: { Label("Results", systemImage: "chevron.backward") }
          .keyboardShortcut(.cancelAction).help("Back to the results (Esc)")
        Spacer()
        Text("\(index + 1) of \(model.marked.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
        ControlGroup {
          Button { model.review(step: -1) } label: { Image(systemName: "chevron.left") }
            .disabled(index == 0).help("Previous photo (←)")
          Button { model.review(step: 1) } label: { Image(systemName: "chevron.right") }
            .disabled(index >= model.marked.count - 1).help("Next photo (→)")
        }.fixedSize()
      }.padding(.horizontal, 16).padding(.vertical, 10)
      Divider()
      GeometryReader { geometry in
        actualPixels(in: geometry.size)
          .onAppear { viewport = geometry.size }
          .onChange(of: geometry.size) { _, size in viewport = size }
      }.background(Color.black)
      Divider()
      if let photo { footer(photo).padding(16) }
    }
    .task(id: model.reviewing) { await load() }
    .onAppear {
      keys.start { [model] event in
        guard event.window?.isKeyWindow == true, model.reviewing != nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 123: model.review(step: -1); return true
        case 124: model.review(step: 1); return true
        default: break
        }
        if event.charactersIgnoringModifiers?.lowercased() == "k" { model.keepReviewed(); return true }
        return false
      }
    }
    .onDisappear { keys.stop() }
  }

  // MARK: 100% view

  private func pointSize(of detail: FocusDetail) -> CGSize {
    CGSize(width: CGFloat(detail.image.width) / displayScale, height: CGFloat(detail.image.height) / displayScale)
  }

  private func currentCenter(_ detail: FocusDetail) -> CGPoint { center ?? detail.focusCenter ?? CGPoint(x: 0.5, y: 0.5) }

  private func clamped(_ point: CGPoint, _ detail: FocusDetail) -> CGPoint {
    let size = pointSize(of: detail)
    return ActualPixels.center(of: ActualPixels.origin(center: point, photo: size, view: viewport), photo: size, view: viewport)
  }

  @ViewBuilder private func actualPixels(in size: CGSize) -> some View {
    if let photo, let detail = loaded[photo.id] {
      let photoSize = pointSize(of: detail)
      let start = currentCenter(detail)
      let origin = ActualPixels.origin(center: start, photo: photoSize, view: size)
      // Whole screen pixels, so no photo pixel is split across two.
      let x = (origin.x * displayScale).rounded() / displayScale, y = (origin.y * displayScale).rounded() / displayScale
      Image(decorative: detail.image, scale: displayScale)
        .overlay { if showsPoints { FocusPointsOverlay(locked: detail.locked, selected: detail.selected, lineWidth: 2) } }
        .offset(x: -x, y: -y)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture().onChanged { value in
          let from = dragStart ?? start
          if dragStart == nil { dragStart = start }
          center = clamped(CGPoint(x: from.x - value.translation.width / photoSize.width,
            y: from.y - value.translation.height / photoSize.height), detail)
        }.onEnded { _ in dragStart = nil })
        .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
    } else if let photo, failed.contains(photo.id) {
      Text("Focus Check couldn't open this photo.").foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: Whole frame and details

  private func footer(_ photo: MarkedPhoto) -> some View {
    let detail = loaded[photo.id]
    let mark = model.lastMark ?? Mark(.colorLabel)
    return HStack(alignment: .top, spacing: 14) {
      overview(detail).frame(width: 168, height: 112)
      VStack(alignment: .leading, spacing: 4) {
        Text(photo.file.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
        Text("\(photo.miss.explanation): \(Self.format(photo.failedScore)), below \(Self.format(photo.miss.threshold))")
          .font(.callout)
        Text(photo.alreadyMarked
          ? "It was already \(mark.describe(photo.previous)) before Focus Check ran."
          : "\(mark.resultTitle) · before: \(mark.describe(photo.previous))")
          .font(.caption).foregroundStyle(.secondary)
        Text(placeNote(detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 10) {
        if !photo.alreadyMarked {
          Button("Keep") { model.keep(photo) }.disabled(model.busy)
            .help("This photo is usable: put back its \(mark.valueName) (\(mark.describe(photo.previous))) and take it off the list (K)")
        }
        Toggle("Focus points", isOn: $showsPoints).toggleStyle(.checkbox).font(.caption)
      }
    }
  }

  private func placeNote(_ detail: FocusDetail?) -> String {
    guard let detail else { return "Opening the photo at full size…" }
    let place = !detail.locked.isEmpty ? "around the focus points that locked (red)"
      : !detail.selected.isEmpty ? "around the selected focus points (white)"
      : "at the middle of the frame (no focus-point data)"
    return "100% \(place). Drag the photo, or click the small frame, to look around."
  }

  @ViewBuilder private func overview(_ detail: FocusDetail?) -> some View {
    if let detail {
      let photoSize = pointSize(of: detail)
      let origin = ActualPixels.origin(center: currentCenter(detail), photo: photoSize, view: viewport)
      let visible = ActualPixels.visible(origin: origin, photo: photoSize, view: viewport)
      Image(decorative: detail.overview, scale: 1).resizable().aspectRatio(contentMode: .fit)
        .overlay {
          GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
              if showsPoints { FocusPointsOverlay(locked: detail.locked, selected: detail.selected) }
              Rectangle().stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: max(2, visible.width * size.width), height: max(2, visible.height * size.height))
                .offset(x: visible.minX * size.width, y: visible.minY * size.height)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
              center = clamped(CGPoint(x: value.location.x / size.width, y: value.location.y / size.height), detail)
            })
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help("Click or drag to move the 100% view")
    } else {
      RoundedRectangle(cornerRadius: 4).fill(.quaternary)
    }
  }

  private static func format(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }

  // MARK: Loading

  /// Opens the photo shown and reads the next one ahead, keeping only those two and the previous
  /// one in memory (a full-size photo takes about 80 MB).
  private func load() async {
    guard let photo else { return }
    center = nil; dragStart = nil
    if loaded[photo.id] == nil, !failed.contains(photo.id) {
      let url = photo.file
      let detail = await Task.detached(priority: .userInitiated) { FocusDetail.load(url) }.value
      guard !Task.isCancelled else { return }
      if let detail { loaded[photo.id] = detail } else { failed.insert(photo.id); return }
    }
    let list = model.marked, position = list.firstIndex { $0.id == photo.id } ?? 0
    let keep = Set([position - 1, position, position + 1].filter(list.indices.contains).map { list[$0].id })
    loaded = loaded.filter { keep.contains($0.key) }
    guard list.indices.contains(position + 1) else { return }
    let next = list[position + 1]
    guard loaded[next.id] == nil, !failed.contains(next.id) else { return }
    let url = next.file
    let detail = await Task.detached(priority: .utility) { FocusDetail.load(url) }.value
    guard !Task.isCancelled, let detail else { return }
    loaded[next.id] = detail
  }
}
