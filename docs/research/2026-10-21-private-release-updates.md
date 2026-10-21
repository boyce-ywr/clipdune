# 私有 GitHub Releases 在线更新：ClipDune 方案核查

核查日期：2026-10-21。范围：`boyce-ywr/clipdune` 私有仓库、macOS AppKit、纯 SwiftPM、仅 Command Line Tools（CLT）、自用更新。本文是主源调研与设计建议，不是已完成的接入或安全验收。

## 1. 先给结论

**本轮建议：首版采用原生 GitHub REST 下载 + 固定 Ed25519 公钥验证 manifest + 独立、非提权安装 helper。保留 Sparkle 作为后续选项，不为它阻塞当前设置与交互实现。** 这是基于下述已核实限制的工程选择，不是认定 Sparkle 不支持私有分发。

1. **无需自建更新服务端，也无需全局 `gh`。** 用户在自己的设备上配置自己的 fine-grained PAT，客户端直接读取私有 Releases 和 assets 即可；GitHub 是远端托管服务。PAT 最小配置为选定该仓库、`Contents: read`，但此权限不只允许下载安装包，也能读取相应仓库内容，不能随 App 分发。[S10][S11][S13][S14]
2. **Sparkle 当前稳定版是 2.10.0**，官方 Release 发布于 2026-09-13 UTC，最低 macOS 12，覆盖本项目 macOS 14 基线；官方 SwiftPM 包使用预编译二进制 target，不要求客户端源码编译 Sparkle。[S1][S2]
3. **Sparkle 支持 HTTP headers，但不等于可以直接把私有 asset API 当 appcast。** `SPUUpdater.httpHeaders` 覆盖检查更新、更新说明、安装包；然而 2.10.0 的 `SUAppcastDriver.m:66` 在复制这些 headers 后，强制把 `Accept` 改为 `application/rss+xml,*/*;q=0.1`。GitHub asset API 的原始内容下载要求 `application/octet-stream`。因此，“设置 Bearer + octet-stream，直接给 Sparkle 一个 asset API feed URL”不具备官方契约上的可靠性。[S5][S6][S11]
4. **Sparkle 无服务端绕行存在候选，但本轮没有核实到覆盖所有合法响应的干净接法。** 客户端可先认证请求 asset API，遇到 `302` 时把临时下载 URL 交给 Sparkle；但 API 也允许 `200` 直接返回内容，此时未必有可移交 URL。临时链接失效、重试、安装包认证同样需要适配。不能将这个仅覆盖 `302` 的路径写成可直接交付。[S11][S16]
5. **安全重定向不能凭经验担保。** Sparkle 2.10.0 下载器使用默认配置的 `URLSession`，未实现逐次 HTTP 重定向 delegate，也未在已核对的公开 updater delegate 中提供对应控制点。这里只能确认“交给系统网络栈”，不能由此断言一定泄漏或一定不泄漏 PAT。原生实现可以明确控制每一次跳转。[S7][S8][S18]

推荐原生并不意味着 helper 简单：安装事务、解包、路径校验、崩溃恢复都是需要承担的安全责任。若后续 Sparkle 的私有 feed、重定向和 CLT 打包验证全部通过，应重新比较，成熟安装器仍是其明显优势。[S3][S7][S8]

## 2. 本轮边界与证据等级

