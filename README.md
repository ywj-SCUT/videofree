# VideoGET

VideoGET 是一个本地优先的 Windows 与 Android 影视聚合、解析和播放应用。它可以统一接入 CMS、TVBox 和 Spider 点播来源，完成媒体库浏览、跨源搜索、同名内容聚合、线路与选集切换、短视频浏览、收藏、观看记录和断点续播。

应用不要求部署后端服务。Windows 端在 Electron 主进程内运行来源引擎、本地 HLS 代理和磁盘缓存；Android 端使用 Flutter 实现同类来源解析，并通过基于 mpv 的 `media_kit` 直接播放。

## 下载与版本

当前版本：`v0.0.3`

| 平台 | 版本 | 系统要求 | 下载 |
| --- | --- | --- | --- |
| Windows x64 | `0.0.3` | Windows 10/11 64 位 | [下载安装包](https://github.com/ywj-SCUT/videofree/releases/download/v0.0.3/VideoGET-Setup-0.0.3-x64.exe) |
| Android | `0.0.3+3` | Android 5.0（API 21）及以上 | [下载 APK](https://github.com/ywj-SCUT/videofree/releases/download/v0.0.3/VideoGET-Android-v0.0.3.apk) |

版本说明和附件见 [GitHub Releases](https://github.com/ywj-SCUT/videofree/releases/tag/v0.0.3)。仓库中的本地构建产物位于 `release` 目录，该目录不纳入 Git 版本管理。

## 主要功能

### 媒体库与来源聚合

- 聚合电影、电视剧、动漫和其他点播内容。
- 按片库、类型、关键词和年份筛选，并支持片名等排序方式。
- 合并不同来源中的同名内容，在详情页统一展示线路和剧集。
- 支持苹果 CMS API、TVBox JSON 配置以及受支持的 Spider 规则。
- 桌面端和 Android 端均在本机完成搜索、解析与播放，不依赖电脑中转或远程 VideoGET 服务。

### 播放与画质

- 支持 HLS、MP4 等常见网络媒体流以及来源要求的自定义请求头。
- 支持自动、最高、1080P 和 720P 画质偏好，最终可用画质由内容源决定。
- 支持线路切换、选集、倍速、画中画、全屏和弹幕。
- 自动保存当前剧集、线路和播放进度，可从观看记录继续播放。
- Android 播放器在固定画质持续缓冲时会尝试降到较低画质或自动画质。

### v0.0.3 长视频缓存与预取

Windows 端：

- HLS 播放开始后在后台解析播放列表，并使用 4 个并发任务预取分片。
- 视频分片写入 Electron 用户数据目录中的 `video-cache`，磁盘缓存上限为 2 GB。
- 超过上限时按最近最少使用顺序清理到约 1.8 GB，避免缓存持续增长。
- 支持常见 TS、M4S、AAC、MP4、字幕和密钥分片，单个缓存对象上限为 100 MB。
- HLS.js 默认保留 60 秒前向缓冲，允许扩展到 120 秒，内存缓冲上限为 128 MB，并增加分片重试和网络超时容忍度。
- 已经缓存的分片会直接从磁盘读取；未命中时边播放边下载，并在完成后异步落盘。

Android 端：

- mpv 缓存时长配置为 24 小时，前向预读窗口为 20 分钟。
- 解复用缓冲上限为 512 MB，流读取缓冲为 2 MB，网络超时为 60 秒。
- 已缓存范围内的拖动和重复播放更快；实际预读量仍受设备内存、系统限制、来源和网络速度影响。

这些策略会增加网络流量、磁盘占用或内存占用。移动网络下播放长视频时请留意流量消耗。

### 短视频

- 提供上下滑动和自动播放的沉浸式短视频信息流。
- 通过 TikHub 接入 TikTok、抖音和 YouTube Shorts 平台作品。
- 平台短视频与 CMS 短剧分类隔离。
- 支持分页加载、播放地址解析、收藏和详情查看。

### 本地数据

- 收藏、观看记录、播放进度、来源和画质设置保存在当前设备。
- Windows 与 Android 的本地数据相互独立，目前不自动同步。
- 卸载应用或清除应用数据前，请先确认是否需要保留本地记录和配置。

## 使用方法

### Windows

1. 下载并运行 `VideoGET-Setup-0.0.3-x64.exe`。
2. 按安装向导完成安装，然后启动 VideoGET。
3. 在“片库”浏览内容，或使用搜索功能查找片名。
4. 点击海报进入详情页，选择线路和剧集后开始播放。
5. 在播放器设置中切换画质、线路、选集、倍速或弹幕状态。
6. 从“收藏”和“观看记录”继续之前的内容。

播放 HLS 内容时，缓存和预取会自动运行，不需要手动启动。首次播放仍取决于来源响应速度，已缓存分片在后续访问时会优先复用。

### Android

在手机上允许当前文件管理器或浏览器“安装未知应用”，然后打开下载的 `VideoGET-Android-v0.0.3.apk` 完成安装。升级已有版本时直接安装新 APK，不要先卸载旧版本；只有新 APK 与已安装版本使用相同应用 ID 和签名时，Android 才能保留应用数据并覆盖更新。

也可以通过已连接的电脑覆盖安装：

```powershell
adb devices
adb install --no-streaming -r .\release\VideoGET-Android-v0.0.3.apk
```

安装后：

1. 从“片库”浏览或搜索影视内容。
2. 进入详情页，选择线路和剧集后播放。
3. 从底部导航进入“短视频”，上下滑动浏览作品。
4. 在详情页或短视频页收藏内容。
5. 从“收藏”页查看收藏和观看记录。
6. 在“设置”中管理来源、TVBox 配置、TikHub Key 和播放画质。

## 配置内容来源

### 添加 CMS 来源

在“设置 > 视频来源”中填写来源名称和 CMS API 地址后保存。桌面端可以点击“检测”查看连通性和响应时间。

常见地址格式：

```text
https://example.com/api.php/provide/vod/
```

### 导入 TVBox 配置

- Windows：导入本地 JSON/TXT 文件，或填写远程配置 URL。
- Android：导入本地 JSON 文件，或填写远程配置 URL。
- 导入后可以分别启用、停用或删除非内置来源。

TVBox 支持 `type=1` CMS 来源和项目已适配的 `type=3` Spider 规则。Spider 脚本可以内联保存，也可以从远程地址加载。

## 配置短视频平台

TikTok、抖音与 YouTube Shorts 来源默认关闭，需要先配置 TikHub API Key：

1. 前往 [TikHub 注册页](https://user.tikhub.io/register) 创建账号并登录。
2. 打开 [TikHub API 控制台](https://user.tikhub.io/dashboard/api)。
3. 创建并复制 API Key，确认账号有可用额度。
4. 在 VideoGET 中打开“设置 > 短视频平台 API”。
5. 粘贴纯 API Key，然后点击“保存并启用”。
6. 返回“短视频”页刷新信息流。

输入时不要添加 `Bearer `，应用会自动生成 `Authorization: Bearer <API_KEY>` 请求头。Key 仅保存在当前设备的本地设置中，不要把它提交到仓库或公开日志。

- [TikHub API 文档](https://docs.tikhub.io/)
- [TikHub API 状态](https://monitor.tikhub.io/)

## 实现原理

### Windows 桌面端

Windows 客户端由 Electron、React、TypeScript、ArtPlayer 和 HLS.js 构成：

1. `src` 中的 React 界面通过 `electron/preload.cts` 暴露的受限 IPC API 调用主进程能力。
2. `electron/source-engine.ts` 读取 CMS 和 TVBox 来源，标准化搜索结果、详情、线路和剧集，再对同名内容进行聚合。
3. `electron/rule-engine.ts` 负责执行受支持的 TVBox/Spider 规则；`electron/short-video-engine.ts` 负责 TikHub 平台请求和播放地址解析。
4. `electron/proxy-server.ts` 在本机随机端口启动代理，转发播放请求头、重写 HLS 播放列表、过滤可识别的广告分片，并将分片请求接入缓存。
5. `electron/video-cache.ts` 使用原始 URL 的 SHA-256 作为缓存键，并通过临时文件和重命名完成原子写入。无 Range 请求下符合条件的上游 HTTP `200` 或 `206` 响应可以进入缓存，响应头 `X-VideoGET-Cache` 标记 `HIT` 或 `MISS`。
6. `electron/prefetch-manager.ts` 获取主播放列表和一层子播放列表，提取分片 URL 后以 4 个 worker 并发预取。进度通过 IPC 发送给渲染进程。

本地代理还提供内部的 `/prefetch` 和 `/cache-stats` 端点；缓存统计、清理和预取控制通过 `cache:*`、`prefetch:*` IPC 通道连接到应用。它们属于应用内部实现，不需要用户手动访问。

### Android 客户端

Android 客户端由 Flutter、Dart、`media_kit` 和 mpv 构成：

1. `mobile/lib/services/source_engine.dart` 在设备本地请求和聚合 CMS/TVBox 内容。
2. `mobile/lib/services/spider_engine.dart` 负责受支持的 Spider 规则加载与调用。
3. `mobile/lib/services/short_video_engine.dart` 访问 TikHub API，并缓存短时解析结果以减少重复请求。
4. `mobile/lib/screens/player_screen.dart` 在打开媒体前设置 mpv 缓冲、预读、超时和可拖动缓存参数，再应用请求头、断点位置、倍速和画质轨道。
5. 收藏、历史、进度和设置通过本地存储保存在 Android 设备上。

### 数据流

```text
用户操作
  -> 本地来源引擎（CMS / TVBox / Spider / TikHub）
  -> 标准化内容、线路与剧集
  -> 播放地址和请求头解析
  -> Windows 本地 HLS 代理与磁盘缓存 / Android mpv 缓冲
  -> ArtPlayer + HLS.js / media_kit + mpv
```

## 源码开发

### Windows 桌面端

环境要求：Windows 10/11 x64、Node.js 20 或更高版本、npm。

```powershell
npm install
npm run typecheck
npm run dev
```

`npm run dev` 会启动 Vite 和 Electron 桌面窗口。Web 开发预览命令为：

```powershell
npm run web:dev
```

默认地址为 `http://127.0.0.1:3000`。

构建 Windows 安装包、便携版和解包目录：

```powershell
npm run typecheck
npm run dist
```

主要输出：

```text
release/VideoGET-Setup-<version>-x64.exe
release/VideoGET-Portable-<version>-x64.exe
release/win-unpacked/VideoGET.exe
```

### Android 客户端

环境要求：Flutter SDK、JDK 17、Android SDK、Platform Tools，以及满足 `>=3.12.2 <4.0.0` 的 Dart SDK。

Windows 中文用户目录可能影响部分 JNI/CMake 依赖解析，建议把 `PUB_CACHE` 设置到纯 ASCII 路径：

```powershell
$env:PUB_CACHE = 'D:\flutter-pub-cache'
Set-Location .\mobile
flutter pub get
flutter analyze
flutter test
flutter run
```

构建 Release APK：

```powershell
$env:PUB_CACHE = 'D:\flutter-pub-cache'
Set-Location .\mobile
flutter build apk --release
```

输出文件为 `mobile/build/app/outputs/flutter-apk/app-release.apk`。发布时可复制并按版本命名为 `release/VideoGET-Android-v<version>.apk`。

### Android 签名与升级

Android 通过应用 ID 和签名证书共同确认更新关系。同一应用的后续版本必须持续使用同一把签名密钥；正常发布不会每个版本更换签名。密钥变化后，系统会把新 APK 视为签名不匹配，不能直接覆盖已安装版本。

当前 `v0.0.3` APK 为了兼容已有 `v0.0.2` 安装，继续使用同一调试密钥签名。正式、长期分发时应配置专用 release keystore，妥善备份密钥和密码，并确保所有后续版本都使用它；切换到新密钥前需要评估现有安装用户的升级路径。

### 网络代理

依赖下载直连失败时，可以为当前 PowerShell 会话使用本机 `7890` 代理，并绕过 Flutter 本地测试服务：

```powershell
$env:HTTP_PROXY = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
$env:NO_PROXY = '127.0.0.1,localhost,::1'
$env:no_proxy = $env:NO_PROXY
$env:GRADLE_OPTS = '-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7890 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7890 -Dorg.gradle.daemon=false -Dorg.gradle.parallel=false'
```

设置前先确认 `127.0.0.1:7890` 正在监听。

## 质量检查

桌面端：

```powershell
npm run typecheck
npm run smoke:phase1
```

Android：

```powershell
Set-Location .\mobile
flutter analyze
flutter test
```

完整 Flutter 测试中的 QuickJS Spider 原生运行时用例只在 Android 真机执行，在桌面测试环境会跳过。

## 项目结构

```text
videofree/
|- electron/       Electron 主进程、本地代理、缓存、来源与短视频引擎
|- src/            Electron React 界面
|- web/            Next.js Web 开发入口
|- mobile/         Flutter Android 客户端
|- scripts/        构建与冒烟测试脚本
|- tests/          桌面端测试资源
|- public/         桌面端图标和静态资源
`- README.md       项目说明
```

## 常见问题

### Android 提示签名不一致，不能覆盖安装

确认新旧 APK 的应用 ID 和签名证书一致。不要先卸载仍需保留数据的旧版本。开发环境中还要确认构建使用的是原版本对应的 keystore，而不是另一台电脑新生成的调试密钥。

### Windows 播放占用较多磁盘空间

`v0.0.3` 会自动预取 HLS 分片并使用最多约 2 GB 视频缓存。达到上限后应用会自动清理较旧的分片，不会无限增长。

### Android 播放占用较多流量或内存

Android 播放器采用较积极的预读和较大的 mpv 缓冲。移动网络下建议留意流量；内存紧张时，Android 可能根据系统资源限制实际缓冲量。

### 短视频页没有内容

确认 TikHub Key 已保存、平台来源处于启用状态，并检查账号额度和 [TikHub API 状态](https://monitor.tikhub.io/)。Key 输入框只填写原始 Key，不包含 `Bearer ` 前缀。

### 短视频显示“重试播放”

刷新短视频页并切换其他作品。如果多条作品都失败，检查设备网络、TikHub Key、平台接口状态和媒体地址是否已过期。

### 内容源搜索失败

确认来源已启用，并且 API 地址可以从当前设备访问。Windows 端可在设置页点击“检测”；Android 端可以停用异常来源后重新搜索。

### Android 构建长时间停在 `assembleRelease`

首次构建需要下载 Gradle、Android 和 Flutter 依赖。检查网络、磁盘空间和代理状态，并避免同时运行多个 Gradle 构建。

### Flutter 测试连接本机端口失败

代理可能转发了 Flutter 测试进程的本地 HTTP 连接。设置以下变量后重新执行 `flutter test`：

```powershell
$env:NO_PROXY = '127.0.0.1,localhost,::1'
$env:no_proxy = $env:NO_PROXY
```

## 数据与内容说明

- VideoGET 不托管视频文件，播放内容来自用户配置或应用启用的第三方来源。
- 来源可用性、内容完整性、清晰度和访问速度由对应服务决定。
- 用户应自行确认内容来源和平台 API 的使用条件。
- API Key、签名密钥和其他凭据不应提交到仓库或写入公开日志。
