# GitHub Release 在线升级

## 用户使用

1. **首次从 0.1.0 升级需手动安装当前版本**。0.2.0 及之后版本已有更新器；当前线上仍为 0.4.0，0.4.1 双架构草稿尚未开放在线更新。0.4.1 手动安装按芯片选择 `arm64.dmg`（Apple Silicon）或 `x86_64.dmg`（Intel）；正式发布后在线更新共用 Universal ZIP。
2. 将完整应用放在 `/Applications` 或 `~/Applications`。目录必须可写；更新器不提权、不修改管理员权限、不在 DMG 或开发产物目录原地安装。
3. 打开 **设置 → 关于与更新**，为 `boyce-ywr/clipdune` 配置自己的 GitHub fine-grained PAT，仅选择这个仓库并授权 `Contents: Read`。这项权限也能读取仓库源码，并非仅能读 Release。
4. 令牌只保存在 macOS 钥匙串，限定本机，不写进 UserDefaults、日志、应用包、URL 或仓库。应用不会读取 `gh` 的登录凭据。发布验证工具可由操作者通过 stdin 临时传入凭据，不保存。
5. 选择“检查更新”。开启自动检查后，应用启动时以及运行期间每小时检查是否距离上次成功检查已超过一天。没有令牌时不执行自动网络检查。
6. 发现版本后可下载、稍后提醒或跳过此版本；下载可取消。下载后验证通过，**再次确认安装并重启**。

网络默认使用当前开发环境的 `http://127.0.0.1:7897` HTTP 代理。更新设置中可修改；留空使用系统网络设置。不会因为代理失败自动转为直连，不影响剪贴板本地功能。

## 版本与信任链

- 固定仓库 `boyce-ywr/clipdune`，仓库保持 Private。
- `GET /repos/boyce-ywr/clipdune/releases/latest` 只消费非草稿、非预发布版本；不自行降级为 beta 或任意其他仓库。
- 每个版本必须有 `clipdune-update.json` 和 `ClipDune-<version>-macOS.zip` 两个在线更新资产。自 0.4.1 起 ZIP 中的主程序和更新辅助程序均包含 arm64 与 x86_64，清单同时声明两种架构。
- 手动安装另提供 `ClipDune-<version>-macOS-arm64.dmg` 与 `ClipDune-<version>-macOS-x86_64.dmg`，镜像中的主程序和辅助程序均为对应单架构。`SHA256SUMS.txt` 覆盖两个 DMG、ZIP 和签名清单；共五个发布资产。
- 清单封装原始 JSON 的 Base64 与 Ed25519 签名。客户端使用应用资源中的固定公钥验证，之后才信任构建号、版本、系统要求、架构、安装包名、大小、SHA-256 和更新说明。
- `CFBundleVersion` 是单调递增整数。只安装比当前构建号大的版本；清单 version 必须与 Release tag 的 `v<version>` 一致。
- 下载按 GitHub asset ID 请求 API，支持 200 原始内容或 302 CDN 跳转。认证只发到固定仓库的 `api.github.com` 路径；CDN 请求重建 headers，不携带 Bearer。
- 全程 HTTPS，拒绝陌生域名、带用户名密码的 URL 和多于 4 次重定向。安装包下载最大 256 MiB，清单最大 128 KiB，解包后最大 512 MiB。
- 解包前验证签名、长度和 SHA-256，再检查 ZIP 中央目录中的路径、加密标记、条目数、压缩方式与 Unix 文件类型；拒绝绝对路径、上级路径和符号链接。
- 解包后核对 Bundle ID、版本、构建号、可执行文件、文件类型及嵌套代码签名，再准备安装。

## 安装事务

