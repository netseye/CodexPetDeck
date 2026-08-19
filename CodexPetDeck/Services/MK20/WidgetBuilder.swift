import Foundation

/// #26 widget 仪表盘 item 构建(字段集与 MK20Control ThemeItemSkeletons 对齐 —
/// 后者交叉验证自多个真机主题文件, 缺字段会令 SET_DEVICE_RELOAD 卡死)。
///
/// 通用字段(id/itemName/x/y/z/w/h/rotate/scale/lock/type)由 WidgetItem.finalize 统一写入;
/// 各类型的专有字段在各自 makeFields 里产出(顺序与官方编辑器保存文件一致)。
///
/// 系统数据绑定: system_data_flag="1" + system_data_name=<键名> +
/// system_data_min_value/system_data_max_value(量程); 键名须是设备
/// deviceRequestSystemData 声明的(如 Cpu/Gpu/Memory), 宿主经 cmd=1 每 2s 推送。
enum WidgetKind: String, CaseIterable, Identifiable {
    case background = "100"       // 背景(图片/视频)
    case circularGauge = "101"    // 圆仪表(实色环)
    case progressBar = "102"      // 进度条(渐变边框)
    case linearGauge = "103"      // 线性仪表
    case segmentedGauge = "104"   // 分段圆仪表(与 101 同字段集)
    case radialGauge = "109"      // 径向仪表(3 段渐变弧)
    case lightShadowGauge = "110" // 光影仪表
    case digitalClock = "111"     // 数字时钟(时/分/秒各一 item)
    case text = "113"             // 文本
    case gif = "114"              // 动图
    case multilineText = "116"    // 多行文本
    case shadowText = "117"       // 阴影文本

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .background: "背景"
        case .circularGauge: "圆仪表"
        case .progressBar: "进度条"
        case .linearGauge: "线性仪表"
        case .segmentedGauge: "分段圆仪表"
        case .radialGauge: "径向仪表"
        case .lightShadowGauge: "光影仪表"
        case .digitalClock: "数字时钟"
        case .text: "文本"
        case .gif: "动图"
        case .multilineText: "多行文本"
        case .shadowText: "阴影文本"
        }
    }
}

/// 颜色统一用官方 RGBA 文本格式(如 "r=255,g=64,b=64,a=255")。
struct WidgetColor {
    var r: Int
    var g: Int
    var b: Int
    var a: Int = 255

    var rgbaText: String { "r=\(r),g=\(g),b=\(b),a=\(a)" }

    static let white = WidgetColor(r: 255, g: 255, b: 255)
    static let black = WidgetColor(r: 0, g: 0, b: 0)
    static let red = WidgetColor(r: 255, g: 64, b: 64)
    static let blue = WidgetColor(r: 64, g: 128, b: 255)
    static let gray = WidgetColor(r: 60, g: 60, b: 60)
}

/// 官方字体描述符: "family,size,-1,5,weight,0,0,0,0,0[,style]"。
struct WidgetFont {
    var family: String
    var size: Int
    var weight: Int = 50

    var fontText: String { "\(family),\(size),-1,5,\(weight),0,0,0,0,0" }

    static let yaHei24 = WidgetFont(family: "Microsoft YaHei", size: 24)
    static let yaHei32 = WidgetFont(family: "Microsoft YaHei", size: 32)
}

/// widget item 构建器: 通用几何 + 类型专有字段 + 系统数据绑定。
final class WidgetItem {
    private let id: String
    private let kind: WidgetKind
    private var itemName: String
    private var x: Int
    private var y: Int
    private var z = 1
    private var width: Int?
    private var height: Int?
    private var rotate = 0
    private var scale = 1.0
    private var lock = true

    /// 系统数据绑定(nil = 不绑定)。
    private var systemDataName: String?
    private var systemDataMin: Double?
    private var systemDataMax: Double?

    /// 类型专有字段(有序)。
    private var fields: [(String, String)] = []
    /// 资产路径(背景/GIF 的 path)。
    private var assetPath: String?
    private var backgroundType: String?

