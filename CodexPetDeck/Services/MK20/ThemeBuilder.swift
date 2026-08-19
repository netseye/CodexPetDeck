import Foundation

/// MK20 屏幕几何(真机确认, MK20Control ScreenLayout):
/// 画布 640×656; 键格 4 行 × 5 列, 每格 128×128, 主屏起于 y=144;
/// 副屏条 428×142 位于 (106, 0)。
enum ScreenLayout {
    static let canvasWidth = 640
    static let canvasHeight = 656
    static let keyRows = 4
    static let keyColumns = 5
    static let keyCellSize = 128
    static let mainScreenTop = 144
    static let secondaryScreenLeft = 106
    static let secondaryScreenWidth = 428
    static let secondaryScreenHeight = 142

    /// 键格 (row 0-3, col 0-4) 的左上角像素坐标。
    static func keyCellOrigin(row: Int, column: Int) -> (x: Int, y: Int) {
        (column * keyCellSize, mainScreenTop + row * keyCellSize)
    }
}

/// 按键动作(controlData 内的 QVariant map, §7.2)。
/// 只建模常用动作; 其余类型以原始字段字典原样编码。
enum KeyAction {
    case keyboard(keycode: Int32, keyString: String?)
    /// mode: 1=上一页, 2=下一页, 0=跳转到 pageIndex。
    case pageSwitch(mode: Int32, pageIndex: Int32?)
    /// 进入 pageName 指定的页(文件夹); 目标页需配 oneLevelUp 返回。
    case openPage(pageName: String)
    /// 返回上一级; 哨兵 pageName="parentPage", 由目标页的 parentPageName 解析。
    /// ⚠ 真机语义(2026-08-15 实测 + MK20Control NavigationTheme 注释): oneLevelUp 只在
    /// 经 openPage 进入的**文件夹页**(带 parentPageName)上生效; pageSwitch 跳入的普通页
    /// 上按它无反应 — 普通页的"返回"用 pageSwitch(mode:0, pageIndex:0)(官方 defaultTheme 形态)。
    case oneLevelUp
    /// text 型: 宿主收到上报后代输入(设备自身不执行)。
    case typeText(text: String, pressEnterAfter: Bool)
    /// 旋钮三向键击(设备原生执行, 支持方向): 左转/按下/右转各绑一键。
    /// keycode 修饰键打包同 keyboard: (modifiers<<8)|usage, 0 = 未绑定。
    case encoderKeyboard(left: Int32, leftLabel: String,
                         middle: Int32, middleLabel: String,
                         right: Int32, rightLabel: String)
    /// 旋钮内置函数: systemVolume / systemMedia / deviceBrightness / deviceVolume。
    /// ⚠ 函数型旋钮上报不含方向(左转/右转/按下同伪行); 要方向用 encoderKeyboard。
    case encoderFunction(type: String)
    /// 未知/透传: 字段原样保留。
    case raw(type: String, fields: [String: ThemeFileCodec.TaggedValue])

    var typeName: String {
        switch self {
        case .keyboard: "keyboard"
        case .pageSwitch: "pageSwitch"
        case .openPage: "openPage"
        case .oneLevelUp: "oneLevelUp"
        case .typeText: "text"
        case .encoderKeyboard: "encoder_keyboard"
        case .encoderFunction(let type): type
        case .raw(let type, _): type
        }
    }
}

/// 两枚物理旋钮的固定副屏坐标与伪行(真机确认): 设备靠"键位于该坐标"识别旋钮。
enum EncoderSide {
    case left
    case right

    /// 副屏固定坐标(x, y)。
    var position: (x: Int, y: Int) {
        switch self {
        case .left: (106, 0)
        case .right: (320, 0)
        }
    }

    /// cmd=13 事件伪行(row==col)。
    var pseudoRow: Int {
        switch self {
        case .left: 100
        case .right: 103
        }
    }
}

