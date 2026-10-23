# 验证状态

核查日期：2026-10-23。开发机：Apple Silicon，Swift 6.4，Command Line Tools，macOS 27 SDK。

## 已执行

### 部分编辑器粘贴焦点兼容修复（未发布）

- `bash scripts/check.sh`：64 个场景、332 个断言通过，应用与更新辅助程序 Release 编译通过。新增无 AX 输入元素回退、窗口证据交叉检查、原控件丢失拒绝、权限／读取异常、持续稳定恢复和失败原因区分。
- 实际隔离 AppKit 窗口验证 WindowServer 窗口编号、窗口切换、浮层保守拒绝和窗口恢复；只检查编号，不读取窗口标题、文档正文或系统剪贴板。
- `bash scripts/check-ui.sh`：开发入口普通／原生全屏各 60 项布尔检查通过，五个设置页和四项容量设置检查通过。结果位于 `qa/2026-10-23-paste-focus-windowed-development.json`、`qa/2026-10-23-paste-focus-fullscreen-development.json` 及对应的 `*-settings.json`。
- 未替换运行中的 `dist/ClipDune.app`，未重新创建或发布 Release。原策略新增回归先失败，修复后通过；不把这个结果表述为截图对应编辑器已实测成功。
- 真实跨应用插入待验证：诊断进程无辅助功能权限，本次没有向用户实际文档发送输入。已知根因和受限窗口回退的能力边界见 `issues/2026-10-23-部分编辑器直接粘贴被焦点校验拒绝.md`。

### 0.4.1 双架构 DMG（草稿，正式发布受阻）

- 构建号 6，最低 macOS 14。`make release` 生成 Apple Silicon／arm64 和 Intel／x86_64 两个 DMG、Universal ZIP、签名清单和 `SHA256SUMS.txt`。
- 两个 DMG 均完成只读挂载、版本／公钥、Applications 安装入口、主程序与辅助程序的单架构、严格代码签名检查；四个资产的 SHA-256 校验通过。将 ARM 镜像误标为 Intel 的负向检查明确拒绝。
- Universal ZIP 的主程序与辅助程序均含 arm64 和 x86_64，签名更新清单也声明两种架构；原更新签名公钥和协议保持兼容。
- `bash scripts/check.sh`：57 个场景、277 个断言通过。新增 Universal 清单签名往返、两种架构兼容与不支持架构拒绝。
- 原位置的 Universal Release 包普通／全屏各 60 项布尔检查和四项容量设置检查通过；记录为 `qa/2026-10-23-v0.4.1-windowed-bundle.json`、`qa/2026-10-23-v0.4.1-fullscreen-bundle.json` 和对应的 `*-settings.json`。
- **DMG 内 ARM 应用及复制后的应用运行失败**：收到 `SIGKILL`／退出 137，无实际图标输出；旧版 0.4.0 在临时目录也复现。根因未确定，不归咎于某个安全组件，不用磁盘签名通过替代运行验收。详见 `issues/2026-10-23-DMG运行验收被系统终止.md`。
- Intel 仅完成交叉编译与静态封装检查，未做 Intel 实机运行验证。本机没有可用的 Developer ID 签名身份；没有更改安全策略或安装 Rosetta。
- 0.4.1 只保留草稿，在线 Latest 保持 0.4.0；正式发布需先通过 DMG 的实际运行门槛。

### 0.4.0

- 发布构建为 5，应用最低要求 macOS 14，安装包架构为 arm64。关于与更新页面已确认显示 0.4.0。
- `bash scripts/check.sh`：56 个场景、275 个断言通过，应用和更新辅助程序 Release 构建通过。
- 0.4.0 实际 Release 包普通／全屏各 60 项布尔检查通过，五个设置页面及容量提高、降容取消、降容确认、用量显示四项均通过；机器记录为 `qa/2026-10-23-v0.4.0-windowed-bundle.json`、`qa/2026-10-23-v0.4.0-fullscreen-bundle.json` 和对应的 `*-settings.json`。
- 已通过原生下载器重新下载并验签 GitHub 上的 0.3.1（构建 4），其包内公钥与本次公钥完全一致；不更换更新签名链。
- 发布流程先创建私有草稿、下载真实资产并验签，再切换为 latest。在线发布状态以 GitHub Release 为准，不以本地包或源码推送代替。
- 仍未执行用户真实历史上的升级重启或第三方终端插入验收；未做 Developer ID 公证或 Mac App Store 发布。

