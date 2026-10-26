import Foundation
import CoreGraphics
import zlib

@main
struct ShareImageSmoke {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "长图回归", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func image(width: Int, rows: [[UInt8]]) throws -> CGImage {
        var data = Data()
        for row in rows {
            for _ in 0..<width { data.append(contentsOf: row + [255]) }
        }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func decode(_ file: URL, width: Int, height: Int) throws -> Data {
        let png = try Data(contentsOf: file)
        try require(png.prefix(8) == ShareLongImageWriter.pngSignature, "缺少 PNG 签名")
        func number(_ offset: Int) -> Int {
            png[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        var offset = 8
        var compressed = Data()
        var ended = false
        while offset < png.count {
            let count = number(offset)
            let name = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let body = Data(png[(offset + 8)..<(offset + 8 + count)])
            try require(UInt32(number(offset + 8 + count)) == ShareLongImageWriter.pngCRC32(type: name, payload: body), "PNG 校验失败")
            if name == "IHDR" {
                try require(number(offset + 8) == width && number(offset + 12) == height, "PNG 尺寸不是完整长图")
            } else if name == "IDAT" { compressed.append(body) }
            else if name == "IEND" { ended = true }
            offset += count + 12
        }
        try require(ended, "缺少 IEND")
        var length = UInt((width * 3 + 1) * height)
        var pixels = [UInt8](repeating: 0, count: Int(length))
        let code = pixels.withUnsafeMutableBufferPointer { output in
            compressed.withUnsafeBytes { input in
                zlib.uncompress(output.baseAddress, &length, input.bindMemory(to: UInt8.self).baseAddress, UInt(compressed.count))
            }
        }
        try require(code == Z_OK && Int(length) == pixels.count, "PNG 压缩流包含错误或多余尾行")
        return Data(pixels)
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255]]
        let file = root.appendingPathComponent("whole.png")
        let writer = try ShareLongImageWriter(url: file, width: 17, height: 72)
        try writer.append(image(width: 17, rows: colors), rows: 3)
        let rest = (0..<69).map { colors[$0 % 3] }
        try writer.append(image(width: 17, rows: rest), rows: 69)
        try writer.finish()
        let data = try decode(file, width: 17, height: 72)
        let expected = colors + rest
        for row in 0..<72 {
            let offset = row * (17 * 3 + 1)
            try require(data[offset] == 0, "扫描行过滤错误")
            for x in 0..<17 {
                try require(Array(data[(offset + 1 + x * 3)..<(offset + 4 + x * 3)]) == expected[row], "长图倒置、漏行或拼接边界错误")
            }
        }
        writer.cancel()
        try require(FileManager.default.fileExists(atPath: file.path), "已完成文件被取消操作删除")
        do {
            _ = try ShareLongImageWriter(url: file, width: 17, height: 72)
            try require(false, "覆盖已有图片")
        } catch is ShareLongImageWriterError {}
        let partial = root.appendingPathComponent("partial.png")
        let incomplete = try ShareLongImageWriter(url: partial, width: 17, height: 4)
        try incomplete.append(image(width: 17, rows: colors), rows: 3)
        do { try incomplete.finish(); try require(false, "缺片也生成成功") }
        catch is ShareLongImageWriterError {}
        try require(!FileManager.default.fileExists(atPath: partial.path), "缺片文件未清理")
        let invalid = root.appendingPathComponent("invalid.png")
        let wrong = try ShareLongImageWriter(url: invalid, width: 17, height: 2)
        do { try wrong.append(image(width: 17, rows: colors), rows: 3); try require(false, "超片未拒绝") }
        catch is ShareLongImageWriterError {}
        try require(!FileManager.default.fileExists(atPath: invalid.path), "无效分片文件未清理")
        print("通过：单张长图尺寸、逐行像素方向、跨片边界、64行尾批、CRC/压缩流、缺片拒绝及临时文件清理")
    }
}