/// 流式 `.Theme` 构建器: 页 → 键/图标/动作 → ThemeFileCodec.encode。
///
/// 产出与官方 ScreenKeyWindows 保存文件同构(§7/§10 Item #10 的全部坑已规避):
/// - keyMacroValue 92B 常量(text 键依赖);
/// - 键 item 必带全字段(缺 itemName 官方软件锁死);
/// - 页必带 encoder 数组(缺失官方软件锁死);
/// - JSON 规范化: 4 空格缩进 / \n / 键字母序 / 数值全为字符串。
final class ThemeBuilder {
    var language: Int32 = 1
    var layoutVersion = "V3.0"

    private var pages: [PageBuilder] = []
    private var assets: [String: Data] = [:]
    private var assetOrder: [String] = []
    private var nextItemID = 1

    /// 图标资产命名空间(设备路径 /image/MK20/<主题名>/...)。
    private let themeName: String

    init(themeName: String) {
        self.themeName = themeName
    }

    func addPage(_ configure: (PageBuilder) -> Void) -> PageBuilder {
        let page = PageBuilder(owner: self, pageID: UUID().uuidString)
        configure(page)
        pages.append(page)
        return page
    }

    /// 构建主题; 首页成为 main.currentPage。
    func build() throws -> ThemeFile {
        guard !pages.isEmpty else {
            throw ThemeFileCodecError.invalid("主题至少需要一页")
        }
        // 固件红线(#35 实验 C): 每个 type-100 视频项起一个 videoplayerinte 解码进程
        // (40-64MB VM), >1 个即可能 OOM 把设备打进崩溃-重启死循环。构建期直接拒绝。
        let videoCount = pages.flatMap(\.items).filter { $0["type"] == WidgetKind.background.rawValue }
            .filter { ($0["path"] ?? "").hasSuffix(".mp4") }.count
        if videoCount > 1 {
            throw ThemeFileCodecError.invalid(
                "视频背景最多 1 个(实测 \(videoCount) 个): 每个 MP4 在设备上各起一个解码进程, 多个会 OOM 死机(#35 实验 C)"
            )
        }
        let built = pages.map { $0.build() }
        let json = ThemeJSONWriter.write(
            currentPageID: built[0].pageID, layoutVersion: layoutVersion, pages: built
        )
        return ThemeFile(
            language: language,
            keyMacroValue: ThemeFileCodec.defaultKeyMacroValue,
            keyMacro: nil,
            layoutJSON: json,
            assets: assetOrder.compactMap { path in assets[path].map { ThemeAsset(path: path, data: $0) } }
        )
    }

    // MARK: - 内部: 资产注册与 ID 分配(供 PageBuilder/KeyBuilder 使用)

    fileprivate func registerAsset(suggestedFileName: String, data: Data) -> String {
        registerAssetAt(path: "/image/MK20/\(themeName)/\(suggestedFileName)", data: data)
    }

    /// 以指定设备路径注册资产(背景等有专用命名空间的类型用)。
    fileprivate func registerAssetAt(path: String, data: Data) -> String {
        if assets[path] == nil { assetOrder.append(path) }
        assets[path] = data
        return path
    }

    fileprivate func allocateItemID() -> String {
        let id = nextItemID
        nextItemID += 1
        return String(id)
    }
}

/// 单页构建器。键位自动按 4×5 网格放置(col*128, 144+row*128)。
final class PageBuilder {
    let pageID: String
    private(set) var parentPageID: String?
    private unowned let owner: ThemeBuilder
    fileprivate var items: [[String: String]] = []
    /// 键构建器(延迟 finalize, 保持后置配置生效)。
    private var keyBuilders: [KeyBuilder] = []
    private var canvas: [String: String] = [
        "canvas_w": String(ScreenLayout.canvasWidth),
        "canvas_h": String(ScreenLayout.canvasHeight),
        "canvas_flip": "0",
        "canvas_rotate": "0",
        "showUnit": "0",
    ]

    /// 页级 encoder 数组(官方当前 4 条目形态; 缺失官方软件锁死, §10 Item #10)。
    private var encoderJSON: String = #"[{"col":0,"keyString":"","keycode":0,"row":103},{"col":0,"keyString":"","keycode":0,"row":104},{"col":0,"keyString":"E","keycode":8,"row":100},{"col":0,"keyString":"","keycode":38992,"row":105}]"#

