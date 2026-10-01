import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import QbarCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, layout, behavior, appearance, shortcuts, permissions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: L10n.tr("概览")
        case .layout: L10n.tr("布局与图标")
        case .behavior: L10n.tr("显示与行为")
        case .appearance: L10n.tr("外观与间距")
        case .shortcuts: L10n.tr("快捷键")
        case .permissions: L10n.tr("授权与关于")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .layout: "rectangle.3.group"
        case .behavior: "cursorarrow.motionlines"
        case .appearance: "paintpalette"
        case .shortcuts: "command"
        case .permissions: "lock.shield"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: L10n.tr("少一点拥挤，多一点专注。")
        case .layout: L10n.tr("每个图标，都有恰好的位置。")
        case .behavior: L10n.tr("需要时出现，其余时间保持安静。")
        case .appearance: L10n.tr("让每一个细节，都合你心意。")
        case .shortcuts: L10n.tr("让常用操作，快于鼠标。")
        case .permissions: L10n.tr("权限清晰，数据留在你的 Mac。")
        }
    }
}

enum Palette {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.65, alpha: 1)
            : NSColor(calibratedRed: 0.12, green: 0.51, blue: 0.42, alpha: 1)
    })
    static let line = Color.primary.opacity(0.07)
    static let card = Color(nsColor: .controlBackgroundColor)
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var resetAlert = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.selectedPage.title).font(.system(size: 23, weight: .semibold))
                        Text(model.selectedPage.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.selectedPage == .layout || model.selectedPage == .overview {
                        Button { model.refresh() } label: {
                            Label(L10n.tr(model.isRefreshing ? "正在刷新" : "刷新图标"), systemImage: "arrow.clockwise")
                        }.disabled(model.isRefreshing).controlSize(.large)
                    }
                }.padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 22)
                if let notice = model.notice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(Palette.accent)
                        Text(notice).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 30).padding(.bottom, 14)
                }
                ScrollView {
                    Group {
                        switch model.selectedPage {
                        case .overview: OverviewView(model: model)
                        case .layout: LayoutView(model: model)
                        case .behavior: BehaviorView(model: model)
                        case .appearance: AppearanceView(model: model)
                        case .shortcuts: ShortcutsView(model: model)
                        case .permissions: PermissionsView(model: model)
                        }
                    }.padding(.horizontal, 30).padding(.bottom, 30).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Palette.accent)
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil && !model.isMoving }, set: { if !$0 && !model.isMoving { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark().frame(width: 35, height: 35)
                Text("Qbar").font(.system(size: 25, weight: .bold, design: .rounded)).tracking(-0.7)
            }.padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 34)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                .padding(.horizontal, 25).padding(.bottom, 12)
            ForEach(SettingsPage.allCases) { page in
                Button { model.selectedPage = page } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol).font(.system(size: 15)).frame(width: 20)
                        Text(page.title).font(.system(size: 13, weight: model.selectedPage == page ? .semibold : .regular))
                        Spacer()
                        if page == .permissions && !model.accessibilityGranted { Circle().fill(.orange).frame(width: 6, height: 6) }
                    }.foregroundStyle(model.selectedPage == page ? Palette.accent : Color.primary.opacity(0.72))
                        .padding(.horizontal, 13).frame(height: 42)
                        .background(model.selectedPage == page ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle().fill(model.managementEnabled ? Palette.accent : Color.orange).frame(width: 6, height: 6)
                    Text(L10n.tr(model.managementEnabled ? "Qbar 正在管理菜单栏" : "准备好，从容开始"))
                        .font(.system(size: 11, weight: .medium))
                }
                Text("为留白，留一点空间。").font(.system(size: 10)).foregroundStyle(.tertiary)
                HStack {
                    Text("Qbar 1.0").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    Spacer()
                    Menu {
                        Button("导出配置…") { model.exportConfiguration() }
                        Button("导入配置…") { model.importConfiguration() }
                        Divider()
                        Button("退出 Qbar") { NSApp.terminate(nil) }
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).frame(width: 22)
                }.padding(.top, 8)
            }.padding(20)
        }.frame(width: 206).background(.ultraThinMaterial)
    }
}

