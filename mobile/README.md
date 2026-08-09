# VideoGET Mobile

VideoGET 的 Flutter 移动客户端，使用与 Web/Tauri 端相同的 Next.js API 契约，播放器基于 `media_kit`。

## 已实现能力

- 电影、电视剧、动漫、短剧和 AI 短剧聚合搜索
- 同名内容跨源去重，详情页合并线路并支持手动换线、选集
- HLS/MP4 播放、Spider 播放令牌解析、自定义播放请求头
- HLS 清晰度识别、自动/最高/1080P/720P 偏好和播放中手动切换
- 收藏、观看历史、断点续播本地持久化
- TVBox JSON、CMS 源、M3U/IPTV 文件或 URL 导入
- IPTV 搜索、分组和多线路播放

## 运行

移动端通过 HTTP 调用 VideoGET Web API。Android 模拟器默认地址为
`http://10.0.2.2:3000`，真机需要在设置中填写运行 API 服务的局域网地址。

在仓库根目录启动可被局域网访问的开发服务：

```powershell
npm.cmd run web:dev -- --hostname 0.0.0.0 --port 3000
```

然后启动 Flutter 客户端：

```powershell
& 'D:\tools\flutter\bin\flutter.bat' run
```

## Android 构建

Windows 中文用户目录会导致部分 CMake/Ninja 插件解析 Pub 缓存路径失败。使用仓库提供的脚本可把 Pub 缓存固定到项目内的 ASCII 路径：

```powershell
.\scripts\build-android.ps1 -Mode debug -ProxyUrl 'http://127.0.0.1:7890'
```

输出位于 `build\app\outputs\flutter-apk\app-debug.apk`。脚本默认依次执行依赖解析、静态检查、单元测试和 APK 构建。