    init(owner: ThemeBuilder, pageID: String) {
        self.owner = owner
        self.pageID = pageID
    }

    /// 把本页标记为 parentPageID 的子页(文件夹导航, oneLevelUp 的解析目标)。
    func asFolderOf(_ parentPageID: String) {
        self.parentPageID = parentPageID
    }

    /// 主屏(20 键区)背景: 全屏图片/GIF/MP4。资产路径**必须**在
    /// /theme/MK20-PLUS/MainScreen/ 命名空间(键图标的 /image/MK20/ 命名空间设备找不到背景,
    /// MK20Control 多真机主题确认)。默认 640×512 盖键格区, y=144(状态条下方)。
    /// configure 可改尺寸/位置(如 #35 小窗视频实验: setSize(128,128) + setPosition 对准单键)。
    ///
    /// ⚠ MP4 全主题限 1 个(#35 实验 C 教训): 每个 type-100 视频项 = 设备上一个
    /// videoplayerinte 解码进程(40-64MB VM), 多个直接把 128MB RAM 打穿 → OOM 死循环。
    /// build() 时强制拒绝。
    @discardableResult
    func setMainScreenBackground(
        suggestedFileName: String, media data: Data,
        configure: ((WidgetItem) -> Void)? = nil
    ) -> WidgetItem {
        let path = owner.registerAssetAt(
            path: "/theme/MK20-PLUS/MainScreen/\(suggestedFileName)", data: data
        )
        // ⚠ 外部 configure 必须并入 addWidget 的闭包 — addWidget 在返回前就 finalize 固化
        // item 字典, 之后再改 builder 只改内存对象, 不影响已固化的输出。
        return addWidget(.background, x: 0, y: ScreenLayout.mainScreenTop) {
            $0.setSize(ScreenLayout.canvasWidth, ScreenLayout.canvasHeight - ScreenLayout.mainScreenTop)
                .setZ(-2)
                .setAsset(path: path, backgroundType: "main")
            configure?($0)
        }
    }

    /// 副屏(2.8", 428×142)背景: 图片/GIF, 放 (106,0)。资产路径**必须**在
    /// /image/428x142/PhotoAlbum/ 命名空间(defaultTheme 确认的约定)。GIF 须预缩放到
    /// 428×142 — 设备渲染时不缩放背景。
    ///
    /// ⚠ widget 类型必须用 .gif(114) — 真机 A/B 实验(2026-08-16): type 100 的
    /// secondary item 只在上传间隙闪现一帧不持续渲染; type 114 持续显示。
    /// 静态 PNG 一样走 114(设备按 path 扩展名处理, 不看类型区分静图/动图)。
    @discardableResult
    func setSecondaryScreenBackground(suggestedFileName: String, media data: Data) -> WidgetItem {
        let path = owner.registerAssetAt(
            path: "/image/428x142/PhotoAlbum/\(suggestedFileName)", data: data
        )
        return addWidget(.gif, x: ScreenLayout.secondaryScreenLeft, y: 0) {
            $0.setSize(ScreenLayout.secondaryScreenWidth, ScreenLayout.secondaryScreenHeight)
                .setZ(-2)
                .setAsset(path: path, backgroundType: "secondary")
        }
    }

    /// 覆盖画布尺寸/翻转(默认 640×656 不翻转)。
    func setCanvas(width: Int, height: Int, flip: Bool = false, rotate: Bool = false) {
        canvas["canvas_w"] = String(width)
        canvas["canvas_h"] = String(height)
        canvas["canvas_flip"] = flip ? "1" : "0"
        canvas["canvas_rotate"] = rotate ? "1" : "0"
    }

    /// 绑定一枚物理旋钮: 旋钮不是独立 item 类型 — 是放在固定副屏坐标的普通 type-115 键,
    /// 设备靠坐标识别; row/col 写伪行(100=左 / 103=右)。
    @discardableResult
    func addEncoder(side: EncoderSide, action: KeyAction) -> KeyBuilder {
        let builder = KeyBuilder(
            owner: owner, id: owner.allocateItemID(),
            row: side.pseudoRow, column: side.pseudoRow, title: "",
            at: side.position
        )
        builder.action = action
        keyBuilders.append(builder)
        return builder
    }

