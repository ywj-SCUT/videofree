# 短视频功能开源参考

本轮改造在编码前先搜索并浅克隆了两个 MIT 许可的 GitHub 项目。参考代码保存在本地 `artifacts/open-source-references/` 中，不进入产品包。

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

VideoGET 以自身数据模型和视觉系统重写上述交互，未引入参考项目的运行时依赖。点播所需的 HLS / `.m3u8` 解析、代理和广告过滤保持不变。
