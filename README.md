# Qbar

[English](README.en.md) · [隐私政策](docs/privacy.html)

原生 macOS 菜单栏管理工具。Swift、SwiftUI、AppKit、ScreenCaptureKit；无第三方运行时依赖，无账号和后台联网。

**当前状态：开源开发预览，尚无公开发行版。** 2026-09-30 重做收纳栏、原始图标快照、原生菜单激活及布局恢复。最新实测见 `docs/REDESIGN-2026-09-30.md`，历史记录见 `docs/QUALITY.md`。

源码按 [MIT License](LICENSE) 开放。Qbar 只使用本机菜单栏信息；个人布局和图标快照保存在本机，不应提交到代码仓库。项目内的 `backups/`、构建目录和调试日志都在 `.gitignore` 中。问题反馈可使用 GitHub Issues。

## 开发

要求 macOS 14.4+、Xcode 15.3+、XcodeGen。

```sh
xcodegen generate
xcodebuild -project Qbar.xcodeproj -scheme Qbar -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY=-
swift test
```

使用 Xcode 打开 `Qbar.xcodeproj`。本地构建可用现有 Apple Development 证书签名，固定签名和安装路径有助于在迭代时保持系统授权。

```sh
zsh Scripts/build.sh
```

输出 `dist/Qbar.app` 和 `dist/Qbar.zip`。脚本默认临时签名，仅供开发；需要系统辅助功能和录屏授权时，请使用自己的 Apple Development 证书设置 `QBAR_SIGNING_IDENTITY`。这不是已公证或已提交商店的发行包。不要把临时签名的压缩包当成面向普通用户的正式版本。

## 功能

- 普通折叠、水平玻璃收纳栏，始终显示 / 收纳 / 始终隐藏三组。
- 拖拽排序、菜单操作分组、图标搜索、单独图标快捷键。
- 收纳栏保留原始菜单栏图标与颜色，图标间距为 14 点。点击收纳栏图标只把所选图标临时显示到 Mac 菜单栏；可连续点击多个图标，让它们同时显示并直接在 Mac 菜单栏操作。每个图标单独计时，默认空闲 10 秒后各自收回。
- 监听新应用及后续新增菜单栏项目，沿用保存的分组。
- 点击、悬停、滚动及全局快捷键展开；自动收起。
- 6 种菜单栏标记、浅色/深色主题、浮窗图标大小和位置。
- 系统图标间距设置与原值备份恢复（本地非沙盒版）。
- 登录启动、配置 JSON 导入导出、明确的授权引导。

以上为代码中的实现范围，不代表已验证所有第三方应用、显示器组合及 macOS 版本。

## 使用

1. 将 Qbar.app 放到“应用程序”，打开设置。
2. 在“授权与关于”中开启辅助功能和屏幕录制。录屏只用于菜单栏图标快照，不采集声音。
3. 退出其他菜单栏管理工具，再启用管理。
4. 在“布局与图标”把不常用的项目移入收纳区。按住 ⌘ 直接拖动系统菜单栏图标也可调整实际顺序。
5. 点击 Qbar 展开。快捷键默认不设置，可在“快捷键”页自行录制；Control＋Option＋空格保留给输入法。右键 Qbar 打开菜单，⌥ 点击可临时查看始终隐藏。

初次启用不自动改变各应用图标的顺序。导入配置后，点击“应用布局”才批量移动图标。退出 Qbar 会移除折叠分隔符，让图标重新显示。

## 结构

| 位置 | 职责 |
| --- | --- |
| `Core/Preferences.swift` | 设置、稳定规则、快捷键校验、导入格式 |
| `App/MenuItem.swift` | AX/CG 菜单栏识别及 macOS 26 托管窗口去重 |
| `App/StatusController.swift` | 折叠分隔符、触发事件、浮窗、显示器定位 |
| `App/MenuBarEngine.swift` | 图标布局移动、多项临时显示与独立空闲计时 |
| `App/IconCapture.swift` | 菜单栏窗口图标快照及有界本地缓存 |
| `App/SettingsView.swift` | 六个设置页面和聚合浮窗 |
| `App/HotkeyManager.swift` | Carbon 全局快捷键与录制控件 |
| `Tests/` | 导入边界、快捷键冲突及排序的核心测试 |
| `Scripts/Fixture.swift` | A/B/C 菜单栏图标，用于真实交互回归 |

设置位于 `~/Library/Application Support/Qbar/preferences.json`；菜单栏图标快照缓存在同目录的 `status-icon-cache-v1` 中，不上传。超过 7 天的快照不再复用，启动时清理过期文件；重置设置或撤销录屏权限也会清除缓存。沙盒构建位于系统容器内对应目录。Debug 构建额外写入本地菜单栏诊断信息；Release 不写入该诊断文件。

## 商店构建

`Qbar-AppStore` scheme 使用 App Sandbox 和 `APP_STORE` 编译条件。商店版避免跨进程 AX 读取，改用 CG 菜单栏窗口信息；全局系统间距修改被禁用。**商店版不能视为当前本地版的全功能等价版本，必须完成沙盒真实交互测试和审核评估。**

Apple 官方明确指出沙盒不支持跨应用 AX API、修改其他应用偏好。实机沙盒探针也确认 Qbar 当前无法可靠读取第三方菜单栏图标身份。现有 iBar 商店包证明同类产品可上架，但不能证明 Qbar 当前实现符合审核要求。不要将 `Qbar-AppStore` 构建作为全功能正式版发布；详情见 `docs/APP_STORE.md`。

详细产品、定价和上架准备见 `docs/APP_STORE.md`。
