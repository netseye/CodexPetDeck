import Foundation
import CoreGraphics
import ImageIO

/// 图标归一化(真机确认格式): 键图标 = 128×128 **RGB 无 alpha** PNG。
/// 官方所有键图标均为该格式; 调用方无需预缩放/预拍平。
///
/// `preservingAlpha` 变体保留 alpha 通道 — 真机确认设备会拿 alpha 与键后方内容
/// (含 GIF 背景)正确合成, 但这是固件能力、官方编辑器到不了: 用它做的主题
/// 最好视为设备专用(官方软件加载未验证)。
enum IconImageNormalizer {
    static let iconSize = 128

    /// 任意 PNG/GIF/JPEG → 128×128 RGB PNG(alpha 拍平到黑底)。
    static func normalizeToKeyIcon(_ imageData: Data) throws -> Data {
        try render(imageData, flattenAlpha: true)
    }

    /// 保留 alpha 的变体(透明区域透出键后方内容)。
    static func normalizeToKeyIconPreservingAlpha(_ imageData: Data) throws -> Data {
        try render(imageData, flattenAlpha: false)
    }

    private static func render(_ imageData: Data, flattenAlpha: Bool) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NormalizerError.unreadableImage
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: iconSize,
            height: iconSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            // 拍平: 无 alpha 通道(RGB); 保留: 预乘 alpha。
            bitmapInfo: flattenAlpha
                ? CGImageAlphaInfo.noneSkipFirst.rawValue
                : CGImageAlphaInfo.premultipliedFirst.rawValue,
        ) else {
            throw NormalizerError.contextCreationFailed
        }

        if flattenAlpha {
            // alpha 拍平到黑底(与官方图标一致)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
        }

        // 等比缩放居中(不拉伸变形)
        let scale = min(
            CGFloat(iconSize) / CGFloat(image.width),
            CGFloat(iconSize) / CGFloat(image.height),
        )
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        let drawX = (CGFloat(iconSize) - drawWidth) / 2
        let drawY = (CGFloat(iconSize) - drawHeight) / 2
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight))

        guard let output = context.makeImage() else {
            throw NormalizerError.renderFailed
        }
        return try encodePNG(output)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil
        ) else {
            throw NormalizerError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NormalizerError.encodeFailed
        }
        return output as Data
    }

    /// 动画键注册协议(KeyBuilder.animatedIcon 用; 桥接 ThemeBuilder 的 fileprivate 注册)。
    protocol AnimatedIconRegistry {
        /// 以指定设备路径注册资产, 返回该路径。
        func registerAsset(atPath path: String, data: Data) -> String
    }

    /// GIF 拆帧 → 每帧 128×128 RGB PNG, 注册为 <base>/frame_N.png; 返回 (文件夹路径, 帧延迟 CSV 毫秒)。
    /// 真机机制: 键的 path 空、paths=此文件夹、frameDelays=CSV(§7.1); 帧数上限 60 防失控。
    static func registerAnimatedIcon(
        registry: AnimatedIconRegistry,
        folderName: String,
        gifData: Data,
        maxFrames: Int = 60
    ) throws -> (folderPath: String, frameDelaysCSV: String) {
        guard let source = CGImageSourceCreateWithData(gifData as CFData, nil) else {
            throw NormalizerError.unreadableImage
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw NormalizerError.unreadableImage }

        let base = "/image/MK20/cache/\(folderName)"
        var delays: [String] = []
        let limit = min(frameCount, maxFrames)

        for index in 0..<limit {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw NormalizerError.renderFailed
            }
            // GIF 帧延迟: kCGImagePropertyGIFDictionary 的 UnclampedDelayTime(秒), 缺省 0.1s。
            var delaySeconds = 0.1
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               let gifProps = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                if let unclamped = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
                    delaySeconds = unclamped
                } else if let clamped = gifProps[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0 {
                    delaySeconds = clamped
                }
            }
            delays.append(String(Int((delaySeconds * 1000).rounded())))

            let framePNG = try encodePNG(renderNormalized(image))
            _ = registry.registerAsset(atPath: "\(base)/frame_\(index).png", data: framePNG)
        }

        return (base, delays.joined(separator: ","))
    }

    /// 归一化渲染一张已解码帧(与静态图标同规格)。
    private static func renderNormalized(_ image: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: iconSize, height: iconSize,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { throw NormalizerError.contextCreationFailed }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
        let scale = min(CGFloat(iconSize) / CGFloat(image.width), CGFloat(iconSize) / CGFloat(image.height))
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (CGFloat(iconSize) - drawWidth) / 2,
            y: (CGFloat(iconSize) - drawHeight) / 2,
            width: drawWidth, height: drawHeight
        ))
        guard let output = context.makeImage() else { throw NormalizerError.renderFailed }
        return output
    }

    enum NormalizerError: LocalizedError {
        case unreadableImage
        case contextCreationFailed
        case renderFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "无法读取图像数据"
            case .contextCreationFailed: "无法创建图像上下文"
            case .renderFailed: "图像渲染失败"
            case .encodeFailed: "PNG 编码失败"
            }
        }
    }
}
