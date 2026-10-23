# Cooper

把 Cloudflare R2（或其他 S3 兼容）存储桶挂载到 macOS Finder。基于 Apple File Provider 框架（`NSFileProviderReplicatedExtension`），挂载后 Finder 侧栏「位置」里出现一个 **Cooper**（本地路径 `~/Library/CloudStorage/Cooper-CooperDrive`，下文称 CooperDrive），每个存储桶是其中一个子文件夹：可以浏览目录，打开文件时按需下载，拖入文件即上传。

当前版本：0.1.0（原型）

## 功能

| Finder 操作 | 对应的 S3 行为 |
|---|---|
| 浏览文件夹 | `ListObjectsV2`（`delimiter=/`），每页最多 1000 项，自动翻页 |
| 打开文件 | `GET` 下载到本地，之后由系统缓存 |
| 拖入 / 复制文件 | 不超过 32 MB 单次 `PUT`，更大的分片上传；同名对象已存在时 Finder 会把新文件改名为「xxx 2」 |
| 编辑并保存已打开的文件 | 整个文件重新上传覆盖 |
| 新建文件夹 | 上传一个以 `/` 结尾的空对象占位，空文件夹也能保留 |
| 改名、在同一个存储桶里移动 | 服务端复制到新 key 再删除旧的；文件夹会处理前缀下的每个对象 |
| 删除文件或文件夹 | `DELETE` / 批量删除远端对象，不经过废纸篓 |
| 拖到另一个存储桶 | 暂不支持，文件会弹回原位 |

CooperDrive 根目录下只能放存储桶文件夹。存储桶文件夹本身不能在 Finder 里改名、移动或删除，要在 App 里管理连接。

Finder 和 Office 产生的系统文件不会上传：`.DS_Store`、`.localized`、`._*`、`~$*`、`Icon\r`。

## 环境要求

- macOS 14 或更高版本
- Xcode（Swift 6），装好后打开一次完成初始化，并切换命令行工具：
  ```bash
  sudo xcode-select -s /Applications/Xcode.app
  ```
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：Xcode 工程由 `project.yml` 生成
  ```bash
  brew install xcodegen
  ```
- 一个 Apple ID（免费账号即可），在 Xcode → Settings → Accounts 登录。File Provider 扩展必须用带 Team ID 的证书签名，「Sign to Run Locally」不行

## 目录结构

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程定义：两个 target、Info.plist 键值、权限（entitlements） |
| `Config/Signing.xcconfig` | 签名设置（`DEVELOPMENT_TEAM`、`CODE_SIGN_STYLE`） |
| `App/` | SwiftUI 主程序：主窗口里有首页（存储桶列表）、文件浏览（上传下载、预览、分享）、存储占用、传输和设置页（管理存储桶连接和 CooperDrive 挂载）；常驻菜单栏，显示挂载状态和文件操作记录；运行时每分钟提醒扩展检查远端变化 |
| `FileProvider/` | File Provider 扩展：列举、下载、上传、改名/移动、删除（含文件夹）、轮询远端变化，并记录 Finder 里的操作 |
| `Shared/` | 主程序和扩展共用：连接配置、同步记录和操作记录（App Group 容器）、访问密钥（钥匙串） |
| `Packages/S3Kit/` | Swift Package。`S3Kit`：精简 S3 客户端（SigV4、列举、分片上传、服务端复制、批量删除）；`SyncCore`：挂载的同步记录（稳定标识、变化序号、轮询差异）；附带 `s3probe` 命令行工具和单元测试 |
| `scripts/s3probe.sh` | 不经过 SwiftPM，直接用 `swiftc` 编译并运行 `s3probe` |

`Cooper.xcodeproj`、`App/Info.plist`、`FileProvider/Info.plist` 和两个 `.entitlements` 文件都由 `xcodegen generate` 生成，不要手改，改 `project.yml` 后重新生成。

## 快速开始

1. 编辑 `Config/Signing.xcconfig`，把 `DEVELOPMENT_TEAM` 改成你自己的 Team ID（10 位字母数字，在 Xcode 的 Accounts 页面或开发者网站可以查到）。改签名不需要重新生成工程。
2. 生成并打开工程：
   ```bash
   xcodegen generate && open Cooper.xcodeproj
   ```