- **已做**：首先调用 `web.run`；其返回空内容后，通过 `curl --proxy http://127.0.0.1:7897` 读取官方站点和固定版本官方源码。请求使用 5 秒连接超时、18–22 秒总超时；错误路径不反复等待。后台子任务独立核对 GitHub REST 契约。
- **只用主源**：Sparkle 官方文档、Sparkle 2.10.0 源码、GitHub 官方 REST/认证文档、Apple 官方 API/签署文档。本轮未访问或复制 Clipbara 源文件。
- **已读本项目初始快照**：`Package.swift:6` 声明 macOS 14；`scripts/build.sh:5` 使用 `swift build`，随后手工组装 `.app`，`:23` 使用 ad-hoc 签名。主线程在并行实现，本文不把初始快照当作最终代码状态。
- **本机只读核验**：`xcode-select -p` 为 `/Library/Developer/CommandLineTools`；`swift --version` 为 Swift 6.4；`xcrun --find notarytool`、`xcrun --find stapler` 均返回 CLT 下路径。因此不能泛称“没有完整 Xcode 就没有这些公证工具”；工具存在也不等于拥有证书或公证已成功。
- **未做**：未读取凭据、未调用目标私有仓库 API、未运行 `gh`、未发布 Release、未修改权限、未安装框架、未编译接入样例、未实际更新 App。除了本笔记，不写项目文件。
- **尚有共同前置门槛**：本轮开始时 `README.md:7` 仍声明应用包启动被本机终止、原因未确认。它是仓库记录，不是本轮重现结果。任何更新器交付都要先证明基线 `.app` 可正常启动；不能把更新器当成启动问题的修复。

下文“官方确认”指文档/源码已核对；“建议”指据此推导的设计；“未验证”不等同于不可行。

## 3. Sparkle 官方接入：能力与 CLT 边界

### 3.1 支持 AppKit、程序化初始化和 SwiftPM

官方推荐 Sparkle 2 使用 `SPUStandardUpdaterController`，可程序化实例化，无需 nib/storyboard，也不要求改成 SwiftUI。`SUUpdater` 在 Sparkle 2 是迁移用的已弃用接口，不应作为新接入入口。[S3][S4]

2.10.0 的 `Package.swift` 定义名为 `Sparkle` 的 library product，通过带 checksum 的 `binaryTarget` 引用官方发行的 `Sparkle-for-Swift-Package-Manager.zip`。因此纯 SwiftPM 接入有明确的包入口；但“存在二进制包”不等于“本项目 `swift build` + 手工打包已经验收通过”。官方主教程的操作步骤仍以 Xcode 项目为主。[S2][S3]

对本项目的接入清单应至少包括以下项目；这是待验证工作，不是本轮实施：

- 链接框架并把完整运行时框架放入 `.app/Contents/Frameworks`；正确设置 `@executable_path/../Frameworks` 等运行时搜索路径。不能仅在 SwiftPM 中加 dependency 就认为分发包完整。[S3]
- 保留所需嵌套安装/更新组件，按嵌套代码由内而外签署，再签外层 App；不能靠一次外层 ad-hoc 签署就推定所有组件身份正确。Apple 的 `--deep` 签署不是替代正确构建签署流程的通用方案。[S3][S21]
- 配置 `SUPublicEDKey`、feed 获取策略与单调递增的 `CFBundleVersion`；从真实旧版本升级到新版本，验收退出、替换、重启，而非只检查框架可以 import。[S3]
- 官方建议采用 Developer ID 签署及公证。当前已确认的 CLT 工具路径只能排除“工具必然缺失”这一假设，不能证明当前证书、嵌套签署、公证或 Gatekeeper 通过。[S3][S22]

结论：**CLT-only 不是已有证据证明的绝对禁区，但也没有完成本机可发行包验证。** 不应为了调研先要求安装完整 Xcode，更不能承诺零打包工作。

### 3.2 私有 feed 与安装包认证不能混为一谈

| 环节 | 官方确认 | 对私有 GitHub 的含义 |
| --- | --- | --- |
| 全局请求 headers | `SPUUpdater.httpHeaders` 用于 feed、更新说明及安装包。[S5] | 可携带认证；不是只给某一个域名设置认证的策略接口。 |
| Appcast 的 `Accept` | 2.10.0 强制覆盖成 RSS 优先的值。[S6] | 不能靠同名 header 强制 asset API 返回 XML 原文；Contents API 的 raw 媒体类型也有同类问题。 |
| 安装包的初始请求 | `updater:willDownloadUpdate:withRequest:` 允许修改可变请求。[S8] | 可以为安装包单独设置 `Accept: application/octet-stream`、检查 origin；不能据此推导 feed 也存在同样的钩子。 |
| HTTP 重定向 | 下载器内部创建默认 `URLSession`，没有逐跳回调实现。[S7] | 上述更新请求钩子不是逐次重定向钩子；安全性要测试实际系统行为。 |
| 远程更新说明 | headers 也覆盖此下载，delegate 可决定不下载独立 release notes。[S5][S8] | 首版宜只显示受信的内嵌简短说明，不给未知外域发送携带 PAT 的初始请求。 |