struct BrandMark: View {
    var body: some View {
        Image(nsImage: QbarBrand.appImage).resizable().scaledToFit().accessibilityLabel("Qbar")
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title { Text(L10n.tr(title)).font(.system(size: 13, weight: .semibold)) }
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr(title)).font(.system(size: 13, weight: .medium))
                if let detail { Text(L10n.tr(detail)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            content
        }.frame(minHeight: 34)
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A LITTLE SPACE. A LOT OF CALM.").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.6).foregroundStyle(Palette.accent)
                        Text("把菜单栏，\n留给重要的事。").font(.system(size: 33, weight: .semibold)).tracking(-0.6).lineSpacing(5)
                        Text("常用的留在眼前，其余的妥善收好。\n一键唤出，随用随走。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                    }
                    Spacer()
                    Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 66, weight: .ultraLight))
                        .foregroundStyle(Palette.accent.opacity(0.26)).rotationEffect(.degrees(-8)).padding(.top, 18).padding(.trailing, 16)
                }
                MenuBarIllustration()
                HStack {
                    Button {
                        model.onToggle?()
                    } label: {
                        Label(L10n.tr(model.managementEnabled ? "打开我的收纳区" : model.layoutPending ? "应用并打开收纳区" : "启用并打开收纳区"),
                              systemImage: model.managementEnabled ? "rectangle.bottomthird.inset.filled" : "power")
                            .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("整理图标 →") { model.selectedPage = .layout }.buttonStyle(.plain).font(.system(size: 12)).padding(.leading, 10)
                    Spacer()
                    Text("布局示意").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }.padding(25).background(LinearGradient(colors: [Palette.accent.opacity(0.09), Palette.card], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent.opacity(0.1)))
            HStack(spacing: 12) {
                metric("始终显示", value: model.visibleCount, symbol: "sun.max", color: Palette.accent)
                metric("已收纳", value: model.hiddenCount, symbol: "tray", color: .blue)
                metric("始终隐藏", value: model.alwaysCount, symbol: "eye.slash", color: .purple)
            }
            Card(title: "快速设置") {
                SettingsRow(title: "显示方式", detail: "刘海屏推荐使用聚合浮窗") {
                    Picker("显示方式", selection: $model.preferences.mode) {
                        ForEach(DisplayMode.allCases) { Text(L10n.tr($0.title)).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
                Divider()
                SettingsRow(title: "登录时启动", detail: "打开 Mac，Qbar 就已准备好") {
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            if !model.accessibilityGranted {
                Button { model.selectedPage = .permissions } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.open").foregroundStyle(Palette.accent)
                        Text("还差一步：授予控制权限，开始整理菜单栏。")
                        Spacer(); Image(systemName: "arrow.right")
                    }.font(.system(size: 12)).padding(15).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
        }
    }

    private func metric(_ title: String, value: Int, symbol: String, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr(title)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(value)").font(.system(size: 27, weight: .medium, design: .rounded))
            }
            Spacer()
            Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(color)
                .frame(width: 37, height: 37).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        }.padding(17).frame(maxWidth: .infinity).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
    }
}

struct MenuBarIllustration: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(spacing: 13) {
                Image(systemName: "apple.logo")
                Text("Finder").fontWeight(.semibold)
                Text("文件").opacity(0.5)
                Text("编辑").opacity(0.5)
                Spacer(minLength: 10)
                Image(systemName: "rectangle.split.2x1").foregroundStyle(Palette.accent)
                Rectangle().fill(Palette.line).frame(width: 1, height: 12)
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
                Text("09:41").monospacedDigit()
            }.font(.system(size: 11)).padding(.horizontal, 16).frame(height: 35)
                .background(Palette.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.5)))
            HStack(spacing: 20) {
                ForEach(["cloud", "headphones", "bolt.circle", "calendar", "clipboard"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 16, weight: .regular)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 18).frame(height: 42)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.line))
                .shadow(color: .black.opacity(0.04), radius: 10, y: 4).padding(.trailing, 100)
        }.accessibilityElement(children: .ignore).accessibilityLabel(L10n.tr("布局示意：常用图标保留在菜单栏，其他图标显示在下方浮窗"))
    }
}