3. 在 Xcode 里选择 `Cooper` scheme 运行。
4. 打开后先看到首页。点「添加存储桶」（或 ⌘N），选择服务商并填写连接参数（见下节），点「测试连接」。
5. 测试通过后点「添加连接」，面板关闭并直接打开这个存储桶。第一个存储桶添加后会自动挂载 CooperDrive，在 Finder 侧栏「位置」里点「Cooper」打开，或点首页横幅、设置页里的「在 Finder 中打开」。Finder 侧栏显示的是 App 名，不是 CooperDrive。再添加的存储桶会作为新的子文件夹出现。

## 主窗口

应用图标位于 `App/Assets.xcassets/AppIcon.appiconset`，包含 macOS 的 16、32、128、256、512 pt 的 1x / 2x 图片；`project.yml` 中通过 `ASSETCATALOG_COMPILER_APPICON_NAME` 指定为 `AppIcon`，构建时供 Dock、Finder 和系统“关于”窗口使用。

当前采用 V2「折叠的 C」Logo，配色为亮靛蓝与暖杏橙。侧栏、首页欢迎区域和设置页使用 `CooperMark.imageset`，提供浅色、深色外观的 1x / 2x 图片，两种外观均保留蓝橙品牌色。正式设计源图与完整素材包保存在 `output/imagegen/v2/`；应用资源是项目内的独立副本，运行时不依赖这个设计输出目录。

更新 V2 源图后，运行 `python3 scripts/update-brand-assets.py`（需要 Pillow）即可重新导出 AppIcon、CooperMark、菜单栏模板图标 MenuBarIcon（由单色版 `cooper-v2-mono.png` 生成）及 `output/imagegen/v2/Cooper.icns`。

所有页面都在一个主窗口里，左边侧栏从上到下是：

| 侧栏 | 内容 |
|---|---|
| Cooper（App 标志） | 首页，打开 App 时显示。顶部是 Finder 挂载状态，下面每行一个存储桶：服务商图标、名称、桶名、Endpoint、已统计的占用；点一行进入，右键或「…」可以编辑、复制、移除、在 Finder 中打开、查看存储占用 |
| 存储桶 | 每个存储桶一项，点开是文件列表；段标题右边的「+」添加存储桶 |
| 传输（固定在左下角） | 上传和下载的进度，可以取消；有进行中的任务时右边显示数量 |
| 设置（固定在左下角） | 管理存储桶连接、挂载 / 刷新 / 卸载 CooperDrive、版本信息。不再单独开窗口，⌘, 也会跳到这一页 |

存储占用不在侧栏里：在存储桶上点右键（侧栏、首页、设置页都可以）选「查看存储占用」。页面会统计总大小、对象数、按文件夹和文件类型的分布、最大的文件，统计要列出整个存储桶，只在点「开始统计」时进行；右上角可以切换存储桶，或点「浏览文件」回到文件列表。

添加、编辑和复制存储桶都在从主窗口顶部滑出的面板里完成。「复制连接…」会带上原连接的服务商、Endpoint、区域、访问密钥和公开域名，名称变成「xxx 副本」，改一下存储桶名就能保存，适合同一个账号下的多个存储桶；如果没改桶名，面板会提示已有连接指向同一个存储桶。

文件列表上方是路径（每一级都可以点）和统计（如「2 项，208 MB」），右边是类型筛选、排序、筛选框、列表 / 图标切换和刷新。列表和 Finder 一样是名称、修改日期、大小、种类四列（种类是系统的描述，如「ZIP 归档」），小图标、斑马纹；修改日期一周内显示为「16 小时前」这样的相对时间。图标视图的选中样式也和 Finder 一致。类型筛选菜单按文件夹、图片、视频、音频、文档、代码、压缩包和其他分类。

| 操作 | 方式 |
|---|---|
| 进入文件夹 / 预览文件 | 双击；选中文件后按空格用 Quick Look 预览（先下载到缓存，同一版本只下载一次） |
| 前进、后退、回到上级 | 工具栏的箭头，或点上方路径里的任意一级 |
| 排序、筛选 | 点列标题或「排序」菜单（文件夹始终在前）；类型菜单只显示某一类；⌘F 跳到筛选框，只筛当前文件夹，Esc 清空 |
| 上传 | 把文件或文件夹拖进列表，或点工具栏的「上传」选择；文件夹会保留目录结构 |
| 下载、移动、分享、删除 | 选中后统计位置变成操作条，也可以用右键菜单；按 Delete 键删除，删除前会确认 |
| 新建文件夹、重命名 | 工具栏的「新建文件夹」或右键菜单 |
| 分享 | 生成 1 小时 / 1 天 / 7 天有效的预签名链接；配置了公开域名时也可以拷贝公开链接 |