**风险推导**：如果把 PAT 广泛配置在 updater 上，而未可信验证的 feed 能指定任意下载 origin，认证信息可能在初始请求阶段就暴露；即使安装包最终签名验证失败，也不代表之前的凭据发送安全。需要验证 feed 签名、约束初始 origin，不能只讨论“跨域重定向会不会剥离 Authorization”。[S5][S6][S8][S9]

### 3.3 无服务端路径逐项评估

| 路径 | 本轮判断 | 原因与缺口 |
| --- | --- | --- |
| 私有 release asset API 直接作 feed + `httpHeaders` | **不作为可靠首版** | appcast 的 `Accept` 覆盖与 GitHub 原始下载契约冲突。[S6][S11] |
| 私有 Contents API 直接作 feed | **同样不直接采用** | 官方原始文件媒体类型为 `application/vnd.github.raw+json`，不能假定 RSS Accept 仍返回 XML。[S6][S17] |
| 客户端预请求 asset，取 `302 Location` 给 Sparkle | **无自建服务端的候选** | 仅覆盖 `302`；必须补齐合法的 `200` 分支、临时 URL 失效及重试。还需要独立处理 enclosure 下载认证。[S11][S16] |
| 每次用 Contents API 查询新的 `download_url` | **候选，未验收** | 官方说明 URL 会过期、应每次获取，字段允许为 null；未确认私有返回 URL 的完整鉴权与 Sparkle 重试兼容性。[S17] |
| 直接给 `raw.githubusercontent.com` 加 PAT header | **未找到足够官方保证** | 不把 api.github.com 的认证保证外推到 raw 域名；不能写成已证实，也不断言一定不可用。[S17][S23] |
| 客户端先下载 XML，再交给 `file://` feed | **不是现成逃生口** | 已核对的 Sparkle 下载器只接受 HTTP/HTTPS，直接传本地文件 URL 不符合该路径。[S7] |
| 自建远端代理，输出标准 appcast 并做下载授权 | 技术上可行，但本需求不必选 | 引入托管、认证及 secret 管理，偏离无自建服务端目标；这是架构推导，不是 Sparkle 的强制要求。 |

如果未来试 Sparkle，首先做**限时概念验证**：一个真实私有 appcast、真实 asset、模拟 `200/302`、过期链接和跨域跳转、CLT 打包旧新两个 App。不能用“公开 feed 成功”替代私有链路；不能通过在 URL 中永久拼接 PAT、大小写不同的重复 Accept header 或依赖未文档化参数来绕过限制。

### 3.4 签名配置不要只停留在安装包

官方支持 EdDSA 更新包签名；`SUVerifyUpdateBeforeExtraction` 可以强制解包前验证，Sparkle 2.9 起的 `SURequireSignedFeed` 还可验证 appcast 和 release notes，后者要求前者同时启用。对带有私有认证的分发，两者均应进入评估。[S3][S9]

`SUSignedFeedFailureExpirationInterval` 默认是 20 天，设为 `0` 可禁用签名失败的到期放宽机制。若选择严格 fail-closed，应明确配置与密钥恢复策略；不能宣称启用 signed feed 后，默认行为在任意长时间后仍绝不放宽。没有 Developer ID 兜底时，遗失更新签名私钥更可能需要手动安装恢复。[S3][S9]

## 4. GitHub Releases REST：原生客户端的确定性契约

### 4.1 API 版本与 latest