    /// 在 (row, col) 加键(0-3 / 0-4)。图标自动注册为资产。
    /// 返回的 builder 可继续配置(icon/titleStyle/animatedIcon/action), build() 时才固化。
    @discardableResult
    func addKey(
        row: Int, column: Int,
        iconFileName: String? = nil, iconPNG: Data? = nil,
        action: KeyAction? = nil,
        title: String = ""
    ) -> KeyBuilder {
        let builder = KeyBuilder(
            owner: owner, id: owner.allocateItemID(),
            row: row, column: column, title: title
        )
        if let iconFileName, let iconPNG {
            builder.iconRaw(suggestedFileName: iconFileName, png: iconPNG)
        }
        if let action { builder.action = action }
        keyBuilders.append(builder)
        return builder
    }

    struct BuiltPage {
        let pageID: String
        let parentPageID: String?
        let canvas: [String: String]
        let encoderJSON: String
        let items: [[String: String]]
    }

    /// 添加 widget item(#26): 仪表/时钟/文本/背景/GIF。配置闭包里绑定系统数据
    /// (bind(systemData:min:max:)) 与配色/字体; 骨架必带字段由 WidgetItem 兜底。
    @discardableResult
    func addWidget(_ kind: WidgetKind, x: Int, y: Int,
                   configure: (WidgetItem) -> Void = { _ in }) -> WidgetItem {
        let widget = WidgetItem(kind: kind, id: owner.allocateItemID(), x: x, y: y)
        configure(widget)
        items.append(widget.finalize())
        return widget
    }

    func build() -> BuiltPage {
        // 键延迟固化: addKey 后仍可对 KeyBuilder 配置(icon/animatedIcon/titleStyle/action),
        // 到这里才 snapshot — 否则闭包外的后置配置会静默丢失。
        let keyItems = keyBuilders.map { $0.finalize() }
        return BuiltPage(
            pageID: pageID,
            parentPageID: parentPageID,
            canvas: canvas,
            encoderJSON: encoderJSON,
            items: items + keyItems
        )
    }
}

/// 键 item 构建器(在 addPage 闭包内由 addKey 间接创建)。
final class KeyBuilder {
    /// 官方参考文件的默认 titleParam(标题字体/对齐/颜色)。
    private static let defaultTitleParam = """
        {"FontFamily":"Microsoft YaHei","FontSize":24,"FontStyle":"","FontUnderline":false,\
        "ShowImage":true,"ShowTitle":true,"TitleAlignment":"bottom","TitleColor":"#ffffff"}
        """

    private unowned let owner: ThemeBuilder
    private let id: String
    private let row: Int
    private let column: Int
    private var iconAssetPath: String?
    /// 动画键: 帧文件夹路径(paths 字段) + 每帧延迟 CSV(毫秒)。
    private var animatedFolderPath: String?
    private var frameDelays: String?
    /// titleParam 覆盖(titleStyle 设置)。
    private var titleParamOverride: String?
    var action: KeyAction?
    private var title: String
    private var opacity = 100

    init(owner: ThemeBuilder, id: String, row: Int, column: Int, title: String, at position: (x: Int, y: Int)? = nil) {
        self.owner = owner
        self.id = id
        self.row = row
        self.column = column
        self.title = title
        // 旋钮键用固定副屏坐标(默认网格推导被覆盖); 普通键 position=nil → 网格自动放置。
        self.customPosition = position
    }

    private var customPosition: (x: Int, y: Int)?