上传和下载的进度在「传输」里，可以取消。在主窗口里做的改动会通知 Finder 挂载尽快刷新。

挂载失败并提示找不到 provider 时，把编译出的 `Cooper.app` 拷到「应用程序」文件夹再运行。

## 菜单栏

Cooper 常驻菜单栏。关掉主窗口后 App 不退出：Dock 图标消失，只留菜单栏图标，挂载的定时提醒照常运行；要退出用菜单栏面板「…」里的「退出 Cooper」。设置页「通用」里可以：

- 打开「登录时启动」：登录 Mac 后自动运行，只出现在菜单栏，不弹主窗口（系统要求允许时，按提示到「系统设置 → 通用 → 登录项」里打开）
- 关掉「关闭主窗口后隐藏 Dock 图标」：关窗后 Dock 图标也保留

菜单栏图标是 Cooper 标志，右下角的角标表示状态：转圈箭头是有操作在进行，感叹号是最近 24 小时里有操作失败；没挂载时图标变淡。

点图标打开面板：

| 位置 | 内容 |
|---|---|
| 顶部 | 挂载状态（已挂载 · N 个存储桶 / 正在同步 N 项 / N 项操作失败 / 未挂载），有上传时显示总进度；右边是「在 Finder 中打开」和「…」菜单（立即刷新、打开 Cooper、设置、清除记录、退出） |
| 筛选 | 全部 / 进行中 / 失败；有多个存储桶时右边可以只看一个 |
| 列表 | 按今天、昨天、过去 7 天、更早分段。每行是文件图标加操作角标（上传、修改、新建文件夹、重命名、移动、删除），角标橙色表示失败；下面一行是操作、大小、时间和所在位置，主窗口里做的带「Cooper」标签。失败的显示原因和尝试次数 |
| 底部 | 打开 Cooper、有传输时的「传输 N」、设置 |

列表只记录**改变存储桶内容的操作**：Finder 里的上传（拖入、复制、新建）、修改保存、新建文件夹、改名、移动、删除，以及主窗口里的上传、新建文件夹、改名、移动、删除。打开文件时的下载、主窗口的下载、轮询发现的远端变化都不记录。挂载未开启时面板只显示挂载按钮。

几条记录会合并成一行：在 Finder 里拖入一个文件夹，显示为「photos · 上传文件夹 · 32 个文件，1.2 GB」；同一个文件夹里 5 分钟内连续的同类操作显示为「上传了 5 个文件」「删除了 3 项」；同一个文件反复保存显示为「修改了 3 次」。合并的行点一下展开明细。进行中和失败的操作不合并。

单条记录点一下在 Finder 里选中它（已删除的除外），右键还可以「在 Cooper 中显示」（主窗口打开对应文件夹并选中）、拷贝 1 天有效的分享链接、拷贝路径。系统自动重试失败的操作时沿用同一条记录，只增加尝试次数。被拒绝的操作也会记录原因，比如把文件拖到另一个存储桶时显示「不能移到其他存储桶，已放回原处」。

记录最多保留 1000 条、30 天。「清除记录」、卸载 CooperDrive 后，之前的记录不再显示；移除连接后它的记录也不再显示。

## 连接参数

| 字段 | 说明 |
|---|---|
| 服务商 | 决定表单的默认值和提示，右边的「连接教程」打开服务商创建访问密钥的说明 |
| 连接名称 | CooperDrive 里的子文件夹名，重名时自动加序号 |
| S3 API Endpoint | 服务地址，不含存储桶名。粘贴 R2 控制台里带存储桶名的地址时，存储桶会自动拆出来 |
| 存储桶 | 存储桶名 |
| 区域 | 签名用的区域，留空时用服务商的默认值 |
| 路径式地址 | 只有 MinIO 和「其他」显示这个开关。开启时请求地址为 `endpoint/bucket/key`，关闭时为 `bucket.endpoint/key` |
| Access Key ID / Secret Access Key | 访问密钥，保存在钥匙串里 |
| 公开域名 / 自定义域名 | 可选，用于拷贝长期有效的公开链接 |