截至本轮，GitHub 官方支持表列出的较新 REST 版本为 **`2026-03-10`**；未指定版本仍默认 `2022-11-28`，旧版本支持至 **2028-03-10**。新实现建议显式固定 `X-GitHub-Api-Version: 2026-03-10` 并测试，不能把 `2022-11-28` 写成当前最新版本。[S12]

检查入口为 `GET /repos/boyce-ywr/clipdune/releases/latest`，JSON 请求使用 `Accept: application/vnd.github+json`，凭据由用户在 App 中配置。`latest` 排除 draft 和 prerelease；若仓库只有预发布，不能擅自回退为自动安装预发布。[S10][S23]

官方 GET 文档描述为按 `created_at` 选最近的非预发布、非草稿，并特别说明这是对应 commit 的日期，而非草稿创建或发布时间；与此同时，创建/更新 Release 的 `make_latest` 提供 `true`、`false`、`legacy`，新发布默认 `true`，`legacy` 描述了日期和较高语义版本判断。**保留这些文档口径，不自行合并成“总是最大 SemVer”。** 实现建议将 `/latest` 视为发布入口指针，再以已签名 manifest 的递增 build 检查是否允许更新。[S10]

### 4.2 Asset 下载

从 Release 的 `assets` 中选择固定名称的 manifest、签名和当前架构安装包，记录 asset ID。不要把 GitHub 自动生成的源码 tarball/zipball 当 App 安装包。下载端点为 `GET /repos/boyce-ywr/clipdune/releases/assets/{asset_id}`。[S10][S11]

| 请求/响应 | 客户端处理 |
| --- | --- |
| Release / asset 元数据 | `Accept: application/vnd.github+json`，按 JSON 解析。[S10][S11] |
| Asset 文件内容 | `Accept: application/octet-stream`，向可信 API origin 发送 Bearer 凭据。[S11][S23] |
| `200` | 直接消费文件内容；安装包流式落盘，不误按 JSON 解码，也不要求必须有 Location。[S11] |
| `302` | 处理 Location；临时地址只用于本次下载，不持久化为后续更新入口。[S11][S16] |
| `browser_download_url` | 官方浏览器下载入口，不是私有资源免认证保证；不作为程序下载的唯一依据。[S11] |
| `digest` | API schema 允许 null；可做附加一致性检查，不能取代独立签名信任根。[S11] |

**建议的安全重定向实现**：使用普通/ephemeral `URLSession`；每一跳检查 HTTPS、规范化后的 hostname/port、禁止 URL 用户信息、限制跳数，拒绝降级。仅对初始、固定且已核对路径的 `https://api.github.com:443` 请求加凭据；跳转请求先移除 `Authorization`、Cookie 等敏感头，不向下载存储域补加 PAT。需要重新认证时回到可信 asset API 发起新请求，而非向未知 Location 补 token。禁用不需要的 cookie/持久缓存，避免日志记录完整请求头及带查询参数的下载 URL。该策略是设计要求，不是 Sparkle 或所有 URLSession 的默认保证。[S14][S16][S18]

Apple 特别说明逐次重定向 delegate 只对 default/ephemeral session 调用，background session 自动跟随。因此“调研后台进行”不应混淆成“实现时使用 background URLSession”；首版应选择能控制重定向的 session 类型。[S18]

不写死临时下载 URL 的 TTL，也不假定存储域永久不变。若实现域名 allowlist，应根据实际 GitHub 跳转证据维护、精确匹配；不要粗放接受所有 `*.githubusercontent.com` 并仍携带 PAT。HTTPS、无凭据跨域和安装包签名是不同层的保护。

### 4.3 凭据与错误边界