    /// 注册图标资产: 任意 PNG/GIF/JPEG 自动归一化为 128×128 RGB 无 alpha PNG(真机确认格式)。
    /// `preservingAlpha` = true 保留 alpha(设备真支持透明合成, 但官方软件不兼容 — 设备专用)。
    func icon(suggestedFileName: String, imageData: Data, preservingAlpha: Bool = false) {
        let normalized: Data
        if preservingAlpha {
            normalized = (try? IconImageNormalizer.normalizeToKeyIconPreservingAlpha(imageData)) ?? imageData
        } else {
            normalized = (try? IconImageNormalizer.normalizeToKeyIcon(imageData)) ?? imageData
        }
        iconAssetPath = owner.registerAsset(suggestedFileName: suggestedFileName, data: normalized)
    }

    /// 注册已归一化的图标字节(如复用既有资产), 原样写入。
    func iconRaw(suggestedFileName: String, png: Data) {
        iconAssetPath = owner.registerAsset(suggestedFileName: suggestedFileName, data: png)
    }

    /// 键屏标题样式(titleParam)。默认 Microsoft YaHei 24 底部白字。
    /// alignment: "bottom"/"top"/"center"; color 为 #RRGGBB。
    func titleStyle(
        fontFamily: String? = nil, fontSize: Int? = nil,
        alignment: String? = nil, color: String? = nil,
        showTitle: Bool = true, showImage: Bool = true
    ) {
        titleParamOverride = """
        {"FontFamily":"\(fontFamily ?? "Microsoft YaHei")","FontSize":\(fontSize ?? 24),\
        "FontStyle":"","FontUnderline":false,"ShowImage":\(showImage),"ShowTitle":\(showTitle),\
        "TitleAlignment":"\(alignment ?? "bottom")","TitleColor":"\(color ?? "#ffffff")"}
        """
    }

    /// 动画键: GIF 拆帧 → 每帧归一化 128×128 RGB PNG → 文件夹资产 + frameDelays CSV。
    /// 键仍可按(与静态图标完全同权); 真机机制: path 置空, paths=帧文件夹(§7.1)。
    func animatedIcon(suggestedFolderName: String, gifData: Data) throws {
        let (folder, delays) = try IconImageNormalizer.registerAnimatedIcon(
            registry: AssetRegistryAdapter(builder: owner),
            folderName: suggestedFolderName,
            gifData: gifData
        )
        animatedFolderPath = folder
        frameDelays = delays
        iconAssetPath = nil
    }

    /// 直接注册宿主生成的 PNG 动画帧。用于运行时状态动效，避免先编码 GIF
    /// 再拆帧；每帧仍统一归一化为 MK20 要求的 128×128 RGB PNG。
    func animatedIcon(
        suggestedFolderName: String,
        framePNGs: [Data],
        delaysMilliseconds: [Int]
    ) throws {
        guard !framePNGs.isEmpty, framePNGs.count == delaysMilliseconds.count else {
            throw IconImageNormalizer.NormalizerError.unreadableImage
        }
        let safeFolder = suggestedFolderName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "..", with: "-")
        let base = "/image/MK20/cache/\(safeFolder)"
        for (index, data) in framePNGs.enumerated() {
            let normalized = try IconImageNormalizer.normalizeToKeyIcon(data)
            _ = owner.registerAssetAt(path: "\(base)/frame_\(index).png", data: normalized)
        }
        animatedFolderPath = base
        frameDelays = delaysMilliseconds.map { String(max(20, $0)) }.joined(separator: ",")
        iconAssetPath = nil
    }

    func setOpacity(_ value: Int) { opacity = value }

    /// 产出 type-115 item 的完整字段集(全字段必带, 缺失官方软件锁死)。
    func finalize() -> [String: String] {
        let position = customPosition ?? ScreenLayout.keyCellOrigin(row: row, column: column)
        let itemName = "control\(id)"
        var item: [String: String] = [
            "id": id,
            "itemName": itemName,
            "type": "115",
            "x": String(position.x),
            "y": String(position.y),
            "z": "1",
            "rotate": "0",
            "scale": "1",
            "lock": "1",
            "row": String(row),
            "col": String(column),
            "path": iconAssetPath ?? "",
            "maxWidth": String(ScreenLayout.canvasWidth),
            "maxHeight": String(ScreenLayout.keyCellSize),
            "scaledWidthTo": "128",
            "scaledHeightTo": "128",
            "opacity": String(opacity),
            // 动画键: path 空 + paths=帧文件夹 + frameDelays(真机机制, 静态键 paths="")。
            "paths": animatedFolderPath ?? "",
            "soundFile": "",
            "title": title,
            "titleParam": titleParamOverride ?? Self.defaultTitleParam,
        ]
        if let frameDelays { item["frameDelays"] = frameDelays }
        if let action {
            item["controlData"] = ThemeControlData.encode(action: action).base64EncodedString()
        }
        return item
    }
}