    init(kind: WidgetKind, id: String, itemName: String? = nil, x: Int, y: Int) {
        self.kind = kind
        self.id = id
        self.itemName = itemName ?? "control\(id)"
        self.x = x
        self.y = y
    }

    // MARK: - 通用几何

    @discardableResult func setSize(_ width: Int, _ height: Int) -> WidgetItem {
        self.width = width
        self.height = height
        return self
    }

    /// 覆盖初始化时的位置(背景类 widget 做非全屏放置时用)。
    @discardableResult func setPosition(_ x: Int, _ y: Int) -> WidgetItem {
        self.x = x
        self.y = y
        return self
    }

    @discardableResult func setZ(_ z: Int) -> WidgetItem {
        self.z = z
        return self
    }

    @discardableResult func setRotation(_ degrees: Int) -> WidgetItem {
        rotate = degrees
        return self
    }

    /// 系统数据绑定(键名来自设备 deviceRequestSystemData, 如 "Cpu"/"Gpu"/"Memory")。
    @discardableResult func bind(systemData name: String, min: Double, max: Double) -> WidgetItem {
        systemDataName = name
        systemDataMin = min
        systemDataMax = max
        return self
    }

    // MARK: - 类型专有配置(按需调用; 未调用的用类型默认)

    @discardableResult func setField(_ key: String, _ value: String) -> WidgetItem {
        if let i = fields.firstIndex(where: { $0.0 == key }) {
            fields[i] = (key, value)
        } else {
            fields.append((key, value))
        }
        return self
    }

    @discardableResult func setAsset(path: String, backgroundType: String? = nil) -> WidgetItem {
        assetPath = path
        self.backgroundType = backgroundType
        return self
    }

    /// 标记控件属于 428×142 副屏。官方主题要求动态副屏控件同时带
    /// backgroundType=secondary 与相对副屏原点的 backupX/backupY；只有
    /// 绝对 x/y 时虽然能画出默认值，但 cmd=1 不会刷新它。
    @discardableResult func placeOnSecondaryScreen() -> WidgetItem {
        backgroundType = "secondary"
        return self
    }

    // MARK: - 常用快捷配置

    /// 圆仪表/分段仪表配色。
    @discardableResult func gaugeColors(front: WidgetColor, back: WidgetColor, margin: Double = 10, radius: Double = 45) -> WidgetItem {
        setField("front_color", front.rgbaText)
        setField("back_color", back.rgbaText)
        setField("margin", fmt(margin))
        setField("radius", fmt(radius))
        return self
    }

    /// 文本类字体/颜色。
    @discardableResult func text(content: String, font: WidgetFont, color: WidgetColor) -> WidgetItem {
        if kind == .text || kind == .multilineText || kind == .shadowText {
            setField("text_str", content)
        }
        setField("text_font", font.fontText)
        setField("front_color", color.rgbaText)
        setField("text_customFont_flag", "")
        setField("text_customFont_path", "")
        return self
    }

    /// 时钟显示字段("hour"/"minute"/"second")。
    @discardableResult func clockField(_ field: String, font: WidgetFont, color: WidgetColor,
                    back: WidgetColor, displayNum: Int = 2) -> WidgetItem {
        setField("front_color", color.rgbaText)
        setField("back_color", back.rgbaText)
        setField("border_color", WidgetColor.black.rgbaText)
        setField("border_width", "0")
        setField("corner_radius", "0")
        setField("displayNum", String(displayNum))
        setField("displayType", "0")
        setField("paths", "")
        setField("text_customFont_flag", "")
        setField("text_customFont_path", "")
        setField("text_font", font.fontText)
        setField("transition", "0")
        return bind(systemData: field, min: 0, max: 0)
    }