1. 旧应用启动自己携带的非提权 helper；helper 使用旧应用公钥重新验证清单与安装包。
2. helper 确认运行中的父进程就是目标应用，写就绪标记后等待父进程退出。
3. 将已验证的新应用复制到目标目录的备用位置。使用同文件系统的原子交换替换应用；原应用保留为 `.ClipDune-backup-<UUID>.app`。
4. 启动新版本，等待其完成数据库初始化并回传构建号确认，最多 45 秒。
5. 未收到确认时，尝试正常退出新应用，再原子交换恢复旧版。不强制结束无法正常退出的应用；此时保留备份并记录需要人工处理。
6. helper 不读写剪贴板历史数据库内容或导入备份。0.4.0 主 schema 仍为 1，附表扩展名称、类型与最近使用时间，并保留旧版可解码载荷；已有旧主表写入、活动回填与载荷解码兼容测试。未来引入不向后兼容 schema 时，必须重新设计回滚迁移，不能只靠应用目录备份。

状态位于 `~/Library/Application Support/ClipDune/Updates/installation.json`，设置页显示上次安装状态。保留旧版备份供恢复，不自动无限清理其他文件；用户确认新版本稳定后可以删除对应备份。

## 发布者流程

本机签名私钥放在仓库外，默认路径为 `~/Library/Application Support/ClipDune Publisher/signing.key`，权限 `0600`。公钥在 `Resources/UpdatePublicKey.txt`。私钥不可提交、不可上传 Release、不可输出到终端；请通过自己的安全备份流程备份。

```bash
# 初次初始化；已有公钥不匹配时拒绝覆盖
swift run ClipDuneReleaseTool keygen \
  --private-key "$HOME/Library/Application Support/ClipDune Publisher/signing.key" \
  --public-key Resources/UpdatePublicKey.txt

# 修改 Resources/Info.plist 的版本和构建号，并准备对应更新说明
bash scripts/check.sh
bash scripts/check-ui.sh development
bash scripts/release.sh prepare

# 可先上传私有草稿并用原生下载器验证，不对客户端开放
bash scripts/release.sh draft

# 代码验证、提交、推送后创建私有 Release 并发布为 latest
bash scripts/release.sh publish
```

`prepare` 编译 Universal 主程序与辅助程序，生成签名 ZIP，再分别提取 arm64 和 x86_64 切片、重新签名并制作 DMG。两种 DMG 都执行只读挂载、版本、公钥、安装入口、单架构和代码签名检查。构建与草稿不把静态检查表述为运行验收。

`draft` 检查工作区干净、远端 main 与 HEAD 一致、仓库私有，上传五个资产；通过应用共用的原生下载器校验 ZIP，再下载两个 DMG 与校验文件，核对 SHA-256 并重新挂载检查。`publish` 还要求 Universal Release 应用包 GUI 检查通过，并在上传前及下载后运行本机架构 DMG 内的安全图标渲染启动检查；任一步失败都不能切换正式 Release。已有同名版本会失败，不会覆盖资产；实际工作中选择 draft 或 publish 其中一条创建路径。草稿晋升前必须重跑上述运行检查，不能仅凭静态校验手动发布。最终上传构建与源码版本保持一致。

单独编译 Universal 应用可运行 `bash scripts/build.sh release universal`；GUI 验证命令为 `CLIPDUNE_UI_CONFIGURATION=release CLIPDUNE_BUILD_ARCHITECTURE=universal bash scripts/check-ui.sh bundle`。交叉编译、架构检查和 Apple Silicon 本机运行不等于 Intel 实机运行验收。

可通过 `CLIPDUNE_SIGN_IDENTITY` 指定自己的合法代码签名身份。未指定时只是 ad-hoc 开发签名，不是 Developer ID，也不是公证。Ed25519 更新签名与 Apple 代码签名承担不同职责，不能互相替代。

私钥丢失后不能随意换公钥继续推送；没有合法旧签名链的情况下需要用户手动安装带新公钥的版本。

## 当前验收边界

签名、篡改拒绝、哈希、大小、架构、来源限制、原子替换与失败回滚有自动化测试。0.2.0 Release 应用包 GUI 测试通过；真实旧应用退出、新应用启动确认的完整用户升级尚未整链路验收。更新器不会关闭 Gatekeeper、企业防护或任何系统安全策略；不要把下载成功或磁盘签名通过等同于升级后的程序实际运行成功。

Mac App Store 发行将来应单独使用商店更新渠道，不在该渠道内直接替换自身。当前版本面向自用的独立分发。
