# 短视频功能开源参考

本轮改造在编码前搜索并浅克隆了以下 GitHub 项目。参考代码保存在本地 `artifacts/open-source-references/` 中，不进入产品包。

## Web / 桌面端

- 项目：[Fr4n0m/tiktok-clone](https://github.com/Fr4n0m/tiktok-clone)
- 参考提交：`b347b321d6ea4f95b915a23a59542d85edac7aff`
- 许可证：MIT
- 参考点：CSS `scroll-snap`、`IntersectionObserver` 活动项判定、只自动播放当前项、视频上层操作区。
- VideoGET 实现：`src/App.tsx` 与 `src/styles.css`。

## Android 端

- 项目：[alperefesahin/flutter_video_feed](https://github.com/alperefesahin/flutter_video_feed)
- 参考提交：`e0fcccb0e6ac8add972f5af0ca49bb792e6b4843`
- 许可证：MIT
- 参考点：纵向 `PageView`、页面切换时的播放器生命周期、相邻海报预取、限制同时活动的播放器数量。
- VideoGET 实现：`mobile/lib/screens/shorts_screen.dart`，整个流共用一个 `media_kit` Player。

## 平台接口适配

- 项目：[Evil0ctal/Douyin_TikTok_Download_API](https://github.com/Evil0ctal/Douyin_TikTok_Download_API)
- 参考提交：`42784ffc`
- 许可证：Apache-2.0
- 参考点：抖音与 TikTok 返回字段、播放地址和封面地址归一化。
- TikWM：无需 Token 的 TikTok 推荐流，默认启用；同页请求合并并缓存 30 秒，请求间隔至少 1.2 秒，短时失败可复用 5 分钟内的最近缓存。
- TikHub：通过用户本机保存的 Bearer Token 接入抖音、TikTok 和 YouTube Shorts；抖音与 YouTube 来源在配置 Token 后启用。
- YouTube Shorts：列表阶段保存 `videoget-short:` 播放令牌，真正播放时再解析视频流。

VideoGET 以自身数据模型和视觉系统重写上述交互，未引入参考项目的运行时依赖。公共接口可能受平台策略、地区和限流影响；平台适配层负责超时、错误隔离、去重和延迟解析。