    /// 光影仪表全套参数。
    @discardableResult func lightShadow(back: WidgetColor, arc: WidgetColor, arcWidth: Double, radius: Double,
                     clockwise: Bool, displayDirection: Double,
                     shadowColor: WidgetColor, shadowLighter: Double, shadowPosition: Double) -> WidgetItem {
        setField("back_color", back.rgbaText)
        setField("arcColor", arc.rgbaText)
        setField("arcWidth", fmt(arcWidth))
        setField("radius", fmt(radius))
        setField("Clockwise", clockwise ? "1" : "0")
        setField("DisplayDirection", fmt(displayDirection))
        setField("lightShadowColor", shadowColor.rgbaText)
        setField("lightShadowLighter", fmt(shadowLighter))
        setField("lightShadowPosition", fmt(shadowPosition))
        return self
    }

    /// 进度条/线性仪表配色(带边框)。
    @discardableResult func barColors(front: WidgetColor, back: WidgetColor, border: WidgetColor,
                   borderWidth: Double, cornerRadius: Double = 0) -> WidgetItem {
        setField("front_color", front.rgbaText)
        setField("back_color", back.rgbaText)
        setField("border_color", border.rgbaText)
        setField("border_width", fmt(borderWidth))
        if kind == .progressBar {
            setField("corner_radius", fmt(cornerRadius))
            setField("lineargradient_flag", "0")
            setField("lineargradient_color", "r=000,g=000,b=255,a=255")
        }
        return self
    }

    // MARK: - 输出

    /// 产出完整 item 字典(通用字段 + 专有字段 + 系统数据绑定)。
    func finalize() -> [String: String] {
        var item: [String: String] = [
            "id": id,
            "itemName": itemName,
            "type": kind.rawValue,
            "x": String(x),
            "y": String(y),
            "z": String(z),
            "rotate": String(rotate),
            "scale": fmt(scale),
            "lock": lock ? "1" : "0",
        ]
        if let width { item["w"] = String(width) }
        if let height { item["h"] = String(height) }

        // 系统数据绑定(widget 类型通用; main 背景除外)
        if systemDataName != nil, !(kind == .gif && backgroundType == "main") {
            item["system_data_flag"] = "1"
            item["system_data_name"] = systemDataName
            if let systemDataMin { item["system_data_min_value"] = fmt(systemDataMin) }
            if let systemDataMax { item["system_data_max_value"] = fmt(systemDataMax) }
        } else if hasSystemDataFieldByDefault {
            item["system_data_flag"] = "0"
        }

        // 背景/GIF 资产与类型
        if let backgroundType {
            item["backgroundType"] = backgroundType
            if backgroundType == "secondary" {
                item["backupX"] = String(max(0, x - ScreenLayout.secondaryScreenLeft))
                item["backupY"] = String(y)
            }
        }
        if let assetPath {
            item["path"] = assetPath
        }

        // 类型专有字段
        for (key, value) in fields {
            item[key] = value
        }

        // 各类型必带字段兜底(缺字段官方软件锁死/真机 reload 卡死)
        applySkeletonDefaults(to: &item)
        return item
    }

    /// 该类型在官方文件中恒带 system_data_flag(即便未绑定)。
    private var hasSystemDataFieldByDefault: Bool {
        switch kind {
        case .circularGauge, .segmentedGauge, .progressBar, .linearGauge, .radialGauge,
             .lightShadowGauge, .digitalClock, .text, .gif, .multilineText, .shadowText:
            true
        case .background:
            false
        }
    }