struct LayoutView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    private let dragType = UTType(exportedAs: "studio.qbar.menu-item")
    @State private var renameTarget: RenameTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索图标或应用名称", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }.padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            HStack {
                Text("拖动到分组中，或通过右侧菜单调整。按住 ⌘ 也可直接整理系统菜单栏。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("应用布局") { model.requestApplyLayout() }
                    .disabled(!model.canApplyLayout)
                    .help(L10n.tr(model.managementEnabled ? "将当前分组应用到菜单栏" : "自动开启菜单栏管理，并应用当前分组"))
                if model.layoutPending {
                    Button("取消待应用布局") { model.discardPendingLayout() }.disabled(model.isMoving)
                }
            }
            if model.layoutPending && !model.managementEnabled {
                Text("分组尚未应用。点击“应用布局”会自动开启菜单栏管理。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if model.isMoving { ProgressView("正在移动菜单栏图标…").controlSize(.small) }
            ForEach(ItemSection.allCases) { section in
                Card {
                    HStack {
                        Image(systemName: section == .visible ? "sun.max" : section == .hidden ? "tray" : "eye.slash").foregroundStyle(Palette.accent)
                        Text(L10n.tr(section.title)).font(.system(size: 13, weight: .semibold))
                        Text("\(model.sortedItems(in: section).count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Text(L10n.tr(section == .visible ? "留在菜单栏" : section == .hidden ? "点击 Qbar 时出现" : "仅主动查看时出现"))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    let items = filtered(section)
                    if items.isEmpty {
                        HStack {
                            Spacer()
                            Text(L10n.tr(query.isEmpty ? "将图标拖到这里" : "没有匹配的图标")).font(.system(size: 12)).foregroundStyle(.tertiary)
                            Spacer()
                        }.frame(height: 48).background(Palette.accent.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                HStack(spacing: 11) {
                                    Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary)
                                    ItemIcon(item: item)
                                        .frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(L10n.tr(item.isSystem ? "系统菜单栏项目" : "应用菜单栏项目"))
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let shortcut = model.preferences.rules.first(where: { $0.id == item.id })?.shortcut {
                                        Text(shortcut.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    Menu {
                                        Button("打开图标菜单") { model.onActivateItem?(item.id, false) }.disabled(!model.managementEnabled)
                                        Button("设置显示名称…") { renameTarget = RenameTarget(id: item.id, name: item.name) }
                                        Divider()
                                        ForEach(ItemSection.allCases) { destination in
                                            Button(L10n.tr(destination.title)) { model.move(item.id, to: destination) }.disabled(!item.isMovable)
                                        }
                                        Divider()
                                        Button("移到本组最前") { model.move(item.id, to: section, before: model.sortedItems(in: section).first?.id) }.disabled(!item.isMovable)
                                        Button("移到本组最后") { model.move(item.id, to: section) }.disabled(!item.isMovable)
                                    } label: { Image(systemName: "ellipsis").frame(width: 24) }.menuStyle(.borderlessButton).frame(width: 30)
                                }.padding(.vertical, 10).contentShape(Rectangle())
                                    .onDrag {
                                        guard item.isMovable else { return NSItemProvider() }
                                        return NSItemProvider(item: Data(item.id.utf8) as NSData, typeIdentifier: dragType.identifier)
                                    }
                                    .onDrop(of: [dragType], isTargeted: nil) { providers in accept(providers, section: section, before: item.id) }
                                if item.id != items.last?.id { Divider().opacity(0.5) }
                            }
                        }
                    }
                }.onDrop(of: [dragType], isTargeted: nil) { accept($0, section: section, before: nil) }
            }
            let missingApplications = runningApplicationsWithoutMenuItems
            if !missingApplications.isEmpty {
                Card(title: "运行中，菜单栏未显示") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(missingApplications) { application in
                            HStack(spacing: 9) {
                                if let icon = application.icon {
                                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 24, height: 24)
                                } else {
                                    Image(systemName: "app").foregroundStyle(.secondary).frame(width: 24, height: 24)
                                }
                                Text(application.name).font(.system(size: 12, weight: .medium))
                            }
                        }
                        Text("暂未检测到这些应用的原生菜单栏图标。Qbar 会保留已保存的分组，并在图标出现后恢复位置；如需显示，请检查对应应用的菜单栏选项。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if model.items.isEmpty {
                Text(L10n.tr(model.accessibilityGranted ? "暂未识别到菜单栏图标。请确保其他应用正在运行，再点击刷新。" : "请先完成授权，识别更多菜单栏图标。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button("导出布局与设置…") { model.exportConfiguration() }
                Button("导入…") { model.importConfiguration() }
                Spacer()
                let absent = model.preferences.rules.filter { rule in !model.items.contains(where: { $0.id == rule.id }) }.count
                if absent > 0 {
                    Text(String(format: L10n.tr("保留 %d 个暂未显示图标的设置"), absent))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }.sheet(item: $renameTarget) { target in
            RenameItemSheet(name: target.name) { model.rename(target.id, to: $0) }
        }
    }

    private func filtered(_ section: ItemSection) -> [MenuItem] {
        model.sortedItems(in: section).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
    }
    private var runningApplicationsWithoutMenuItems: [MissingMenuApplication] {
        let savedBundles = Set(model.preferences.rules.map(\.bundleID).filter {
            !$0.isEmpty && !$0.lowercased().hasPrefix("com.apple.")
        })
        let activeBundles = Set(model.items.map(\.bundleID))
        var applications: [String: MissingMenuApplication] = [:]
        for running in NSWorkspace.shared.runningApplications {
            guard let bundle = running.bundleIdentifier,
                  running.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  savedBundles.contains(bundle), !activeBundles.contains(bundle),
                  applications[bundle] == nil else { continue }
            applications[bundle] = MissingMenuApplication(
                id: bundle,
                name: MenuItem.applicationName(pid: running.processIdentifier, bundleID: bundle) ?? running.localizedName ?? bundle,
                icon: running.icon ?? MenuItem.applicationIcon(pid: running.processIdentifier, bundleID: bundle)
            )
        }
        return applications.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func accept(_ providers: [NSItemProvider], section: ItemSection, before: String?) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(dragType.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: dragType.identifier) { data, _ in
            guard let data, data.count <= 4096, let id = String(data: data, encoding: .utf8), id != before else { return }
            Task { @MainActor in model.move(id, to: section, before: before) }
        }
        return true
    }
}

private struct MissingMenuApplication: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
}

private struct RenameTarget: Identifiable {
    let id: String
    let name: String
}

private struct RenameItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var nameFocused: Bool
    let save: (String) -> Void

    init(name: String, save: @escaping (String) -> Void) {
        _name = State(initialValue: name)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("显示名称").font(.headline)
            Text("可用自定义名称查找图标。留空恢复自动名称。")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(name); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 380)
        .onAppear { nameFocused = true }
    }
}

struct ItemIcon: View {
    let item: MenuItem
    var prefersMenuImage = false
    var body: some View {
        if prefersMenuImage, let image = item.menuImage {
            Image(nsImage: image)
                .resizable().scaledToFit()
                .padding(2)
                .background {
                    if let dark = item.captureNeedsDarkBackground {
                        RoundedRectangle(cornerRadius: 4).fill(dark ? Color(white: 0.22) : Color(white: 0.94))
                    }
                }
        }
        else if let symbol = item.systemSymbol {
            Image(systemName: symbol).resizable().scaledToFit().padding(3).foregroundStyle(.secondary)
        } else if let image = item.image {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "app").resizable().scaledToFit().padding(4).foregroundStyle(.secondary)
        }
    }
}

struct BehaviorView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Card(title: "两种显示方式") {
                HStack(spacing: 12) {
                    modeCard(.aggregate, icon: "rectangle.bottomthird.inset.filled", detail: "独立浮窗收纳图标，适合刘海屏。")
                    modeCard(.inline, icon: "menubar.rectangle", detail: "直接在菜单栏展开，再次点击收起。")
                }
                SettingsRow(title: "聚合浮窗位置") {
                    Picker("浮窗位置", selection: $model.preferences.panelAnchor) {
                        ForEach(PanelAnchor.allCases) { Text(L10n.tr($0.title)).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
            }
            Card(title: "展开图标") {
                settingToggle("悬停时展开", detail: BuildChannel.isAppStore ? "鼠标停留在 Qbar 图标上时显示" : "鼠标停留在 Qbar 图标或菜单栏空白处时显示", value: $model.preferences.hoverToShow)
                if model.preferences.hoverToShow {
                    SettingsRow(title: "悬停等待", detail: "减少鼠标经过时的误触") {
                        Slider(value: $model.preferences.hoverDelay, in: 0.1...3, step: 0.1).frame(width: 140)
                        Text(String(format: L10n.tr("%.1f 秒"), model.preferences.hoverDelay)).monospacedDigit().frame(width: 48)
                    }
                }
                Divider()
                settingToggle("点击菜单栏空白处展开", detail: "关闭后，只通过 Qbar 图标或快捷键展开", value: $model.preferences.clickEmptyToShow)
                    .disabled(BuildChannel.isAppStore)
                Divider()
                settingToggle("滚动菜单栏展开 / 收起", detail: "向上滚动展开，向下滚动收起", value: $model.preferences.scrollToShow)
            }
            Card(title: "自动收起") {
                settingToggle("离开后自动收起", detail: "鼠标离开菜单栏和浮窗后开始计时", value: $model.preferences.autoHide)
                if model.preferences.autoHide {
                    SettingsRow(title: "等待时间") {
                        Stepper(value: $model.preferences.hideDelay, in: 0.5...60, step: 0.5) {
                            Text(String(format: L10n.tr("%.1f 秒"), model.preferences.hideDelay)).monospacedDigit()
                        }.frame(width: 110)
                    }
                }
                Divider()
                settingToggle("临时显示的图标自动收回", detail: "每个图标单独计时；操作该图标或打开菜单会延后收回", value: $model.preferences.rehideTemporary)
                if model.preferences.rehideTemporary {
                    SettingsRow(title: "无操作等待时间") {
                        Stepper(value: $model.preferences.temporaryDelay, in: 1...120, step: 1) {
                            Text(String(format: L10n.tr("%d 秒"), Int(model.preferences.temporaryDelay))).monospacedDigit()
                        }.frame(width: 110)
                    }
                }
            }
        }
    }
    private func settingToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        SettingsRow(title: title, detail: detail) { Toggle(L10n.tr(title), isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small) }
    }
    private func modeCard(_ mode: DisplayMode, icon: String, detail: String) -> some View {
        Button { model.preferences.mode = mode } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon).font(.system(size: 25, weight: .light))
                    Spacer()
                    Image(systemName: model.preferences.mode == mode ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                }.foregroundStyle(model.preferences.mode == mode ? Palette.accent : .secondary)
                Text(L10n.tr(mode.title)).font(.system(size: 13, weight: .semibold))
                Text(L10n.tr(detail)).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(model.preferences.mode == mode ? Palette.accent.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.preferences.mode == mode ? Palette.accent.opacity(0.5) : Palette.line))
        }.buttonStyle(.plain)
    }
}