### 容量与最近使用（发布前实现验收）

- `bash scripts/check.sh`：56 个场景、275 个断言通过，应用、更新辅助程序 Release 编译及发布工具编译通过；同一测试二进制连续运行三次仍为零失败。
- `CLIPDUNE_UI_CONFIGURATION=release bash scripts/check-ui.sh bundle`：实际开发包普通／全屏各 60 项布尔检查通过。新增真实选择回调的复制／粘贴后前移，且条目 ID 集合、最近采集时间不变。
- 普通／全屏各五个设置页面完成显示检查；容量提高、降低时取消、降低时确认、容量占用显示四项均通过。已人工查看实际 Release 包通用设置截图，容量行、用量与规则说明正常显示，剩余内容可滚动访问。
- 原有普通／全屏可见性、中文输入、卡片操作、滚动复位、重复唤出与焦点归还检查继续通过。包签名 `codesign --verify --deep --strict dist/ClipDune.app` 通过，仍是开发签名，不是公证验收。
- 机器结果位于 `qa/2026-10-23-history-policy-windowed-bundle.json`、`qa/2026-10-23-history-policy-fullscreen-bundle.json`、`qa/2026-10-23-history-policy-windowed-settings.json`、`qa/2026-10-23-history-policy-fullscreen-settings.json`；截图只含合成数据。
- 未发布新版本，未修改版本号或更新公钥；未运行真实用户历史迁移、第三方终端插入或在线升级重启。QA 粘贴在演示模式使用命名剪贴板，不将其表述为真实目标应用插入通过。

### 0.3.1

- `bash scripts/check.sh`：46 个核心场景、205 个断言通过，应用和更新辅助程序 Release 构建通过。
- `CLIPDUNE_UI_CONFIGURATION=release bash scripts/check-ui.sh bundle`：实际 Release 应用包普通／全屏各 52 项布尔检查通过，五个设置页面检查继续通过。
- 新增滚动用例先在修复前观察到失败：第一项已经选中，但打开当下、查询返回后和首项部分可见情况下的滚动坐标均未复位。修复后以上三项通过。
- “回到最新”的窗口鼠标点击、第一项完整可见、选中项与输入焦点、筛选／关键词／收藏保留、空结果禁用、6 次带滚动反复重开与不触发粘贴均通过。
- 结果保存于 `qa/2026-10-22-v0.3.1-windowed-bundle.json`、`qa/2026-10-22-v0.3.1-fullscreen-bundle.json` 和 `qa/2026-10-22-v0.3.1-settings.json`。预览图只包含合成记录。
- 新增的 48 条滚动夹具仅在隔离 QA 模式生成，不读取或写入用户正常历史。数据 schema、公钥与更新协议均未改变。

### 0.3.0

- `swift run ClipDuneChecks`：46 个场景、205 个断言通过。新增名称检索、收藏与去重保留名称、归档往返、旧主表写入兼容、类型独立筛选、时区／夏令时、8 类数据保真和大小口径检查。
- `CLIPDUNE_UI_CONFIGURATION=release bash scripts/check-ui.sh bundle`：实际 Release 应用包普通／全屏均通过。覆盖卡片按钮点击命中、双击按钮不粘贴、右键菜单、重命名对话框、按名称查找收藏、类型与时间筛选、清除筛选、紧凑按钮布局、来源图标与大小、全屏宽度。
- 旧数据库兼容测试只操作临时数据库；“旧版本可读”指已测试的旧载荷字段与主表 SQL 约定，不等同于任意版本降级后的功能都保持一致。
- 原有初次唤出焦点、卡片失焦后输入、中文组词、连续 12 次唤出与焦点归还用例继续通过。
- 机器结果保存在 `qa/2026-10-22-v0.3.0-windowed-bundle.json`、`qa/2026-10-22-v0.3.0-fullscreen-bundle.json` 和 `qa/2026-10-22-v0.3.0-settings.json`；最新合成预览图为 `images/preview.png`。
- 上述测试不读取真实用户剪贴板或历史；截图只包含合成示例。真实终端输入与更新后自动重启仍沿用独立验收边界。

