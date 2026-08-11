# VideoGET

VideoGET 是一个本地优先的多端影视聚合与播放应用，提供 Windows 桌面端和 Android 客户端。两端都可以聚合 CMS、TVBox 与 Spider 点播来源，浏览媒体库、搜索内容、切换线路和选集，并在本机保存收藏与观看记录。

Android 客户端使用本地引擎直接完成搜索、解析和播放，不需要连接电脑或部署远程服务。

## 支持平台

| 平台 | 技术栈 | 当前版本 | 运行方式 |
| --- | --- | --- | --- |
| Windows 桌面端 | Electron、React、TypeScript、ArtPlayer、HLS.js | `0.1.0` | 安装版或便携版 |
| Android | Flutter、Dart、media_kit | `1.0.0+1` | APK 安装 |
| Web 开发预览 | Next.js、React | 与桌面端共享核心能力 | 本地开发服务器 |

## 主要功能

### 媒体库与搜索

- 中文深色界面，桌面端和 Android 端采用统一的媒体库结构。
- 按片库、类型和关键词筛选内容，并支持年份、片名等排序方式。
- 聚合电影、电视剧、动漫和其他点播内容。
- 同名内容跨来源合并，在详情页集中展示可用线路和剧集。
- 海报网格与沉浸式详情页，支持背景图、简介、年份、地区和集数信息。

### 播放能力

- 支持 HLS、MP4 等常见网络媒体流。
- 支持多线路切换、剧集选择和断点续播。
- 支持自动、最高、1080P 和 720P 清晰度偏好；最终画质取决于内容源。
- 桌面端提供本地 HLS 代理、播放列表重写、广告分片过滤和弹幕来源配置。
- Android 端支持播放请求头、HLS 清晰度识别和本地 Spider 规则解析。

### 短视频

- 提供上下滑动、自动播放的沉浸式短视频信息流。
- 通过 TikHub 接入 TikTok、抖音和 YouTube Shorts 的平台作品。
- 平台短视频与 AI 短视频分类隔离，不会把 CMS 短剧混入平台推荐。
- 支持分页加载、播放地址解析、收藏和详情查看。

### 本地数据

- 收藏、观看记录、播放进度、来源和画质设置保存在当前设备。
- Android 客户端只有本地模式，不依赖桌面端服务。
- 桌面端与 Android 端的数据分别保存，不会自动跨设备同步。

## 快速使用

### Windows 桌面端

1. 安装 `VideoGET-Setup-<version>-x64.exe`，或直接运行 `VideoGET-Portable-<version>-x64.exe`。
2. 打开“媒体库”浏览内容，或使用顶部搜索框查找片名。
3. 使用片库、类型、收藏和排序控件缩小范围。
4. 点击海报进入详情页，选择“立即播放”。
5. 在播放器内切换线路、选集、清晰度或弹幕状态。
6. 在“收藏”和“观看记录”中继续之前的内容。

### Android

Android 5.0（API 21）及以上版本可安装 APK：

```powershell
adb install --no-streaming -r .\mobile\build\app\outputs\flutter-apk\app-release.apk
```

安装后：

1. 从“片库”浏览或搜索影视内容。
2. 点击海报进入详情页，选择线路和剧集后播放。
3. 从底部导航进入“短视频”，上下滑动浏览平台作品。
4. 在详情页或短视频页收藏内容。
5. 从“收藏”页查看收藏与观看记录。
6. 在“设置”中管理来源、TikHub Key、TVBox 配置和播放画质。

## 配置短视频平台

TikTok、抖音与 YouTube Shorts 来源默认关闭，需要先配置 TikHub API Key。