各服务商的预设（按区域生成 Endpoint 的服务商，改区域时 Endpoint 跟着变，手动改过就不再自动改）：

| 服务商 | Endpoint | 默认区域 | 路径式地址 |
|---|---|---|---|
| Cloudflare R2 | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` | `auto` | 开启 |
| Amazon S3 | `https://s3.<region>.amazonaws.com` | `us-east-1` | 关闭 |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | `us-west-004` | 开启 |
| Wasabi | `https://s3.<region>.wasabisys.com` | `us-east-1` | 开启 |
| MinIO | 你的 MinIO 地址 | `us-east-1` | 开启（可改） |
| Alibaba Cloud OSS | `https://s3.oss-<region>.aliyuncs.com` | `cn-hangzhou` | 关闭 |
| Tencent Cloud COS | `https://cos.<region>.myqcloud.com` | `ap-guangzhou` | 关闭 |
| 其他兼容 S3 的服务商 | 服务商提供的地址 | `us-east-1` | 开启（可改） |

旧版本保存的连接没有记录服务商，按 Endpoint 的域名识别，识别不出算「其他」。

R2 的访问密钥在 Cloudflare 控制台 R2 → 管理 API 令牌中创建，权限选「对象读和写」，建议限定到测试桶。原型主要针对 R2 验证。

修改连接后点「保存」，扩展会自动读取新配置，换了存储桶的话对应文件夹会重新加载。「移除」只删除连接和本机缓存，存储桶里的数据不受影响。设置页「Finder 挂载」里的「卸载」会移除整个 CooperDrive 和所有本机缓存。

从旧版本（每个存储桶单独挂载）升级时，App 启动后会自动移除旧的挂载并挂载 CooperDrive，本机缓存需要重新下载。

## 工作原理

### 进程和数据共享

主程序和 File Provider 扩展是两个独立的沙盒进程，通过两处共享数据：

- **连接配置**（不含密钥）：以 JSON 数组存在 App Group 容器的 `connections.json` 里（旧版本的 `connection.json` 会自动迁移）。App Group 为 `<TeamID>.app.getcooper`
- **访问密钥**：存在数据保护钥匙串里，放进共享钥匙串组 `<AppIdentifierPrefix>app.getcooper.shared`

这两个标识在构建时由 `project.yml` 写入各自 Info.plist 的 `CooperAppGroupIdentifier` 和 `CooperKeychainAccessGroup` 键，代码在运行时读取。

菜单栏的操作记录也在 App Group 容器里，目录是 `Activity/`：扩展写 `finder.json`，主程序写 `app.json`，每个进程只写自己的文件（写盘合并 0.5 秒，原子写入）。主程序监听这个目录，有变化就重新读取两份记录合并显示。「清除记录」不改文件，只在 App Group 的偏好设置里记一个时间，之前结束的记录不再显示。

### S3 key 和 Finder 项目的对应

| Finder 项目 | File Provider 标识 |
|---|---|
| 根目录 | `.rootContainer`，对应空前缀 |
| 文件夹 | 以 `/` 结尾的前缀，如 `photos/2025/` |
| 文件 | 对象 key，如 `photos/2025/a.jpg` |

文件的版本号使用 ETag；没有 ETag 时用「大小 + 修改时间」代替。

### 同步策略

- S3 没有增量变更接口，扩展在被问到变化时报告锚点已过期，系统会重新完整列举该文件夹，并自行算出哪些项被删除
- 原型没有轮询，远端的变化不会自动出现，要在 App 里点「刷新」，让系统重新读取整个存储桶
- S3 错误映射为 File Provider 错误：HTTP 401/403 → 未认证，404 → 不存在，其他 HTTP 错误和网络错误 → 服务器不可达

## 测试

S3Kit 的单元测试使用 Swift Testing，覆盖 SigV4 签名（用 AWS 文档里的公开示例校验）、URL 编码、路径式和虚拟主机式地址、列举结果和错误响应的 XML 解析：

```bash
cd Packages/S3Kit && swift test
```

## 不用 Xcode 工程，直接验证 S3 客户端

