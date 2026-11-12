import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SessionKit

/// #2708 PR 1: fitting, encoding and thumbnailing a photo with real ImageIO on macOS. Fixture images are generated here;
/// no test touches a Library or a real photo. The rules around the result are `LiveSessionPhotoStoreTests` (Linux too).
final class LiveSessionPhotoEncoderTests: XCTestCase {
    /// A page-like fixture: light paper with dark stripes and a gradient, so it compresses like text, not like noise.
    private func pageImage(width: Int, height: Int) throws -> CGImage {
        try image(width: width, height: height) { x, y in
            let stripe = (y / 12) % 3 == 0 && (x / 7) % 5 != 0
            let base = UInt8(230 - (x * 40 / max(width, 1)))
            return stripe ? (30, 30, 40) : (base, base, base - 10)
        }
    }

    /// Hard to compress: every pixel random, from a fixed seed.
    private func noiseImage(width: Int, height: Int) throws -> CGImage {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return try image(width: width, height: height) { _, _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (UInt8(truncatingIfNeeded: state >> 24), UInt8(truncatingIfNeeded: state >> 32), UInt8(truncatingIfNeeded: state >> 40))
        }
    }

    private func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let offset = (y * width + x) * 4
                buffer[offset] = r
                buffer[offset + 1] = g
                buffer[offset + 2] = b
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(buffer) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func data(_ image: CGImage, type: String = "public.jpeg", properties: [CFString: Any] = [:]) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type as CFString, 1, nil), "no \(type) encoder here")
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func size(of data: Data) throws -> (Int, Int) {
        let p = try properties(of: data)
        return (try XCTUnwrap(p[kCGImagePropertyPixelWidth] as? Int), try XCTUnwrap(p[kCGImagePropertyPixelHeight] as? Int))
    }

    // MARK: Encode

    func testAPhoneSizedPictureIsFittedAndKeptWithinBothCaps() throws {
        let source = try data(pageImage(width: 4_000, height: 3_000))
        let encoded = try LiveSessionPhotoEncoder.encode(source)
        // ImageIO rounds the short side itself, so it may differ from `fitted` by a pixel.
        XCTAssertEqual(encoded.widthPx, 2_048)
        XCTAssertEqual(Double(encoded.heightPx), 1_536, accuracy: 1)
        XCTAssertLessThanOrEqual(encoded.data.count, LiveSessionPhoto.maxByteCount)
        let written = try size(of: encoded.data)
        XCTAssertEqual([written.0, written.1], [encoded.widthPx, encoded.heightPx], "the reported size is the file's")
        XCTAssertNotNil(LiveSessionPhoto(path: "SpokenMargins/live-photos/s/m.jpg", widthPx: encoded.widthPx, heightPx: encoded.heightPx, byteCount: encoded.data.count))
    }

    func testASmallPictureIsNotEnlarged() throws {
        let encoded = try LiveSessionPhotoEncoder.encode(data(pageImage(width: 640, height: 480)))
        XCTAssertEqual([encoded.widthPx, encoded.heightPx], [640, 480])
        let tiny = try LiveSessionPhotoEncoder.encode(data(pageImage(width: 3, height: 2)))
        XCTAssertEqual([tiny.widthPx, tiny.heightPx], [3, 2])
    }

    func testATurnedPictureIsTurnedIntoThePixelsAndLeavesNoRotationTag() throws {
        let source = try pageImage(width: 400, height: 200)
        // Orientation 6: the camera held in portrait; the stored pixels are landscape and a tag says "rotate right".
        let turned = try LiveSessionPhotoEncoder.encode(data(source, properties: [kCGImagePropertyOrientation: 6]))
        XCTAssertEqual([turned.widthPx, turned.heightPx], [200, 400])
        let tag = try properties(of: turned.data)[kCGImagePropertyOrientation] as? Int
        XCTAssertTrue(tag == nil || tag == 1, "no rotation tag is left to apply twice")
    }

    func testNothingFromTheOriginalsMetadataIsKept() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 44.9, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 93.2, kCGImagePropertyGPSLongitudeRef: "W"]
        let exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "taken at the library"]
        let source = try data(pageImage(width: 800, height: 600), properties: [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: exif])
        XCTAssertNotNil(try properties(of: source)[kCGImagePropertyGPSDictionary], "fixture must carry a location")
        let encoded = try LiveSessionPhotoEncoder.encode(source)
        let kept = try properties(of: encoded.data)
        XCTAssertNil(kept[kCGImagePropertyGPSDictionary])
        let keptExif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(keptExif?[kCGImagePropertyExifUserComment])
    }

    func testOtherFormatsAreReadAndComeOutAsJPEG() throws {
        let image = try pageImage(width: 1_200, height: 800)
        let png = try LiveSessionPhotoEncoder.encode(data(image, type: "public.png"))
        XCTAssertEqual(png.fileExtension, "jpg")
        XCTAssertEqual(Array(png.data.prefix(2)), [0xFF, 0xD8], "a JPEG starts with FF D8")
        // HEIC is the iPhone's own format. A machine with no HEIC encoder cannot make the fixture; that is not a failure here.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.heic" as CFString, 1, nil) else {
            throw XCTSkip("this machine has no HEIC encoder to make the fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("this machine could not write the HEIC fixture") }
        let heic = try LiveSessionPhotoEncoder.encode(output as Data)
        XCTAssertEqual([heic.widthPx, heic.heightPx], [1_200, 800])
    }

    func testAHardPictureStillFitsTheByteCapBySmallerQualityThenSize() throws {
        let source = try data(noiseImage(width: 2_048, height: 1_536), properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        XCTAssertGreaterThan(source.count, LiveSessionPhoto.maxByteCount, "fixture must be too big as it is")
        let encoded = try LiveSessionPhotoEncoder.encode(source)
        XCTAssertLessThanOrEqual(encoded.data.count, LiveSessionPhoto.maxByteCount)
        XCTAssertLessThanOrEqual(max(encoded.widthPx, encoded.heightPx), LiveSessionPhoto.maxLongEdgePixels)
        XCTAssertGreaterThan(encoded.widthPx, 0)
    }

    func testACapNothingCanMeetIsRefusedNotBroken() throws {
        let source = try data(noiseImage(width: 600, height: 400))
        XCTAssertThrowsError(try LiveSessionPhotoEncoder.encode(source, maxByteCount: 200)) {
            XCTAssertEqual($0 as? LiveSessionPhotoEncoder.EncodeError, .tooLarge)
        }
    }

    func testCorruptEmptyAndNonImageDataAreRefused() throws {
        let good = try data(pageImage(width: 800, height: 600))
        let cases: [(String, Data)] = [
            ("empty", Data()), ("text", Data("not a picture".utf8)), ("zeros", Data(count: 4_096)),
            ("header only", good.prefix(20)), ("sliced in half", good.prefix(good.count / 2))
        ]
        for (name, bytes) in cases {
            // A half picture may decode partly: either it is refused, or whatever comes out keeps every rule.
            do {
                let encoded = try LiveSessionPhotoEncoder.encode(bytes)
                XCTAssertEqual(name, "sliced in half", "\(name) should have been refused")
                XCTAssertLessThanOrEqual(encoded.data.count, LiveSessionPhoto.maxByteCount)
            } catch {
                XCTAssertEqual(error as? LiveSessionPhotoEncoder.EncodeError, .unreadable, name)
            }
        }
    }

    // MARK: Thumbnails

    func testAThumbnailIsSmallAndMadeFromTheKeptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photo-thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "m.jpg")
        try LiveSessionPhotoEncoder.encode(data(pageImage(width: 4_000, height: 3_000))).data.write(to: file)

        let thumb = try XCTUnwrap(LiveSessionPhotoEncoder.thumbnail(of: file))
        let (width, height) = try size(of: thumb)
        XCTAssertEqual(max(width, height), 144)
        XCTAssertEqual(Double(width) / Double(height), 4.0 / 3.0, accuracy: 0.05)
        XCTAssertLessThan(thumb.count, 30_000)
    }

    func testNoThumbnailForAMissingOrBrokenFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photo-thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(LiveSessionPhotoEncoder.thumbnail(of: directory.appending(path: "gone.jpg")))
        let broken = directory.appending(path: "broken.jpg")
        try Data("nope".utf8).write(to: broken)
        XCTAssertNil(LiveSessionPhotoEncoder.thumbnail(of: broken))
        XCTAssertNil(LiveSessionPhotoEncoder.thumbnail(of: directory), "a folder is not a photo")
        XCTAssertNil(LiveSessionPhotoEncoder.thumbnail(of: broken, maxPixelSize: 0))
    }

    // MARK: With the store

    func testAnEncodedPhotoStagesAndCommitsThroughTheStore() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "photo-both-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = LiveSessionPhotoStore(root: base.appending(path: "support"), temporaryRoot: base.appending(path: "tmp"))
        let encoded = try LiveSessionPhotoEncoder.encode(data(pageImage(width: 3_024, height: 4_032)))
        XCTAssertEqual(encoded.heightPx, 2_048)
        XCTAssertEqual(Double(encoded.widthPx), 1_536, accuracy: 1)
        let staged = try store.stage(data: encoded.data, widthPx: encoded.widthPx, heightPx: encoded.heightPx, fileExtension: encoded.fileExtension)
        let photo = try store.commit(staged, sessionId: "s1", marginId: "m1")
        XCTAssertTrue(store.fileExists(for: photo))
        let thumb = LiveSessionPhotoEncoder.thumbnail(of: try XCTUnwrap(store.fileURL(for: photo)))
        XCTAssertNotNil(thumb)
    }
}
