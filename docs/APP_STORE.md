# Qbar 商业发行准备

状态：**2026-10-01 正在验证全功能商店版可行性。** 尚未提交审核。优先考虑 App Store 一次性付费下载；如果无法在沙盒中实现用户要求的核心收纳功能，再准备开源发布。开发者已说明 Xcode 与浏览器登录 Apple 开发者账号。无需索取账号密码。

## 产品与定价

- 名称：Qbar（最终可用性需在 App Store Connect 验证）。
- 定位：安静、易整理的原生 macOS 菜单栏管理工具。
- 收费形式：**付费下载，一次性买断；无订阅、无内购解锁。**
- 中国大陆建议价格：**人民币 28 元**；这是待设置的方案，不是已生效的商店价格。
- 参考 iBar Pro 页面展示 68 元，28 元低约 59%；发布时再次核对竞品和 App Store 可用价格点。
- 将图标搜索、配置迁移、清晰的权限说明、独立图标快捷键作为具体差异；不使用未经证实的“全网最强”“完全兼容”宣传。

参考：[iBar Pro](https://apps.apple.com/cn/app/id6737150304?mt=12)、[iBar 功能](https://www.better365.cn/ibar.html)。

## 已准备

- 原创名称、程序图标与中文设置界面。
- 无外部运行时依赖的 Xcode 项目。
- 本地版和沙盒版两个 scheme。
- App Sandbox、用户选定文件读写 entitlements；没有网络 entitlement。
- PrivacyInfo.xcprivacy 与本地设置存储。
- 可测试的 A/B/C 菜单栏测试程序及配置核心测试。

## 必须解决的技术事项

1. macOS 26 将许多菜单栏窗口托管到 Control Center；商店版只用 CG 信息时不能保证识别原应用。需要验证稳定身份和跨重启布局恢复。
2. 商店沙盒下验证 CGEvent 拖动/点击与 ScreenCaptureKit 截图，不能用非沙盒成功替代。
3. 全局图标间距涉及系统共享偏好；当前仅本地版启用。商店文案不能宣称拥有该能力。
4. 测试内置刘海屏、外接屏、不同分辨率、自动隐藏菜单栏、全屏空间、锁屏恢复及应用重启。
5. 确认辅助功能授权使用符合审核说明。仅使用公开符号不等于自动通过审核。
6. 分发签名、沙盒容器持久化、开机启动、干净安装和升级测试。

### 2026-10-01 本机沙盒验证

- `Qbar-AppStore` 的 `AppStoreDebug` 构建成功；测试副本使用 Apple Development 签名，`codesign` 确认 `com.apple.security.app-sandbox=true`。这只是开发测试签名，不是商店分发签名。
- 测试副本在已有 Qbar 授权下显示 PostEvent 控制权限与屏幕录制权限为已授权。未测试图标移动、点击和自动收纳是否能在沙盒中正常工作。
- 沙盒版关闭 AX 扫描后，本机扫描到 20 个菜单栏窗口，20 个均由 Control Center 托管，14 个只能标成 `window-<临时窗口 ID>`，无法可靠关联到第三方 App 或跨重启保存布局。这是当前实现的明确功能缺口。未对这些匿名图标执行批量移动。
- 单独签名的只读 AX 探针使用相同 Bundle ID、开发证书和沙盒配置：`AXIsProcessTrusted()` 返回 `true`，但对 Finder 和 Control Center 读取 `AXRole` / `AXExtrasMenuBar` 均返回 `-25204`（`cannotComplete`）。这与 Apple DTS 所说的沙盒 AX 不受支持相符；系统界面显示“辅助功能已授权”不能证明跨应用 AX 实际可用。
- 本机 `/Applications/iBar.app` 存在 App Store receipt，签名含 App Sandbox；[iBar 的商店页面](https://apps.apple.com/cn/app/id6443843900?mt=12)说明同类聚合与临时移出功能确实有上架实例。因此不能由 Qbar 当前实现失败推断该类产品一概无法上架，也不能由 iBar 已上架推断 Qbar 会获批。
- [Apple DTS 对权限的区分](https://developer.apple.com/forums/thread/820594)：PostEvent 与 ListenEvent 技术上可用于沙盒；跨应用 AX 读取不受支持。技术可运行与 App Review 是否接受是两项独立判断。Qbar 已用 `CGPreflightPostEventAccess` 检查事件发送权限，图标身份识别仍需找到稳定且可审核的方案。

依据：[Mac App Store Review Guidelines 2.4.5 / 2.5.1](https://developer.apple.com/app-store/review/guidelines/)、[App Sandbox 限制](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)、[Apple DTS 对沙盒 AX 的说明](https://developer.apple.com/forums/thread/794253)。

## App Store Connect 待办

功能验证完毕后使用已有登录会话：

1. 确认实际发行的 Team、Seller 与 Bundle ID（当前开发 ID 是 `studio.qbar.mac`）。
2. 创建 macOS App 记录，核对 Qbar 名称可用性。
3. 使用正式 App Store 分发签名归档，Validate 后 Upload。
4. 将中国大陆价格设为可用价格点中最接近 28 元的一次性下载价格；核对其他地区价格。
5. 确认付费应用协议、税务和银行资料由账号持有人完成。
6. 填写隐私问卷（当前代码不上传或收集用户数据）、年龄分级、出口合规、支持地址和隐私政策 URL。
7. 提供来自通过验收的商店版的真实截图，填写权限、操作路径及沙盒限制的审核说明。
8. 最后提交审核。上架结果以 Apple 实际审核为准。

尚未设置定价、创建线上 App、接受协议、购买服务或提交审核。

## 文案草案（需按商店版通过的功能删改）

副标题：让 Mac 菜单栏，井然有序

简介：Qbar 帮你把常用图标留在眼前，把不常用的妥善收好。用普通折叠模式保持简洁，或用聚合浮窗快速找到需要的图标。支持图标搜索、独立快捷键与布局配置导入导出。没有账号、广告或后台上传，一次购买，持续使用。

审核备注需明确：隐藏通过应用自身的 NSStatusItem 分隔符完成；移动/点击需用户授予控制权限；ScreenCaptureKit 仅抓取菜单栏图标窗口，快照可能在用户 Mac 本地缓存以便重启后恢复显示；不录制音频、不上传数据；无静默授权或沙盒逃逸。