    /// 按 ThemeItemSkeletons 补全各类型的必带字段(仅当调用方未显式设置时)。
    private func applySkeletonDefaults(to item: inout [String: String]) {
        func ensure(_ key: String, _ value: String) {
            if item[key] == nil { item[key] = value }
        }
        switch kind {
        case .background:
            ensure("maxWidth", String(ScreenLayout.canvasWidth))
            ensure("maxHeight", String(ScreenLayout.canvasHeight))
            ensure("path", "")
            // 副屏背景恒带 backupX/backupY(官方主题样本: 值 = x/y 复制) —
            // 设备用它锚定副屏层, 缺失则副屏背景不渲染(#27 真机实测)。
            if backgroundType == "secondary" {
                ensure("backupX", String(max(0, x - ScreenLayout.secondaryScreenLeft)))
                ensure("backupY", String(y))
            }
        case .circularGauge, .segmentedGauge:
            ensure("front_color", WidgetColor.blue.rgbaText)
            ensure("back_color", WidgetColor.gray.rgbaText)
            ensure("margin", "10")
            ensure("radius", "45")
        case .progressBar:
            ensure("front_color", WidgetColor.blue.rgbaText)
            ensure("back_color", WidgetColor.gray.rgbaText)
            ensure("border_color", WidgetColor.white.rgbaText)
            ensure("border_width", "2")
            ensure("corner_radius", "5")
            ensure("lineargradient_flag", "0")
            ensure("lineargradient_color", "r=000,g=000,b=255,a=255")
            ensure("maxWidth", "100")
            ensure("maxHeight", "20")
        case .linearGauge:
            ensure("front_color", WidgetColor.blue.rgbaText)
            ensure("back_color", WidgetColor.gray.rgbaText)
            ensure("border_color", WidgetColor.white.rgbaText)
            ensure("border_width", "1")
        case .radialGauge:
            ensure("radius", "50")
            ensure("angleMinValue", "0")
            ensure("angleMaxValue", "270")
            ensure("arcRadius", "45")
            ensure("arcCircularInterval", "10")
            ensure("gradientColor1", WidgetColor.blue.rgbaText)
            ensure("gradientColor2", WidgetColor.green.rgbaText)
            ensure("gradientColor3", WidgetColor.red.rgbaText)
            ensure("Clockwise", "1")
        case .lightShadowGauge:
            ensure("back_color", WidgetColor.gray.rgbaText)
            ensure("arcColor", WidgetColor.blue.rgbaText)
            ensure("arcWidth", "8")
            ensure("radius", "50")
            ensure("Clockwise", "1")
            ensure("DisplayDirection", "0")
            ensure("lightShadowColor", WidgetColor.white.rgbaText)
            ensure("lightShadowLighter", "30")
            ensure("lightShadowPosition", "50")
        case .digitalClock:
            ensure("front_color", WidgetColor.white.rgbaText)
            ensure("back_color", WidgetColor.black.rgbaText)
            ensure("border_color", WidgetColor.black.rgbaText)
            ensure("border_width", "0")
            ensure("corner_radius", "0")
            ensure("displayNum", "2")
            ensure("displayType", "0")
            ensure("paths", "")
            ensure("text_customFont_flag", "")
            ensure("text_customFont_path", "")
            ensure("text_font", WidgetFont.yaHei24.fontText)
            ensure("transition", "0")
        case .text, .multilineText:
            ensure("front_color", WidgetColor.white.rgbaText)
            ensure("text_customFont_flag", "")
            ensure("text_customFont_path", "")
            ensure("text_font", WidgetFont.yaHei24.fontText)
            if kind == .multilineText { ensure("text_str", "") }
        case .shadowText:
            ensure("front_color", WidgetColor.white.rgbaText)
            ensure("text_customFont_flag", "")
            ensure("text_customFont_path", "")
            ensure("text_font", WidgetFont.yaHei24.fontText)
            ensure("border_color", WidgetColor.black.rgbaText)
            ensure("border_width", "0")
            ensure("shadeColor", WidgetColor.black.rgbaText)
            ensure("shadeSize", "3")
        case .gif:
            ensure("maxWidth", "100")
            ensure("maxHeight", "100")
            ensure("paths", "")
            if backgroundType == "secondary" {
                ensure("backupX", String(max(0, x - ScreenLayout.secondaryScreenLeft)))
                ensure("backupY", String(y))
            }
        }
    }

    private func fmt(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }
}

extension WidgetColor {
    static let green = WidgetColor(r: 64, g: 255, b: 128)
}