- 自用默认 fine-grained PAT：正确 resource owner、仅该仓库、`Contents: read`、设置到期时间；组织策略/审批可能额外限制。token 权限不能超过用户自身权限。[S13][S14]
- PAT 由用户单独输入，存 Keychain；不得放源码、Info.plist、UserDefaults、manifest、appcast、命令参数或诊断日志，也不得把发布者共用 PAT 内置分发。Keychain 提供秘密存储，不意味着运行时秘密不可被已攻陷的 App 使用。[S14][S20]
- `401`、`403`、`404` 不统一显示“没有更新”：`404` 也可能是私有资源无权访问；`403` 需结合响应区分权限与限流。无凭据/过期/无权与“没有稳定 Release”应在设置交互中区分，但 API 信息不足时不要捏造精确原因。[S16][S23]
- 尊重 `Retry-After`、速率限制和条件请求，不做忙循环重试；首版仅用户手动检查，避免把定时调度、增量下载和自动重试扩进最小范围。[S16]

## 5. 两种方案的实际取舍

| 维度 | Sparkle 2.10.0 | 原生 HTTPS + Ed25519 manifest + helper |
| --- | --- | --- |
| 私有 GitHub 获取 | 有 header 能力，但 appcast Accept 冲突与临时 URL 适配未闭环 | 直接满足 REST 的 JSON、文件、200/302 契约 |
| 是否必须额外服务器 | 不必须；本轮候选绕行尚未覆盖所有分支 | 不必须，自己的 PAT 直接调用 GitHub |
| CLT-only | 官方 binary package 可用，App 嵌入/签署仍待本机验证 | 可沿用 SwiftPM/AppKit；helper 打包与签署仍需新增和验证 |
| 安装与更新 UI | 成熟安装器和标准更新流程，少造轮子 | 主线程已有 UI 可复用，但安装事务和恢复必须自己实现 |
| 安全重定向控制 | 公开 updater API 不提供逐次钩子，需验证系统行为 | 直接使用 Apple delegate 实施确定性规则 |
| 更新真实性 | EdDSA 包签名，可增加 signed feed 与解包前验证 | 固定公钥验证 manifest，再验证其绑定的包哈希；helper 再验 |
| 长期维护 | 跟踪框架安全更新、版本/签署兼容性 | 自己维护协议、密钥轮换、防回滚、解包和安装安全 |

表中事实依据为 [S2]–[S11]、[S18]–[S22]；复杂度与选择属于针对本项目约束的工程判断。**若只是“仓库私有”，不足以排除 Sparkle；本轮选择原生的原因是当前确定的 feed 适配缺口和可控重定向需求，而不是为了少引一个依赖。**

## 6. 原生首版最小可交付范围（设计，不是代码）

### 6.1 用户与安装边界

- 仅本人、自有设备、自己的私有仓库；设置项只需要凭据配置/删除、连接状态、手动检查更新。仓库坐标固定，不提供任意 URL 输入。
- 仅当前支持架构的完整包、稳定 Release；不做 delta、静默更新、预发布通道、后台定时检查或全局 `gh` 集成。
- 首版支持固定且当前用户可写的安装位置，例如用户自行安装到 `~/Applications/ClipDune.app`；不自动搬迁当前安装、不提权、不安装守护进程。只读卷、DMG、应用转位或无权限位置明确拒绝，给手动安装指引。

### 6.2 最小发布产物与信任链

每个 Release 建议包含 `ClipDune-macos-arm64.zip`（或实际支持架构）、`update-manifest.json`、`update-manifest.sig`。这些是建议命名，不代表仓库当前已有对应资产。

manifest 至少绑定：协议版本、仓库标识、release ID、安装包 asset ID/名称、bundle identifier、显示版本、单调 build、架构、最低 macOS、安装包字节数、SHA-256；可加入明确的有效期政策。公钥内置于通过可信初装渠道得到的 App/helper，不能从同一未签名 Release 元数据动态下载公钥并直接信任。

用独立的 Ed25519 发布私钥对 **manifest 原始 UTF-8 字节** 做 detached signature；客户端先做输入大小限制、验签，再解析并校验字段，避免 JSON 重排/规范化歧义。Apple CryptoKit 的 `Curve25519.Signing` 明确采用 Ed25519；它与 `Curve25519.KeyAgreement` 不是同一用途。[S19]