1. 前往 [TikHub 注册页](https://user.tikhub.io/register) 创建账号并登录。
2. 打开 [TikHub API 控制台](https://user.tikhub.io/dashboard/api)。
3. 创建并复制 API Key，确认账号有可用额度。
4. 在 VideoGET 中打开“设置 > 短视频平台 API”。
5. 粘贴纯 API Key，然后点击“保存并启用”。
6. 返回“短视频”页刷新信息流。

输入时不要手动添加 `Bearer `，应用会自动生成 `Authorization: Bearer <API_KEY>` 请求头。

相关文档：

- [TikHub API 文档](https://docs.tikhub.io/)
- [TikHub API 状态](https://monitor.tikhub.io/)

TikHub Key 会保存在当前设备的本地设置中。不要把 Key 写入仓库、截图或公开日志。

## 管理内容来源

VideoGET 支持以下点播来源：

- 苹果 CMS API。
- TVBox JSON 点播配置，包括 `type=1` CMS 和受支持的 `type=3` Spider 规则。
- 内联或远程 Spider 脚本。

### 添加 CMS 来源

在“设置 > 视频来源”中填写来源名称和 CMS API 地址，然后保存。桌面端可以点击“检测”查看来源连通性和响应时间。

常见地址形式：

```text
https://example.com/api.php/provide/vod/
```

### 导入 TVBox 配置

- 桌面端：可以导入本地 JSON/TXT 文件，也可以填写远程配置 URL。
- Android：可以导入本地 JSON 文件或填写远程配置 URL。

导入后可在来源列表中单独启用、停用或删除非内置来源。

## 桌面端开发

### 环境要求

- Windows 10/11 x64。
- Node.js 20 或更高版本。
- npm。

### 安装与运行

```powershell
npm install
npm run typecheck
npm run dev
```

`npm run dev` 会启动 Vite 和 Electron 桌面窗口。

Web 开发预览：

```powershell
npm run web:dev
```

默认地址为 `http://127.0.0.1:3000`。

### 构建 Windows 安装包

```powershell
npm run typecheck
npm run build
npm run dist
```

构建产物位于根目录 `release`：

```text
release/VideoGET-Setup-<version>-x64.exe
release/VideoGET-Portable-<version>-x64.exe
```

## Android 开发

### 环境要求

- Flutter SDK，所带 Dart SDK 版本需要满足 `>=3.12.2 <4.0.0`。
- Android SDK、Platform Tools 和接受过许可的构建工具。
- JDK 17。
- 已通过 `adb devices` 识别的设备或 Android 模拟器。

### 安装依赖并运行

在 Windows 中文用户目录下，部分 JNI/CMake 依赖可能无法正确解析路径。建议把 `PUB_CACHE` 设置到纯 ASCII 路径：

```powershell
$env:PUB_CACHE = 'D:\flutter-pub-cache'
Set-Location .\mobile
flutter pub get
flutter analyze
flutter test
flutter run
```

### 构建 APK

```powershell
$env:PUB_CACHE = 'D:\flutter-pub-cache'
Set-Location .\mobile
flutter build apk --release
```

输出文件：

```text
mobile/build/app/outputs/flutter-apk/app-release.apk
```

当前项目的 Release 构建仍使用调试签名，仅适合本地安装和测试。正式发布前需要在 `mobile/android/app/build.gradle.kts` 中配置独立的发布密钥。

### 使用 7890 代理构建

直连下载失败时，可以为当前 PowerShell 会话设置代理，并让 Flutter 本地测试服务绕过代理：

```powershell
$env:HTTP_PROXY = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
$env:NO_PROXY = '127.0.0.1,localhost,::1'
$env:no_proxy = $env:NO_PROXY
$env:GRADLE_OPTS = '-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7890 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7890 -Dorg.gradle.daemon=false -Dorg.gradle.parallel=false'
```

设置后再执行 `flutter pub get`、`flutter test` 或 `flutter build apk --release`。使用前应确认 `127.0.0.1:7890` 正在监听。

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

完整 Flutter 测试中，QuickJS Spider 原生运行时测试只在 Android 真机环境执行，在桌面测试环境会跳过。

## 项目结构

```text
videofree/
├─ electron/       Electron 主进程、本地代理、来源与短视频引擎
├─ src/            Electron React 界面
├─ web/            Next.js Web 开发入口
├─ mobile/         Flutter Android 客户端
├─ scripts/        构建与冒烟测试脚本
├─ tests/          桌面端测试资源
├─ public/         桌面端图标和静态资源
└─ README.md       桌面端与 Android 统一说明
```

## 常见问题

### 短视频页没有内容

确认 TikHub Key 已保存、平台来源处于启用状态，并检查账号额度和 [TikHub API 状态](https://monitor.tikhub.io/)。Key 输入框只填写原始 Key，不要包含 `Bearer ` 前缀。

### 短视频显示“重试播放”

先刷新短视频页并切换其他作品。如果多条作品都失败，检查设备网络、TikHub Key、平台接口状态和媒体地址是否已过期。

### 内容源搜索失败

确认来源已启用且 API 地址可以从当前设备访问。桌面端可在设置页点击“检测”；Android 端可以停用异常来源后重新搜索。

### Android 构建长时间停在 `assembleRelease`

首次构建需要下载 Gradle、Android 和 Flutter 依赖。确认网络、磁盘空间和代理状态，并使用上面的 `PUB_CACHE` 与代理配置。不要同时运行多个 Gradle 构建。

### Flutter 测试连接本机端口失败

代理可能转发了 Flutter 测试进程的本地 HTTP 连接。设置：

```powershell
$env:NO_PROXY = '127.0.0.1,localhost,::1'
$env:no_proxy = $env:NO_PROXY
```

然后重新执行 `flutter test`。

## 数据与内容说明

- VideoGET 不托管视频文件，播放内容来自已配置的第三方来源。
- 来源可用性、内容完整性、清晰度和访问速度由对应服务决定。
- 用户应自行确认内容来源和平台 API 的使用条件。
- 删除应用数据或卸载应用前，请确认是否需要保留收藏、观看记录和本地配置。