`s3probe` 用真实存储桶联调 S3Kit。连接参数从环境变量读取：

```bash
export S3_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com S3_BUCKET=<桶名> S3_ACCESS_KEY_ID=<ID>
read -s "S3_SECRET_ACCESS_KEY?Secret: " && export S3_SECRET_ACCESS_KEY
scripts/s3probe.sh ls
```

可选的 `S3_REGION` 默认为 `auto`。`s3probe` 固定使用路径式地址。

支持的命令：

| 命令 | 作用 |
|---|---|
| `ls [PREFIX]` | 列出前缀下的文件夹和文件 |
| `head KEY` | 查看对象的大小、ETag、类型、修改时间 |
| `get KEY 本地文件` | 下载对象 |
| `put 本地文件 KEY` | 上传文件，超过 32 MB 自动分片上传 |
| `cp 源KEY 目标KEY` | 服务端复制，超过 5 GB 自动分片复制 |
| `rm KEY` | 删除对象 |
| `rmr PREFIX` | 批量删除前缀下的所有对象，不可撤销 |

`scripts/s3probe.sh` 直接调用 `swiftc` 编译到 `.build/s3probe/`，源码有改动时才重新编译。也可以用 SwiftPM 运行：

```bash
cd Packages/S3Kit && swift run s3probe ls
```

## 打包 DMG

运行 `bash scripts/package-dmg.sh`，使用现有团队签名构建 Release 通用版本（Apple 芯片与 Intel），并输出 `output/releases/Cooper-macOS.dmg` 和 SHA-256 文件 `Cooper-macOS.dmg.sha256`。构建日志保存在 `.build/dmg-release-build.log`。已构建的应用也可以直接传给脚本：`bash scripts/package-dmg.sh /绝对路径/Cooper.app`。

镜像包含 Cooper.app、“应用程序”快捷方式与安装说明；脚本会校验主程序和 File Provider 扩展签名、只读挂载检查镜像，再卸载。文件名固定，再次打包会替换上一次的 DMG 和校验文件，版本号和架构打印在脚本最后一行。脚本不执行 Apple 公证；当前个人团队的 Apple Development 签名用于已配置的开发设备，公开分发需要另行配置相应签名、描述文件与公证。

## 调试

查看扩展的日志（subsystem 为 `app.getcooper`，category 为 `FileProvider`）：

```bash
log stream --predicate 'subsystem == "app.getcooper"' --level debug
```

查看系统里 File Provider 的状态：

```bash
fileproviderctl dump
```

改完扩展代码重新运行后，系统可能还在用旧的扩展进程。结束它，下次访问挂载目录时会加载新版本：

```bash
pkill -f CooperFileProvider
```

## 常见问题

**保存密钥时报钥匙串错误 -34018**
共享钥匙串组需要描述文件。确认使用自动签名（`CODE_SIGN_STYLE = Automatic`）并已在 Xcode 登录 Apple ID，只配置 App Group 是不够的。

**挂载时提示找不到 provider**
把 `Cooper.app` 拷到「应用程序」文件夹再运行。

**改了扩展代码但行为没变**
执行 `pkill -f CooperFileProvider`，见「调试」一节。

## 远端变化怎么同步

S3 没有变更通知，只能轮询：

- 只轮询在 Finder 里打开过的文件夹。一个文件夹连续没有变化，检查间隔从 1 分钟逐步拉长到 15 分钟；发现变化或本地改过，就回到 1 分钟。
- 扩展运行时自己每分钟检查一次到期的文件夹；扩展被系统结束后，靠主程序运行时的定时提醒唤醒（主程序关掉窗口后留在菜单栏，提醒照常）。主程序退出、扩展也没在跑时，远端变化要等下次访问挂载目录才会出现。
- 主程序里的「刷新」会立即检查所有打开过的文件夹。
- 同步记录存在 App Group 容器的 `Sync/` 目录里，卸载或重新挂载时清空。

## 还没做

- 断点续传：上传中断后整个文件重传
- 冲突处理：两边同时修改同一个文件时，后写入的覆盖先写入的
- 废纸篓：删除即删除远端对象
- 退出主程序后：轮询频率依赖系统何时运行扩展（关掉窗口不影响，App 留在菜单栏）
- 系统通知：操作失败或远端有新文件时还不会发通知
- 菜单栏不记录远端变化和下载