struct AppearanceView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Card(title: "菜单栏上的 Qbar") {
                HStack(spacing: 9) {
                    ForEach(BarGlyph.allCases) { glyph in
                        Button { model.preferences.glyph = glyph } label: {
                            VStack(spacing: 10) {
                                Group {
                                    if glyph == .capsule {
                                        Image(nsImage: QbarBrand.menuImage).resizable().scaledToFit().frame(width: 20, height: 20)
                                    } else {
                                        Image(systemName: glyph.symbol).font(.system(size: 18))
                                    }
                                }.frame(height: 26)
                                Text(L10n.tr(glyph.title)).font(.system(size: 10))
                            }.foregroundStyle(model.preferences.glyph == glyph ? Palette.accent : .secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(model.preferences.glyph == glyph ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.preferences.glyph == glyph ? Palette.accent.opacity(0.5) : Palette.line))
                                .contentShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).help(L10n.tr(glyph.title))
                            .accessibilityValue(L10n.tr(model.preferences.glyph == glyph ? "已选中" : "未选中"))
                    }
                }
                Text("点击后立即更换屏幕顶部菜单栏中的 Qbar 图标，无需启用收纳。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                SettingsRow(title: "显示分隔标记", detail: "整理布局时，用标记区分三个区域") {
                    Toggle("显示分隔标记", isOn: $model.preferences.showDividers).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            Card(title: "浮窗外观") {
                SettingsRow(title: "配色") {
                    Picker("配色", selection: $model.preferences.theme) { ForEach(AppTheme.allCases) { Text(L10n.tr($0.title)).tag($0) } }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                }
                Divider()
                SettingsRow(title: "收纳图标最大高度", detail: "菜单栏截图保持原始大小，超过此值时才缩小。") {
                    Slider(value: $model.preferences.panelIconSize, in: 16...40, step: 2).frame(width: 180)
                    Text("\(Int(model.preferences.panelIconSize)) pt").font(.system(size: 11, design: .monospaced)).frame(width: 43)
                }
            }
            Card(title: "系统菜单栏间距") {
                HStack {
                    Picker("图标间距", selection: $model.preferences.spacing) { ForEach(SpacingPreset.allCases) { Text(L10n.tr($0.title)).tag($0) } }.frame(width: 270)
                    Spacer()
                    Button("应用间距") {
                        do {
                            try SpacingManager.apply(model.preferences.spacing)
                            model.notice = L10n.tr("间距已保存。重新打开相关应用，或退出登录后生效。")
                        } catch { model.error = error.localizedDescription }
                    }.disabled(BuildChannel.isAppStore)
                }
                Text(L10n.tr(BuildChannel.isAppStore ? "Mac App Store 沙盒限制修改系统全局间距；浮窗图标大小可正常调整。" : "更改会作用于系统菜单栏。选择“系统默认”可恢复首次修改前的值；不会自动重启应用。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ShortcutsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Card(title: "全局快捷键") {
                Text("默认不占用快捷键。Control＋Option＋空格保留给输入法，可按需录制其他组合。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                shortcutRow("展开 / 收起", detail: "在任意应用中唤出你的菜单栏图标", key: "toggle")
                Divider()
                shortcutRow("查看始终隐藏", detail: "主动打开始终隐藏区", key: "always")
                Divider()
                shortcutRow("收起所有图标", detail: "立即恢复清爽的菜单栏", key: "collapse")
                Divider()
                shortcutRow("打开 Qbar 设置", detail: nil, key: "settings")
            }
            Card(title: "直接打开某个图标") {
                Text("给常用应用设置独立快捷键。触发后临时显示图标并打开它的菜单。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.items.isEmpty { Text("完成授权并刷新图标后，可在这里添加。").font(.system(size: 12)).foregroundStyle(.tertiary) }
                ForEach(model.items) { item in
                    HStack(spacing: 10) {
                        ItemIcon(item: item).frame(width: 22, height: 22)
                        Text(item.name).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        ShortcutRecorder(shortcut: Binding(get: {
                            model.preferences.rules.first { $0.id == item.id }?.shortcut
                        }, set: { value in
                            if let index = model.preferences.rules.firstIndex(where: { $0.id == item.id }) { model.preferences.rules[index].shortcut = value }
                        })).frame(width: 145, height: 28)
                    }
                    if let error = model.shortcutErrors["item:" + item.id] { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
                }
            }
            Text("点击按钮后按下组合键。需包含 ⌘、⌥ 或 ⌃；Delete 清除，Esc 取消。")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func shortcutRow(_ title: String, detail: String?, key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow(title: title, detail: detail) {
                ShortcutRecorder(shortcut: Binding(get: { model.preferences.shortcuts[key] }, set: { model.preferences.shortcuts[key] = $0 }))
                    .frame(width: 145, height: 28)
            }
            if let error = model.shortcutErrors[key] { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmReset = false
    var body: some View {
        VStack(spacing: 18) {
            Card(title: "让 Qbar 开始工作") {
                permissionRow("辅助功能 / 控制权限", detail: "用于移动和点击菜单栏图标。", granted: model.accessibilityGranted, action: model.requestAccessibility)
                Divider()
                permissionRow("屏幕与系统音频录制", detail: "仅获取菜单栏图标快照，不采集音频。未授权时使用应用图标代替。", granted: model.screenRecordingGranted, action: model.requestScreenRecording)
                Divider()
                HStack {
                    Button("重新检查") { model.checkPermissions(); model.refresh() }
                    Spacer()
                    Text("权限由 macOS 管理，随时可以撤销。").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if !model.conflicts.isEmpty {
                    Label(String(format: L10n.tr("检测到 %@ 正在运行。请先退出它，再启用 Qbar。"),
                                 model.conflicts.joined(separator: L10n.tr("、"))), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Card(title: "运行状态") {
                SettingsRow(title: "管理菜单栏", detail: "关闭后，所有折叠图标会重新回到菜单栏") {
                    Toggle("管理菜单栏", isOn: Binding(get: { model.managementEnabled }, set: model.setManagement)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider()
                SettingsRow(title: "登录时启动") {
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            Card {
                HStack(spacing: 15) {
                    BrandMark().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Qbar").font(.system(size: 23, weight: .bold, design: .rounded))
                        Text("版本 1.0.0 · macOS 14.4+").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("MADE FOR A CALMER MAC").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.tertiary)
                }
                Divider()
                Label("本地运行 · 无账号 · 无广告 · 不上传数据", systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(Palette.accent)
                Text("Qbar 只读取菜单栏相关的信息。菜单栏图标快照可能缓存在你的 Mac 本地，布局与偏好也保存在你的 Mac。应用不包含分析 SDK 或后台联网服务，不上传数据。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                HStack {
                    Button("导出设置…") { model.exportConfiguration() }
                    Button("导入设置…") { model.importConfiguration() }
                    Spacer()
                    Button("重置设置…", role: .destructive) { confirmReset = true }
                }
            }
        }.alert("重置 Qbar 设置？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { model.resetPreferences() }
        } message: { Text("将停止管理菜单栏，并清除布局、快捷键与外观偏好。系统间距和开机启动保持当前设置，可单独恢复。") }
    }
    private func permissionRow(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield").font(.system(size: 22)).foregroundStyle(granted ? Palette.accent : Color.secondary)
                .frame(width: 42, height: 42).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr(title)).font(.system(size: 13, weight: .medium))
                Text(L10n.tr(detail)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted { Label("已授权", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            else { Button("前往授权", action: action).controlSize(.large) }
        }
    }
}

struct TrayView: View {
    @ObservedObject var model: AppModel
    let always: Bool
    let iconSnapshots: [String: TrayIconSnapshot]
    let onClose: () -> Void
    private var items: [MenuItem] {
        model.trayItems(in: always ? .alwaysHidden : .hidden)
    }
    private var iconHeight: CGFloat { max(18, min(30, model.preferences.panelIconSize)) }
    private var usesDarkGlass: Bool { TrayPanelAppearance.usesDarkGlass(model: model) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if items.isEmpty {
                Text("收纳区为空").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                HStack(spacing: TrayMetrics.iconSpacing) {
                    ForEach(items) { item in
                        let snapshot = iconSnapshots[item.id] ?? TrayReplicaImage.snapshot(for: item, height: iconHeight)
                        let size = snapshot.displaySize
                        TrayIconButton(item: item, iconImage: snapshot.image, displaySize: size,
                                       isEnabled: model.managementEnabled, usesDarkGlass: usesDarkGlass) { anchor, rightClick in
                            if rightClick { model.trace("TRAY RIGHT id=\(item.id) relativeX=\(anchor.normalizedX.map { String(describing: $0) } ?? "nil")") }
                            if let action = model.onActivateItemFromTray { action(item.id, rightClick, anchor) }
                            else if let action = model.onActivateItemAtPoint { action(item.id, rightClick, anchor.normalizedX) }
                            else { model.onActivateItem?(item.id, rightClick) }
                        }
                        .frame(width: size.width, height: iconHeight)
                        .contentShape(Rectangle())
                    }
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.19, green: 0.49, blue: 0.73).opacity(0.91),
                            Color(red: 0.09, green: 0.36, blue: 0.64).opacity(0.94)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
            }
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.12)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
            .environment(\.colorScheme, usesDarkGlass ? .dark : .light)
            .tint(Palette.accent)
            .onExitCommand(perform: onClose)
    }
}

@MainActor
private enum TrayPanelAppearance {
    static func usesDarkGlass(model: AppModel) -> Bool {
        // Native status-item snapshots often contain white pixels even when
        // the desktop runs in light mode. Keep their controls in dark mode so
        // those original pixels stay legible after an asynchronous refresh.
        true
    }

}

/// Draw the tray directly into a transparent panel. System glass and popover
/// materials add a bright blur over colorful wallpapers even at low alpha.
@MainActor
final class TrayPanelContentView: NSView {
    private let hosting: TransparentTrayHostingView
    private var observation: AnyCancellable?
    var onMetricsChanged: (() -> Void)?
    override var isOpaque: Bool { false }

    init(model: AppModel, always: Bool, iconSnapshots: [String: TrayIconSnapshot], onClose: @escaping () -> Void) {
        hosting = TransparentTrayHostingView(rootView: TrayView(model: model, always: always,
                                                               iconSnapshots: iconSnapshots, onClose: onClose))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        observation = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange arrives before the new capture/preferences have
            // been assigned. Re-measure after that assignment.
            DispatchQueue.main.async { [weak self] in
                self?.onMetricsChanged?()
            }
        }
    }

    required init?(coder: NSCoder) { return nil }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }
}

@MainActor
private final class TransparentTrayHostingView: NSHostingView<TrayView> {
    override var isOpaque: Bool { false }
}

enum TrayMetrics {
    // Match the breathing room between native menu-bar glyphs at the default
    // 24-point icon size while keeping each app's original artwork untouched.
    static let iconSpacing: CGFloat = 14
}

struct TrayIconSnapshot {
    let image: NSImage?
    let displaySize: CGSize
}

enum TrayReplicaImage {
    static func image(for item: MenuItem) -> NSImage? {
        if let menuImage = item.menuImage { return trimmingTransparentEdges(menuImage) }
        return item.systemSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: item.name) }
            ?? item.image
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: item.name)
    }

    static func displaySize(for item: MenuItem, height: CGFloat) -> CGSize {
        displaySize(for: item, image: image(for: item), height: height)
    }

    static func snapshot(for item: MenuItem, height: CGFloat) -> TrayIconSnapshot {
        let source = image(for: item)
        return TrayIconSnapshot(image: source?.copy() as? NSImage,
                                displaySize: displaySize(for: item, image: source, height: height))
    }

    private static func displaySize(for item: MenuItem, image: NSImage?, height: CGFloat) -> CGSize {
        guard let image, image.size.height > 0 else { return CGSize(width: height, height: height) }
        // A menu-bar screenshot already has the glyph's native size in points
        // after its transparent host padding is removed. Keep that size instead
        // of stretching every captured glyph to the configured click height.
        // App icons and system-symbol fallbacks have no captured menu-bar size;
        // show them at a restrained, readable menu-bar scale.
        let artworkHeight = item.menuImage == nil
            ? min(height, min(20, max(16, image.size.height)))
            : min(height, image.size.height)
        let artworkWidth = artworkHeight * image.size.width / image.size.height
        return CGSize(width: max(height, artworkWidth), height: artworkHeight)
    }

    private static func trimmingTransparentEdges(_ source: NSImage) -> NSImage {
        var proposed = CGRect(origin: .zero, size: source.size)
        guard let cgImage = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return source }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return source }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 18 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return source }
        let pad = 2
        let crop = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                          width: min(width - 1, maxX + pad) - max(0, minX - pad) + 1,
                          height: min(height - 1, maxY + pad) - max(0, minY - pad) + 1)
        guard crop.width < CGFloat(width) || crop.height < CGFloat(height),
              let result = cgImage.cropping(to: crop) else { return source }
        let scaleX = source.size.width / CGFloat(width)
        let scaleY = source.size.height / CGFloat(height)
        let image = NSImage(cgImage: result, size: NSSize(width: crop.width * scaleX, height: crop.height * scaleY))
        image.isTemplate = source.isTemplate
        return image
    }
}

private struct TrayIconButton: NSViewRepresentable {
    let item: MenuItem
    let iconImage: NSImage?
    let displaySize: CGSize
    let isEnabled: Bool
    let usesDarkGlass: Bool
    let action: (TrayActivationAnchor, Bool) -> Void

    final class Coordinator: NSObject {
        var action: (TrayActivationAnchor, Bool) -> Void
        var acceptsInput = true
        init(action: @escaping (TrayActivationAnchor, Bool) -> Void) { self.action = action }
        func activate(_ sender: NSButton, event: NSEvent?, rightClick: Bool) {
            guard acceptsInput else { return }
            guard let window = sender.window else { return }
            let screenFrame = window.convertToScreen(sender.convert(sender.bounds, to: nil))
            var screenPoint = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
            var normalizedX: CGFloat?
            if let event, event.window === window,
               [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type) {
                screenPoint = window.convertPoint(toScreen: event.locationInWindow)
                let point = sender.convert(event.locationInWindow, from: nil)
                if sender.bounds.width > 0 {
                    normalizedX = min(1, max(0, (point.x - sender.bounds.minX) / sender.bounds.width))
                }
            }
            action(TrayActivationAnchor(screenFrame: screenFrame, screenPoint: screenPoint, normalizedX: normalizedX), rightClick)
        }
        @objc func activate(_ sender: NSButton) {
            activate(sender, event: (sender as? TrayReplicaButton)?.activationMouseEvent, rightClick: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = TrayReplicaButton(title: "", target: context.coordinator, action: #selector(Coordinator.activate(_:)))
        let coordinator = context.coordinator
        button.onRightMouseDown = { [weak button, weak coordinator] event in
            guard let button else { return }
            coordinator?.activate(button, event: event, rightClick: true)
        }
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.setAccessibilityRole(.button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        // Keep native icon artwork at full opacity while the selected host is
        // moving. Disabling NSButton greys every icon for a moment and makes
        // the tray flash before it closes. The coordinator still rejects input.
        context.coordinator.acceptsInput = isEnabled
        button.isEnabled = true
        button.appearance = NSAppearance(named: usesDarkGlass ? .darkAqua : .aqua)
        button.toolTip = item.name
        button.setAccessibilityLabel(item.name)
        let source = iconImage
        button.contentTintColor = source?.isTemplate == true
            ? .labelColor
            : nil
        if let source, let image = source.copy() as? NSImage {
            // Keep the original aspect ratio when a narrow status glyph is
            // centred in the square click target.
            if source.size.height > 0 {
                image.size = CGSize(width: displaySize.height * source.size.width / source.size.height,
                                    height: displaySize.height)
            }
            button.image = image
        } else {
            button.image = nil
        }
    }
}

private final class TrayReplicaButton: NSButton {
    private(set) var activationMouseEvent: NSEvent?
    var onRightMouseDown: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) {
        activationMouseEvent = event
        defer { activationMouseEvent = nil }
        super.mouseDown(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onRightMouseDown?(event)
    }
}
