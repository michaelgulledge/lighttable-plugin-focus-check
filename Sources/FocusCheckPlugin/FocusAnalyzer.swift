import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// One photo's measured focus.
struct FocusScore: Equatable, Sendable {
  let file: URL
  /// How crisp the sharpest parts of the frame are: usable photos scored 0.39 and up, unusable
  /// ones 0.33 or less. Nil when the frame has no detail to judge (a blank sky or a black frame).
  let sharpness: Double?
  /// The same measure around the camera's focus points (the AF zone selected and the points that
  /// locked, with a margin). Nil when the photo has no focus-point data or too little detail there.
  var focusZone: Double? = nil
  /// How crisp the subject right under the locked focus points is: the 90th-percentile crispness of
  /// the squares there with strong edges (a jersey, numbers, a helmet). Nil when the photo has no
  /// focus-point data or the points sit on plain background, where a moved subject can't be judged.
  var focusPoint: Double? = nil
}

/// Edge crispness for overlapping squares of the working image: Laplacian energy over edge
/// (gradient) energy, which depends on how sharp edges are, not on their contrast.
struct SharpnessMap: Sendable {
  let width: Int, height: Int
  let tile: Int, step: Int
  /// Edge energy and crispness per square, row by row.
  let energy: [Float]
  let crispness: [Float]
  let minimumEdgeEnergy: Float
  /// Crispness per square; nil where a square is too flat to judge.
  var squares: [Float?] { zip(energy, crispness).map { $0 >= minimumEdgeEnergy ? $1 : nil } }
  var columns: Int { (width - tile) / step + 1 }
  var rows: Int { (height - tile) / step + 1 }

  init?(_ image: CGImage, tile: Int = FocusAnalyzer.tileSize, minimumEdgeEnergy: Float = FocusAnalyzer.minimumEdgeEnergy) {
    let width = image.width, height = image.height
    guard width >= tile, height >= tile else { return nil }
    self.width = width; self.height = height; self.tile = tile; step = tile / 2
    self.minimumEdgeEnergy = minimumEdgeEnergy
    var gray = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // A light smoothing first keeps high-ISO grain from reading as sharp detail.
    guard let smoothed = Self.convolve(gray.map(Float.init), width: width, height: height,
      kernel: [1, 2, 1, 2, 4, 2, 1, 2, 1].map { $0 / 16 }),
      let laplacian = Self.convolve(smoothed, width: width, height: height, kernel: [0, 1, 0, 1, -4, 1, 0, 1, 0]),
      let horizontal = Self.convolve(smoothed, width: width, height: height, kernel: [0, 0, 0, -0.5, 0, 0.5, 0, 0, 0]),
      let vertical = Self.convolve(smoothed, width: width, height: height, kernel: [0, -0.5, 0, 0, 0, 0, 0, 0.5, 0])
    else { return nil }
    let columns = (width - tile) / (tile / 2) + 1, rows = (height - tile) / (tile / 2) + 1
    let area = Float(tile * tile)
    var energy: [Float] = [], crispness: [Float] = []
    energy.reserveCapacity(columns * rows); crispness.reserveCapacity(columns * rows)
    func sumOfSquares(_ values: [Float], _ start: Int) -> Float {
      values.withUnsafeBufferPointer { buffer in
        var sum: Float = 0
        vDSP_svesq(buffer.baseAddress! + start, 1, &sum, vDSP_Length(tile))
        return sum
      }
    }
    for row in 0..<rows {
      for column in 0..<columns {
        var laplacianEnergy: Float = 0, edgeEnergy: Float = 0
        for y in (row * step)..<(row * step + tile) {
          let start = y * width + column * step
          laplacianEnergy += sumOfSquares(laplacian, start)
          edgeEnergy += sumOfSquares(horizontal, start) + sumOfSquares(vertical, start)
        }
        energy.append(edgeEnergy / area)
        crispness.append(edgeEnergy > 0 ? laplacianEnergy / edgeEnergy : 0)
      }
    }
    self.energy = energy; self.crispness = crispness
  }

