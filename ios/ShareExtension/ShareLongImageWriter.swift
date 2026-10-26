import Foundation
import CoreGraphics
import zlib

/// 把分片截图按顺序流式压缩成一张完整 PNG；不为整图分配 RGBA 画布。
/// 输出为 8 位 RGB（PNG colorType 2），分片先在白底上合成，不写入 alpha。
final class ShareLongImageWriter {
    static let maximumWidth = 1500
    static let maximumHeight = 200_000

    /// PNG 文件签名，供纯原生 smoke 直接复用。
    static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private static let idatLimit = 64 * 1024
    private static let rowsPerBatch = 64
    private static let noFlush = Int32(Z_NO_FLUSH)
    private static let finishFlush = Int32(Z_FINISH)
    private static let ok = Int32(Z_OK)
    private static let streamEnd = Int32(Z_STREAM_END)
    private static let bufferError = Int32(Z_BUF_ERROR)

    private let url: URL
    private let width: Int
    private let height: Int
    private var completedRows = 0
    private var stream = z_stream()
    private var streamReady = false
    private var output = [UInt8](repeating: 0, count: 64 * 1024)
    private var chunk = Data()
    private var handle: FileHandle?
    private var ownsFile = false
    private var committed = false
    private var failed = false
    private var cancelled = false
    private var finished = false