校验顺序建议：发现 Release → 下载 manifest/签名 → 固定公钥验签 → 确认仓库、asset ID、build、系统与架构 → 流式下载归档并检查大小/哈希 → 交安装 helper。签名保证 manifest 未被无密钥者篡改，哈希把它绑定到实际安装包；HTTPS/PAT 负责传输和访问控制，两者不能替代签名。

版本策略至少拒绝不大于已安装 build 的网络更新；记录成功安装的最高 build，避免 tag/时间排序降级。签名本身不能阻止合法旧版本重放、服务端一直隐瞒更新或本地时钟回拨，不能宣称实现了完整抗回滚协议。有效期、轮换及手动恢复规则必须明确。

发布顺序建议：先建 draft、上传完整包拿到 asset ID，再生成并签名 manifest，上传 manifest/签名，确认资产完整后发布并设置 latest。不要先让半成品成为 latest。发布私钥与用户下载 PAT 分离；签名后的包、manifest 发生任何字节变化都必须重新生成相应签名/哈希。

### 6.3 Helper 的最低责任，不可省成一段 `cp`

以下是最小验收要求，不声称本项目已有这些能力：

1. helper 在用户确认后启动，具有可信的代码/安装来源；不接收任意远程 URL、任意目标路径或可执行 shell 字符串。它**不需要 PAT**，只消费已下载的本地待验证产物。
2. 在独立、权限受限的 staging 中再次验证 manifest 签名、归档大小/哈希、预期安装路径与身份；防止主 App 校验后文件被替换。提取后检查 bundle ID、版本/架构、必需文件及适用的代码签署策略。
3. 解包前验签；解包过程限制体积、文件数量和路径，拒绝绝对路径、`..` 越界与逃逸 staging 的符号链接。调用系统工具时使用参数数组，不拼 shell；不能假定任意 ZIP 都可安全解包。
4. 等待原 App **实际退出** 后再替换；超时失败保留旧包，不边运行边逐文件覆盖。对于同卷替换使用明确的备份/替换事务和持久化阶段记录，崩溃后能识别并恢复，不将“rename 原子”误当成整个多步事务自动原子。
5. 新包重启后提供健康确认；替换失败或启动失败保留恢复路径。应用包可回滚不代表用户数据格式可回滚，首版更新必须保持数据向后兼容，否则另做数据迁移/备份方案。

这也是原生方案的主要成本。若不能完成这些验证，首版应退到“下载、验签、提示用户手动替换”，并明确它**不等于自动安装更新已交付**，而不是省略安全步骤后仍称完成。

### 6.4 系统签署与自用边界

Ed25519 只建立本更新协议的真实性，不能替代 Apple Developer ID、notarization 或 Gatekeeper。ad-hoc 自用包、Keychain 授权连续性和辅助功能等系统权限在替换后均需实际测试；不得自动删除 quarantine、关闭系统校验或承诺无需重新授权。[S20][S21][S22]

发布私钥遗失/泄漏的处理必须预先说明：首版固定公钥可先以可信手动重装作为恢复边界；不要临时改为“从服务器获取新公钥自动接受”。未来做轮换需要旧信任根授权和独立设计，不在本次最小实现中暗加。

## 7. 交付门槛与尚未验证

| 验收组 | 必须覆盖 | 本轮状态 |
| --- | --- | --- |
| 私有访问 | 有效/过期/撤销 PAT、错误仓库、无权限、无稳定 release | 未实测；未访问目标私有仓库 |
| 下载协议 | 文件直返 `200`、跨域 `302`、过期 Location、重定向链、HTTP 降级、无 token 外发 | 契约已核实；实际客户端未实现/未测试 |
| 真实性 | 错公钥、签名破坏、manifest 字节变化、包哈希/长度不符、错误架构、旧 build | 设计验收项，未执行 |
| 安装 | App 不退出、无权限、解包越界、磁盘空间不足、替换中断、启动失败、恢复 | 设计验收项，未执行 |
| 系统集成 | 基线包可启动、真实旧版→新版、Keychain/系统权限、用户数据保留 | 未做本轮 GUI/升级验证 |
| Sparkle 备选 | 私有 feed 的 Accept 问题、200/302 全覆盖、URL 失效、token 无泄漏、CLT 嵌套打包 | 有明确缺口，不能标记接入完成 |