/// controlData 编码: QVariant 标签 map(§7.2), 字段顺序匹配官方参考文件。
enum ThemeControlData {
    /// 旋钮内置函数的官方 iconPath/description(真机确认值)。
    private static func encoderFunctionMetadata(_ type: String) -> (icon: String, description: String) {
        switch type {
        case "encoder_system_volume": ("/static/icon/white/systemVolume.png", "System volume")
        case "encoder_device_brightness": ("/static/icon/white/deviceBrightness.png", "Device brightness")
        case "encoder_system_media": ("/static/icon/white/systemMedia.png", "System audio")
        case "encoder_device_volume": ("/static/icon/white/deviceVolume.png", "Device volume")
        default: ("/static/icon/white/systemVolume.png", "Encoder")
        }
    }

    static func encode(action: KeyAction) -> Data {
        var fields: [String: ThemeFileCodec.TaggedValue] = [:]
        var order: [String] = []

        func set(_ key: String, _ value: ThemeFileCodec.TaggedValue) {
            if fields[key] == nil { order.append(key) }
            fields[key] = value
        }

        switch action {
        case .keyboard(let keycode, let keyString):
            // 官方参考文件的确切字段顺序: type, parentDescription, keycode, keyString,
            // iconPath, description, AISoundControlKeyword。
            set("type", .string(action.typeName))
            let isOfficialLeftShift = keycode == 0x0200 && keyString == "L Shift "
            set("parentDescription", .string(
                isOfficialLeftShift ? "系统输入控制" : "System input control"
            ))
            set("keycode", .int32(keycode))
            if let keyString { set("keyString", .string(keyString)) }
            set("iconPath", .string("/static/icon/dark/keyboard.png"))
            set("description", .string(isOfficialLeftShift ? "键盘" : "Keyboard"))
            // Match the stock MK20 K18/Shift controlData byte-for-byte. The
            // stock modifier entry has six fields and omits this newer field.
            if !isOfficialLeftShift {
                set("AISoundControlKeyword", .string(""))
            }
        case .pageSwitch(let mode, let pageIndex):
            set("type", .string("pageSwitch"))
            set("parentDescription", .string("Page switching"))
            set("pageSwitchMode", .int32(mode))
            set("jumpToPage", .int32(pageIndex ?? 0))
            set("iconPath", .string("/static/icon/dark/PageSwitch.png"))
            set("description", .string("Page switching"))
            set("AISoundControlKeyword", .string(""))
        case .openPage(let pageName):
            set("type", .string("openPage"))
            set("parentDescription", .string("Page switching"))
            set("pageName", .string(pageName))
            set("iconPath", .string("/static/icon/dark/createFolder.png"))
            set("description", .string("Create folders"))
            set("AISoundControlKeyword", .string(""))
        case .oneLevelUp:
            set("type", .string("oneLevelUp"))
            set("parentDescription", .string("Page switching"))
            set("pageName", .string("parentPage"))
            set("iconPath", .string("/static/icon/dark/oneLevelUp.png"))
            set("description", .string("Return to the previous level"))
            set("AISoundControlKeyword", .string(""))
        case .encoderKeyboard(let left, let leftLabel, let middle, let middleLabel, let right, let rightLabel):
            // 官方字段顺序(参考 KeyActions.EncoderKeyboard 原始字典序)。
            set("type", .string("encoder_keyboard"))
            set("parentDescription", .string("Encoder"))
            set("iconPath", .string("/static/icon/white/keyboard.png"))
            set("encoder_right_keycode", .int32(right))
            set("encoder_right_keyString", .string(rightLabel))
            set("encoder_middle_keycode", .int32(middle))
            set("encoder_middle_keyString", .string(middleLabel))
            set("encoder_left_keycode", .int32(left))
            set("encoder_left_keyString", .string(leftLabel))
            set("description", .string("Keyboard"))
            set("category", .string("encoder"))
        case .encoderFunction(let type):
            let (icon, description) = Self.encoderFunctionMetadata(type)
            set("type", .string(type))
            set("parentDescription", .string("Encoder"))
            set("iconPath", .string(icon))
            set("description", .string(description))
            set("category", .string("encoder"))
        case .typeText(let text, let pressEnter):
            set("type", .string("text"))
            set("parentDescription", .string("System input control"))
            set("isInputEnter", .bool(pressEnter))
            set("isCopyPaste", .bool(false))
            set("inputText", .string(text))
            set("iconPath", .string("/static/icon/dark/text.png"))
            set("description", .string("Text input"))
            set("AISoundControlKeyword", .string(""))
        case .raw(let type, let rawFields):
            // 透传: 原字段原样保留, 只覆盖 type。
            for (key, value) in rawFields.sorted(by: { $0.key < $1.key }) {
                set(key, value)
            }
            set("type", .string(type))
        }
        return TaggedMapWriter.encode(ordered: order, fields: fields)
    }
}