    init(url: URL, width: Int, height: Int) throws {
        guard width > 0, width <= Self.maximumWidth else {
            throw ShareLongImageWriterError.message("长图宽度超出安全范围。")
        }
        guard height > 0, height <= Self.maximumHeight else {
            throw ShareLongImageWriterError.message("长图高度超出安全范围。")
        }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ShareLongImageWriterError.message("长图临时目录不存在。")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ShareLongImageWriterError.message("目标文件已存在，未覆盖。")
        }
        self.url = url
        self.width = width
        self.height = height
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ShareLongImageWriterError.message("无法创建长图文件。")
        }
        ownsFile = true
        do {
            handle = try FileHandle(forWritingTo: url)
            try write(Self.pngSignature)
            try writeChunk(type: "IHDR", payload: Self.pngIHDRPayload(width: width, height: height))
            try startDeflate()
        } catch {
            cancel()
            throw error
        }
    }

    /// 按从上到下的顺序追加一个分片；rows 必须等于图片实际像素高度。
    func append(_ image: CGImage, rows: Int) throws {
        do { try appendRows(image, rows: rows) }
        catch { cancel(); throw error }
    }

    private func appendRows(_ image: CGImage, rows: Int) throws {
        guard !cancelled, !finished, !failed else {
            throw ShareLongImageWriterError.message("长图写入已结束，不能继续追加分片。")
        }
        guard rows > 0 else {
            throw ShareLongImageWriterError.message("分片高度必须大于 0。")
        }
        guard completedRows + rows <= height else {
            throw ShareLongImageWriterError.message("分片高度超出长图总高度。")
        }
        guard image.width == width, image.height == rows else {
            throw ShareLongImageWriterError.message("分片尺寸与长图总宽度或总高度不一致。")
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ShareLongImageWriterError.message("无法创建 sRGB 颜色空间。")
        }
        let bytesPerRow = width * 4
        let scanlineBytes = width * 3 + 1
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows)
        var batch = [UInt8](repeating: 0, count: scanlineBytes * Self.rowsPerBatch)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        do {
            try pixels.withUnsafeMutableBytes { rawPixels in
                guard let context = CGContext(data: rawPixels.baseAddress, width: width, height: rows,
                                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                              space: colorSpace, bitmapInfo: bitmapInfo) else {
                    throw ShareLongImageWriterError.message("无法创建分片 RGBA 画布。")
                }
                // 白底合成后直接输出 RGB；预乘值加回 (255 - alpha) 即为白底上的颜色。
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: rows))
                // CGContext 原点在左下，但位图内存第一行对应图像顶部；正向整幅绘制即得从上到下顺序。
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: rows))
                let source = rawPixels.bindMemory(to: UInt8.self)
                guard let sourceBase = source.baseAddress else {
                    throw ShareLongImageWriterError.message("分片画布内存不可用。")
                }
                var row = 0
                while row < rows {
                    let count = min(Self.rowsPerBatch, rows - row)
                    try batch.withUnsafeMutableBytes { rawBatch in
                        guard let targetBase = rawBatch.bindMemory(to: UInt8.self).baseAddress else {
                            throw ShareLongImageWriterError.message("PNG 行缓冲不可用。")
                        }
                        for index in 0..<count {
                            let from = (row + index) * bytesPerRow
                            let to = index * scanlineBytes
                            targetBase[to] = 0
                            for x in 0..<width {
                                let pixel = from + x * 4
                                let overWhite = 255 - Int(sourceBase[pixel + 3])
                                targetBase[to + 1 + x * 3] = UInt8(min(255, Int(sourceBase[pixel]) + overWhite))
                                targetBase[to + 2 + x * 3] = UInt8(min(255, Int(sourceBase[pixel + 1]) + overWhite))
                                targetBase[to + 3 + x * 3] = UInt8(min(255, Int(sourceBase[pixel + 2]) + overWhite))
                            }
                        }
                        try deflateInput(UnsafeRawBufferPointer(start: rawBatch.baseAddress, count: scanlineBytes * count), flush: Self.noFlush)
                    }
                    row += count
                }
            }
        } catch {
            failed = true
            throw error
        }
        completedRows += rows
    }

    /// 只有分片累计高度与初始化高度完全一致才写出 IEND 并保留文件。
    func finish() throws {
        guard !cancelled else {
            throw ShareLongImageWriterError.message("长图写入已取消。")
        }
        guard !failed else {
            cancel()
            throw ShareLongImageWriterError.message("长图写入失败，未生成文件。")
        }
        guard !finished else { return }
        guard completedRows == height else {
            cancel()
            throw ShareLongImageWriterError.message("分片不足，未生成不完整长图。")
        }
        do {
            try deflateInput(nil, flush: Self.finishFlush)
            if !chunk.isEmpty {
                try writeChunk(type: "IDAT", payload: chunk)
                chunk.removeAll()
            }
            try writeChunk(type: "IEND", payload: Data())
            closeResources()
            committed = true
            ownsFile = false
            finished = true
        } catch {
            cancel()
            throw error
        }
    }

    /// 取消写入：结束 deflate、关闭文件并删除未完成的新文件。
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        finished = false
        closeResources()
        if ownsFile, !committed {
            try? FileManager.default.removeItem(at: url)
            ownsFile = false
        }
    }

    deinit {
        cancel()
    }

    // MARK: - 流式 PNG 写入

    private func startDeflate() throws {
        var status: Int32 = Int32(Z_STREAM_ERROR)
        withUnsafeMutablePointer(to: &stream) { pointer in
            status = zlib.deflateInit_(pointer, Int32(Z_DEFAULT_COMPRESSION), zlibVersion(),
                                       Int32(MemoryLayout<z_stream>.size))
        }
        guard status == Self.ok else {
            throw ShareLongImageWriterError.message("PNG 压缩器初始化失败。")
        }
        streamReady = true
    }

    private func write(_ data: Data) throws {
        guard let handle = handle else {
            throw ShareLongImageWriterError.message("长图文件已关闭。")
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ShareLongImageWriterError.message("长图写入失败，请检查可用存储空间。")
        }
    }

    private func writeChunk(type: String, payload: Data) throws {
        try write(Self.pngChunk(type: type, payload: payload))
    }

    private func emit(_ data: Data) throws {
        chunk.append(data)
        while chunk.count >= Self.idatLimit {
            try writeChunk(type: "IDAT", payload: Data(chunk.prefix(Self.idatLimit)))
            chunk.removeFirst(Self.idatLimit)
        }
    }

    /// 单次 deflate 可能无法吃完全部输入，循环直到输入耗尽或流结束。
    private func deflateInput(_ input: UnsafeRawBufferPointer?, flush: Int32) throws {
        let total = input?.count ?? 0
        let base = input?.bindMemory(to: UInt8.self).baseAddress
        var offset = 0
        while true {
            var status: Int32 = Self.ok
            var produced = 0
            var consumed = 0
            var outputFull = false
            try withUnsafeMutablePointer(to: &stream) { pointer in
                try output.withUnsafeMutableBufferPointer { buffer in
                    let remaining = total - offset
                    if remaining > 0, let base = base {
                        pointer.pointee.next_in = UnsafeMutablePointer(mutating: base + offset)
                    } else {
                        pointer.pointee.next_in = nil
                    }
                    pointer.pointee.avail_in = UInt32(remaining)
                    pointer.pointee.next_out = buffer.baseAddress
                    pointer.pointee.avail_out = UInt32(buffer.count)
                    status = zlib.deflate(pointer, flush)
                    consumed = remaining - Int(pointer.pointee.avail_in)
                    produced = buffer.count - Int(pointer.pointee.avail_out)
                    outputFull = pointer.pointee.avail_out == 0
                }
            }
            offset += consumed
            if produced > 0 {
                try emit(Data(output[0..<produced]))
            }
            if status == Self.streamEnd {
                guard offset == total else {
                    throw ShareLongImageWriterError.message("PNG 压缩输入未完全写入。")
                }
                return
            }
            guard status == Self.ok || status == Self.bufferError else {
                throw ShareLongImageWriterError.message("PNG 压缩失败。")
            }
            if flush != Self.finishFlush, offset == total, !outputFull {
                return
            }
            if consumed == 0, produced == 0, status == Self.bufferError {
                throw ShareLongImageWriterError.message("PNG 压缩未取得进展。")
            }
        }
    }

    private func closeResources() {
        if streamReady {
            _ = zlib.deflateEnd(&stream)
            streamReady = false
        }
        if let handle = handle {
            try? handle.close()
            self.handle = nil
        }
        chunk.removeAll()
    }

    // MARK: - 可复用的 PNG 打包 helper

    static func pngChunk(type: String, payload: Data) -> Data {
        var data = Data(capacity: payload.count + 12)
        data.append(pngBigEndian(UInt32(truncatingIfNeeded: payload.count)))
        data.append(contentsOf: Array(type.utf8))
        data.append(payload)
        data.append(pngBigEndian(pngCRC32(type: type, payload: payload)))
        return data
    }

    static func pngIHDRPayload(width: Int, height: Int) -> Data {
        var data = Data(capacity: 13)
        data.append(pngBigEndian(UInt32(truncatingIfNeeded: width)))
        data.append(pngBigEndian(UInt32(truncatingIfNeeded: height)))
        data.append(contentsOf: [UInt8(8), UInt8(2), UInt8(0), UInt8(0), UInt8(0)])
        return data
    }

    static func pngBigEndian(_ value: UInt32) -> Data {
        let big = value.bigEndian
        return withUnsafeBytes(of: big) { Data($0) }
    }

    static func pngCRC32(type: String, payload: Data) -> UInt32 {
        var value: UInt = zlib.crc32(0, nil, 0)
        let typeBytes = Array(type.utf8)
        typeBytes.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress, !buffer.isEmpty {
                value = zlib.crc32(value, base, UInt32(buffer.count))
            }
        }
        payload.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress, !raw.isEmpty {
                value = zlib.crc32(value, base, UInt32(raw.count))
            }
        }
        return UInt32(truncatingIfNeeded: value)
    }
}

enum ShareLongImageWriterError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