  /// The crispness the sharpest 5% of the judgeable squares inside a region reach (0…1 of the
  /// frame, from the top left), and how many squares were judged.
  func score(in region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> (score: Double?, squares: Int) {
    let values = crispnessValues(in: region, minimumEnergy: minimumEdgeEnergy).values
    guard !values.isEmpty else { return (nil, 0) }
    return (Double(values[Int(Double(values.count - 1) * FocusAnalyzer.sharpestShare)]), values.count)
  }

  /// For the squares in a region with strong edges (at least `minimumEnergy`): the crispness their
  /// `share` percentile reaches, how many there are, and how many squares the region has in all.
  func structuredScore(in region: CGRect, minimumEnergy: Float, share: Double) -> (score: Double?, structured: Int, total: Int) {
    let (values, total) = crispnessValues(in: region, minimumEnergy: minimumEnergy)
    guard !values.isEmpty else { return (nil, 0, total) }
    return (Double(values[Int(Double(values.count - 1) * share)]), values.count, total)
  }

  /// Sorted crispness of the squares centered in a region whose edge energy reaches a minimum,
  /// and the number of squares centered there.
  private func crispnessValues(in region: CGRect, minimumEnergy: Float) -> (values: [Float], total: Int) {
    var values: [Float] = [], total = 0
    for row in 0..<rows {
      let centerY = (Double(row * step) + Double(tile) / 2) / Double(height)
      guard centerY >= region.minY, centerY <= region.maxY else { continue }
      for column in 0..<columns {
        let centerX = (Double(column * step) + Double(tile) / 2) / Double(width)
        guard centerX >= region.minX, centerX <= region.maxX else { continue }
        total += 1
        let index = row * columns + column
        if energy[index] >= minimumEnergy { values.append(crispness[index]) }
      }
    }
    return (values.sorted(), total)
  }

  private static func convolve(_ values: [Float], width: Int, height: Int, kernel: [Float]) -> [Float]? {
    var input = values
    var output = [Float](repeating: 0, count: values.count)
    let status = input.withUnsafeMutableBytes { inBytes in
      output.withUnsafeMutableBytes { outBytes in
        var source = vImage_Buffer(data: inBytes.baseAddress, height: vImagePixelCount(height),
          width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
        var destination = vImage_Buffer(data: outBytes.baseAddress, height: vImagePixelCount(height),
          width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
        return vImageConvolve_PlanarF(&source, &destination, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
      }
    }
    return status == kvImageNoError ? output : nil
  }
}

enum FocusAnalyzer {
  /// Big enough to show a missed focus, small enough to stay quick on a full card.
  static let workingLongSide = 1600
  /// The frame is judged in overlapping squares of this size.
  static let tileSize = 48
  /// Squares flatter than this (sky, smoke, plain walls) say nothing about focus and are skipped.
  static let minimumEdgeEnergy: Float = 4
  /// A score is the crispness the sharpest 5% of an area reaches, so a sharp player decides it
  /// however much of the area is soft background.
  static let sharpestShare = 0.95
  /// The focus zone is widened by this share of the frame on each side: a moving player is often
  /// just beside the point the camera reports, and the zone must still take them in.
  static let zoneMargin = CGSize(width: 0.08, height: 0.12)
  /// Fewer judgeable squares than this around the focus points (a plain jersey, the night sky) is
  /// too little to judge, so only the whole-frame test applies.
  static let minimumZoneSquares = 8

  /// The area right under the locked focus points is widened only this much: enough to cover the
  /// point's subject, not the players or crowd around it.
  static let pointMargin = CGSize(width: 0.03, height: 0.045)
  /// Squares with at least this much edge energy hold a subject's strong edges (a jersey, numbers,
  /// a helmet) rather than plain or out-of-focus background.
  static let subjectEdgeEnergy: Float = 16
  /// The area under the points is judged as a subject only when at least half its squares, and at
  /// least four, have strong edges; otherwise the point sits on background a player moved off.
  static let subjectShare = 0.5
  static let minimumSubjectSquares = 4
  /// The subject's score is the crispness its sharpest 10% of strong-edge squares reach.
  static let subjectPercentile = 0.9

  static func score(_ url: URL) -> FocusScore? {
    guard let image = workingImage(url), let map = SharpnessMap(image) else { return nil }
    var score = FocusScore(file: url, sharpness: map.score().score)
    if let areas = focusAreas(for: url) {
      let measured = map.score(in: areas.zone)
      if measured.squares >= minimumZoneSquares { score.focusZone = measured.score }
      let subject = map.structuredScore(in: areas.point, minimumEnergy: subjectEdgeEnergy, share: subjectPercentile)
      if subject.structured >= minimumSubjectSquares, Double(subject.structured) >= subjectShare * Double(subject.total) {
        score.focusPoint = subject.score
      }
    }
    return score
  }

  /// The whole-frame score of an image.
  static func sharpness(of image: CGImage) -> Double? { SharpnessMap(image)?.score().score }

  /// Where the photographer focused, as shown (rotation applied) and widened by the margin: the
  /// Canon focus points selected plus those that locked. Nil without focus-point data.
  static func focusZone(for url: URL) -> CGRect? { focusAreas(for: url)?.zone }

  /// The widened focus zone and the area right under the locked points (the selected points when
  /// the camera recorded none locked). Nil without focus-point data.
  static func focusAreas(for url: URL) -> (zone: CGRect, point: CGRect)? {
    guard let points = CanonFocusPoints.read(from: url) else { return nil }
    let orientation = orientation(of: url)
    guard let zone = zone(for: points, orientation: orientation),
      let point = pointArea(for: points, orientation: orientation) else { return nil }
    return (zone, point)
  }

  static func pointArea(for points: CanonFocusPoints, orientation: Int) -> CGRect? {
    let locked = (points.inFocusRects.isEmpty ? points.selectedRects : points.inFocusRects)
      .map { displayed($0, orientation: orientation) }
    guard let first = locked.first else { return nil }
    return locked.dropFirst().reduce(first) { $0.union($1) }
      .insetBy(dx: -pointMargin.width, dy: -pointMargin.height)
      .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  static func zone(for points: CanonFocusPoints, orientation: Int) -> CGRect? {
    let anchors = (points.selectedRects + points.inFocusRects).map { displayed($0, orientation: orientation) }
    guard let first = anchors.first else { return nil }
    let union = anchors.dropFirst().reduce(first) { $0.union($1) }
    return union.insetBy(dx: -zoneMargin.width, dy: -zoneMargin.height)
      .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  /// The photo's EXIF orientation (1 when it records none).
  static func orientation(of url: URL) -> Int {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 1 }
    return properties[kCGImagePropertyOrientation] as? Int ?? 1
  }

  /// A rectangle in the camera's stored orientation, as it appears once the photo is turned
  /// upright (EXIF orientations 1, 3, 6 and 8; Canon bodies record no mirrored ones).
  static func displayed(_ rect: CGRect, orientation: Int) -> CGRect {
    switch orientation {
    case 3: CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    case 6: CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
    case 8: CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
    default: rect
    }
  }

  /// The photo at the working size with its rotation applied. RAW files use their embedded
  /// full-size preview when it is big enough, which is the camera's own rendering.
  static func workingImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: workingLongSide,
    ]
    if let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      max(preview.width, preview.height) >= workingLongSide / 2 { return preview }
    var full = options
    full[kCGImageSourceCreateThumbnailFromImageAlways] = true
    return CGImageSourceCreateThumbnailAtIndex(source, 0, full as CFDictionary)
  }
}