### 0.2.0

- `swift run ClipDuneChecks`：34 个场景、98 个断言通过，新增设置持久化、格式切换、目标检查、签名篡改、大小/哈希、来源限制、ZIP 路径、安装事务和失败回滚。
- `CLIPDUNE_UI_CONFIGURATION=release bash scripts/check-ui.sh bundle`：**实际 Release 应用包**的普通窗口与原生全屏检查均通过，包括失焦后直接输入、双击粘贴回调、中文组词、连续唤出和焦点归还。
- 五个设置页完成显示与截图核查；权限 URL 在本机 Apple 设置组件中核对，剪贴板页打开请求已实际提交。
- 新版 `.app` 已构建并验证嵌套签名。仍是 ad-hoc 开发签名，没有 Developer ID 或公证。
- GitHub 真实资产上传、下载与签名结果以该版本 Release 和交付回执为准，不把本地 prepare 等同于已发布。

### 0.1.0 历史记录

- `swift run ClipDuneChecks`：22 个场景、52 个断言通过。覆盖数据库往返、格式保留、去重、中文检索、搜索注入、收藏与清理、容量回滚、备份、权限、隐私标记、应用排除、纯文本与多文件引用。
- SwiftPM Debug 与 Release 应用编译通过；图标生成的未打包开发入口运行通过；完整 Release `.app` 组装及磁盘签名验证通过。
- `bash scripts/check-ui.sh development`：普通窗口与原生全屏各 14 项布尔检查通过，均包含 12 次反复唤出、打开即输入、中文检索与原输入焦点归还。
- GUI 证据来自独立测试宿主与合成剪贴板；真实终端和打包入口仍未验收。
- 机器结果保存在 `qa/2026-10-21-windowed.json` 与 `qa/2026-10-21-fullscreen.json`，面板截图为 `images/preview.png`，只包含合成演示数据。
- GitHub 同步目标为 `boyce-ywr/clipdune`，仓库 Private 属性已核查。提交与远端一致性以交付时的 Git 回执为准。

## GUI 验证方法

`bash scripts/check-ui.sh development` 建立独立进程的普通／原生全屏输入宿主，随后运行演示模式面板，检查：

1. 面板可见、属于活动 Space，并能在 WindowServer 的屏幕窗口列表中找到。
2. show 返回时已聚焦搜索框，稍后焦点仍稳定。
3. 无鼠标点击输入字符，字段接收正确。
4. marked text 不被普通快捷键路径截获，中文提交后检索正确。
5. 连续 12 次收起／唤出均恢复空查询与输入焦点。
6. 收起后原应用仍在前台，独立宿主验证原输入控件重新获得焦点。
7. 卡片按钮操作被点击条目；重命名后在历史与收藏中都可按新名称检索，类型与时间组合可清除。

窗口内输入使用合成事件与 NSTextInputClient，不等于实物键盘全局快捷键端到端验收。完整输入法候选操作、真实终端的辅助功能元素和粘贴回执需要分别验证。

## 尚未确认

- 0.1.0 的历史启动终止原因没有确定；0.2.0 已完成实际应用包 GUI 检查，不再沿用旧版未启动结论。见 `issues/2026-10-21-开发包启动被终止.md`。
- 完整旧应用退出、新应用启动确认的真实用户安装过程尚未整链路验收；生产安装事务的确认成功与失败回滚路径已在隔离目录中自动验证。
- Apple Terminal、iTerm2、Ghostty、Warp、IDE 内嵌终端与远程会话。
- 实际辅助功能授权之后的自动粘贴、权限中途撤回。
- 双显示器、独立 Space 开关、Stage Manager、长时间持续采集和系统升级。
- macOS 14 / 15 的实际运行；当前仅设置部署目标，未在这些系统实测。
- Developer ID 签名、公证、App Sandbox、Mac App Store 审核及品牌审查。

## 已知开发环境限制

当前 CLT 缺少 XCTest；Testing.framework 存在但缺少 TestingMacros 插件。已使用同一组测试逻辑的自包含可执行入口验证，不修改或安装系统工具链。

开发包磁盘签名检查与进程能否启动是不同检查，相关启动受限现象会独立记录，不通过关闭系统安全策略来规避。