/// 保持插入顺序的 QVariant map 编码(官方参考文件的字段顺序有意义)。
enum TaggedMapWriter {
    static func encode(ordered: [String], fields: [String: ThemeFileCodec.TaggedValue]) -> Data {
        var out = Data()
        out.appendBigEndian(UInt32(fields.count))
        for key in ordered {
            writeQString(key, into: &out)
            writeTagged(fields[key] ?? .string(nil), into: &out)
        }
        return out
    }

    private static let typeBool: UInt32 = 1
    private static let typeInt32: UInt32 = 2
    private static let typeString: UInt32 = 10
    private static let typeByteArray: UInt32 = 12

    private static func writeTagged(_ value: ThemeFileCodec.TaggedValue, into out: inout Data) {
        switch value {
        case .bool(let raw):
            out.appendBigEndian(typeBool); out.append(0); out.append(raw ? 1 : 0)
        case .int32(let raw):
            out.appendBigEndian(typeInt32); out.append(0); out.appendBigEndian(UInt32(bitPattern: raw))
        case .string(let raw):
            // null 由载荷长度哨兵 0xFFFFFFFF 表示(外层 isNull=0, 真机样本确认)。
            out.appendBigEndian(typeString); out.append(0)
            writeNullableQString(raw, into: &out)
        case .byteArray(let raw):
            out.appendBigEndian(typeByteArray); out.append(0)
            if let raw {
                out.appendBigEndian(UInt32(raw.count)); out.append(raw)
            } else {
                out.appendBigEndian(0xFFFF_FFFF)
            }
        case .map, .list, .double:
            // ThemeControlData 不产生这些类型; ThemeFileCodec.encode 才处理完整集合。
            out.appendBigEndian(typeString); out.append(0); writeNullableQString(nil, into: &out)
        }
    }

    private static func writeNullableQString(_ value: String?, into out: inout Data) {
        guard let value else {
            out.appendBigEndian(0xFFFF_FFFF)
            return
        }
        writeQString(value, into: &out)
    }

    private static func writeQString(_ value: String, into out: inout Data) {
        let units = Array(value.utf16)
        out.appendBigEndian(UInt32(units.count * 2))
        for unit in units {
            out.append(UInt8(unit >> 8))
            out.append(UInt8(unit & 0xFF))
        }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

/// KeyBuilder.animatedIcon → ThemeBuilder.registerAssetAt 的桥(fileprivate 可见性适配)。
struct AssetRegistryAdapter: IconImageNormalizer.AnimatedIconRegistry {
    let builder: ThemeBuilder

    func registerAsset(atPath path: String, data: Data) -> String {
        builder.registerAssetAt(path: path, data: data)
    }
}
