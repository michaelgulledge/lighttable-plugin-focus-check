import CoreGraphics
import Foundation

/// The focus points a Canon camera recorded for a shot, read from the maker note's AFInfo2 table
/// (tag 0x0026), the same table ExifTool reports as AFAreaXPositions, AFPointsInFocus, and so on.
struct CanonFocusPoints: Equatable, Sendable {
  struct Point: Equatable, Sendable {
    /// Center relative to the middle of the frame, in AF image pixels; y grows upward.
    let x: Int, y: Int, width: Int, height: Int
  }
  let mode: Int
  let imageWidth: Int
  let imageHeight: Int
  let points: [Point]
  /// Indexes of the points the camera reported as in focus.
  let inFocus: [Int]
  /// Indexes of the points the photographer had selected (a zone, a spot, or an expansion group).
  let selected: [Int]

  /// The in-focus points as rectangles in 0…1 of the frame as stored by the camera (before any
  /// rotation), measured from the top left.
  var inFocusRects: [CGRect] { rects(inFocus) }
  var selectedRects: [CGRect] { rects(selected) }

  func rects(_ indexes: [Int]) -> [CGRect] {
    guard imageWidth > 0, imageHeight > 0 else { return [] }
    return indexes.compactMap { index in
      guard points.indices.contains(index) else { return nil }
      let point = points[index]
      guard point.width > 0, point.height > 0 else { return nil }
      let centerX = (Double(imageWidth) / 2 + Double(point.x)) / Double(imageWidth)
      let centerY = (Double(imageHeight) / 2 - Double(point.y)) / Double(imageHeight)
      let width = Double(point.width) / Double(imageWidth), height = Double(point.height) / Double(imageHeight)
      return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }
  }

  /// Reads the table from a JPEG or a TIFF-based RAW file (CR2). Nil for other cameras, files
  /// without the table, or anything malformed.
  static func read(from url: URL) -> CanonFocusPoints? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    // EXIF sits in the first 64 KB of a JPEG and near the start of a CR2.
    guard let head = try? handle.read(upToCount: 256 * 1024), head.count > 16 else { return nil }
    let bytes = [UInt8](head)
    guard let tiffStart = tiffStart(in: bytes) else { return nil }
    return parse(bytes, tiffStart: tiffStart)
  }

  /// Where the TIFF header starts: at 0 for a CR2, after "Exif\0\0" in a JPEG's APP1 segment.
  static func tiffStart(in bytes: [UInt8]) -> Int? {
    if bytes.count > 4, (bytes[0] == 0x49 && bytes[1] == 0x49) || (bytes[0] == 0x4D && bytes[1] == 0x4D) { return 0 }
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var offset = 2
    while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
      let marker = bytes[offset + 1]
      let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
      if marker == 0xE1, offset + 10 <= bytes.count,
        Array(bytes[(offset + 4)..<(offset + 10)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
        return offset + 10
      }
      if marker == 0xDA { return nil }
      offset += 2 + length
    }
    return nil
  }

  static func parse(_ bytes: [UInt8], tiffStart base: Int) -> CanonFocusPoints? {
    guard base + 8 <= bytes.count else { return nil }
    let little = bytes[base] == 0x49
    func u16(_ at: Int) -> Int? {
      guard at >= 0, at + 2 <= bytes.count else { return nil }
      return little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
    }
    func u32(_ at: Int) -> Int? {
      guard let low = u16(little ? at : at + 2), let high = u16(little ? at + 2 : at) else { return nil }
      return high << 16 | low
    }
    /// The entry for a tag in the IFD at a TIFF-relative offset: (type, count, value-or-offset position).
    func entry(_ tag: Int, inIFDAt ifd: Int) -> (type: Int, count: Int, valueAt: Int)? {
      let start = base + ifd
      guard let count = u16(start), count < 1000 else { return nil }
      for index in 0..<count {
        let at = start + 2 + index * 12
        guard let found = u16(at), let type = u16(at + 2), let items = u32(at + 4) else { return nil }
        if found == tag {
          let size = [1: 1, 2: 1, 3: 2, 4: 4, 6: 1, 7: 1, 8: 2, 9: 4][type, default: 1] * items
          let valueAt = size <= 4 ? at + 8 : (u32(at + 8).map { base + $0 } ?? -1)
          return (type, items, valueAt)
        }
      }
      return nil
    }
    guard let ifd0 = u32(base + 4),
      let exifPointer = entry(0x8769, inIFDAt: ifd0), let exif = u32(exifPointer.valueAt),
      let makerNote = entry(0x927C, inIFDAt: exif), makerNote.valueAt > base,
      let info = entry(0x0026, inIFDAt: makerNote.valueAt - base), info.type == 3 || info.type == 8,
      info.count >= 8 else { return nil }
    func value(_ index: Int) -> Int? {
      guard index < info.count, let raw = u16(info.valueAt + index * 2) else { return nil }
      return raw >= 0x8000 ? raw - 0x10000 : raw
    }
    guard let mode = value(1), let count = value(2), count > 0, count <= 1000,
      let imageWidth = value(6), let imageHeight = value(7), info.count >= 8 + count * 4 else { return nil }
    var points: [Point] = []
    for index in 0..<count {
      guard let width = value(8 + index), let height = value(8 + count + index),
        let x = value(8 + count * 2 + index), let y = value(8 + count * 3 + index) else { return nil }
      points.append(Point(x: x, y: y, width: width, height: height))
    }
    // AFPointsInFocus: a bit mask, 16 points per word, starting after the four position arrays.
    let words = (count + 15) / 16
    func mask(at start: Int) -> [Int] {
      var result: [Int] = []
      for word in 0..<words {
        guard let raw = value(start + word) else { break }
        let bits = raw & 0xFFFF
        for bit in 0..<16 where bits & (1 << bit) != 0 && word * 16 + bit < count { result.append(word * 16 + bit) }
      }
      return result
    }
    let maskStart = 8 + count * 4
    let inFocus = mask(at: maskStart)
    // AFPointsSelected follows on models that record it (the 1D X series does).
    let selected = info.count >= maskStart + words * 2 ? mask(at: maskStart + words) : []
    return CanonFocusPoints(mode: mode, imageWidth: imageWidth, imageHeight: imageHeight, points: points,
      inFocus: inFocus, selected: selected)
  }
}