**决策出口**：当前可推进原生方案的设置与交互，网络和 helper 按上述协议边界衔接。只有拿到 Sparkle 私有 feed 全链路和本机分发包的实测证据，才建议切回 Sparkle；不要求新增服务器，不改变仓库可见性，不要求用户安装全局 `gh`。

## 8. 主源索引

Sparkle 源码固定到 **2.10.0**；网页文档与 GitHub REST 内容按 **2026-10-21** 抓取。以下 URL 不含任何私有凭据。Apple TN2206 是历史归档，只用于嵌套代码签署原则，不能替代当代 Gatekeeper 的实际测试。

[S1]: https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0 "Sparkle 2.10.0 官方发行；另经官方 GitHub releases/latest API 核对"
[S2]: https://github.com/sparkle-project/Sparkle/blob/2.10.0/Package.swift "官方 SwiftPM binaryTarget、最低系统版本与 checksum"
[S3]: https://sparkle-project.org/documentation/ "Sparkle 官方接入、分发、签名、版本及测试指南"
[S4]: https://sparkle-project.org/documentation/programmatic-setup/ "程序化初始化 SPUStandardUpdaterController"
[S5]: https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUpdater.h#L341 "httpHeaders 的公开契约"
[S6]: https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SUAppcastDriver.m#L66 "Appcast 请求复制 headers 后覆盖 Accept"
[S7]: https://github.com/sparkle-project/Sparkle/blob/2.10.0/Downloader/SPUDownloader.m "下载器 URL scheme、URLSession 和 delegate 实现"
[S8]: https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUpdaterDelegate.h#L275 "更新说明控制、安装包初始可变请求；无逐跳重定向接口"
[S9]: https://sparkle-project.org/documentation/customization/ "SUVerifyUpdateBeforeExtraction、SURequireSignedFeed、签名失败期限"
[S10]: https://docs.github.com/en/rest/releases/releases?apiVersion=2026-03-10 "Releases/latest、assets、make_latest、draft/prerelease"
[S11]: https://docs.github.com/en/rest/releases/assets?apiVersion=2026-03-10 "Asset API octet-stream、200/302、browser_download_url、nullable digest"
[S12]: https://docs.github.com/en/rest/about-the-rest-api/api-versions "当前支持版本、默认版本及停止支持日期"
[S13]: https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens#repository-permissions-for-contents "Contents read 对 Releases/Assets 的权限映射"
[S14]: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens "PAT 最小权限、仓库选择、期限与组织限制"
[S16]: https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api "临时重定向、速率限制、条件请求及重试"
[S17]: https://docs.github.com/en/rest/repos/contents?apiVersion=2026-03-10 "原始文件媒体类型、临时 download_url 与字段 schema"
[S18]: https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:) "普通/ephemeral session 的逐次重定向控制；background session 限制"
[S19]: https://developer.apple.com/documentation/cryptokit/curve25519/signing "CryptoKit Curve25519.Signing 明确使用 Ed25519"
[S20]: https://developer.apple.com/documentation/security/keychain-services "Keychain 秘密存储及访问控制"
[S21]: https://developer.apple.com/library/archive/technotes/tn2206/_index.html "Apple 历史签署技术说明：嵌套代码、由内而外签署、--deep 边界"
[S22]: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow "命令行公证工作流和系统分发边界"
[S23]: https://docs.github.com/en/rest/authentication/authenticating-to-the-rest-api "REST Bearer 认证、私有资源及认证错误"
