# Changelog

## [0.0.5] - 2026-08-18

### Added

- Desktop and Android now probe and rank up to eight playback lines by startup latency, measured throughput, recent reliability, and usable quality, preferring stable 1080p-or-lower routes with enough bandwidth reserve.
- Added two managed CMS routes, corrected the existing line E endpoint, and automatically migrate built-in route definitions without overwriting user enable/search preferences.
- HLS background prefetch now caches the opening segments and five-minute seek anchors first, then continues sequentially through the full episode while reusing the persistent media cache.
- Android fullscreen playback provides left-side brightness swipes, right-side volume swipes, and hold-for-2x playback with speed restoration on release.

### Fixed

- Android tries playback traffic directly first, falls back to the configured system proxy within the shared timeout budget, and switches lines when first playback remains near zero even if the player does not report buffering.
- Route probing now validates opening media responses and encrypted HLS keys, rejects HTML/JSON/error pages, and carries the selected manifest `Referer` into segment probes so ranking matches the Android playback proxy.
- Seeking between distant positions now reuses prefetched anchor segments instead of waiting for purely sequential cache fill.
- Range responses are cached only after a matching `206 + Content-Range`; sources that ignore Range and return a full `200` response can no longer poison later seeks.
- Desktop HLS prefetch selects the highest available variant at or below 1080p, and reports empty or failed downloads instead of counting them as completed cache entries.
- Desktop and Android HLS filtering recognize marked ads and conservative discontinuity-based ad islands while preserving encryption keys, init maps, episode position, and line handoff state.
- Desktop history persists native playback progress and opens cached playback lines immediately; Android manual line changes and automatic failover both keep the matching episode.

### Build and signing

- Android debug and release builds use the existing fixed signing identity so AVD tests and release upgrades remain data-compatible.
- Flutter Pub, Gradle, and `media_kit` native artifacts use persistent caches; normal cleanup no longer forces all ABI libraries to download again.
- Final APK certificate SHA-256 remains `f9a529fd73bb2193a805e6b2d09d39cf4f006d998aaa3e7b85f6a841391b5e1a`.

### Verification

- A networked Android API 35 AVD searched `怪奇物语第五季` in `3.246 s`, resolved seven playback lines in `10.292 s`, selected line B, and started a `4,288,083 ms` episode in `10.550 s`.
- Playback advanced for `10.291 s` with zero buffering events; network seeks resumed in `1.753 s` at five minutes and `3.387 s` at ten minutes, both below the eight-second release limit.
- The AVD's composed ten-minute video frame was visibly decoded with subtitles; its video crop contained `94.44%` non-dark pixels. Brightness reached `1.0`, volume reached `1.0`, hold playback reached `2.0x`, history persisted at `619.439 s`, and no `avformat_open_input` failure was observed.
- Flutter analysis reported no issues; 82 host mobile tests passed with one Android-only QuickJS test skipped. A later live rerun still completed network search/detail and automatic line failover, but the upstream HLS provider intermittently rejected key/first-segment requests on the AVD with crypto/H.264 errors; those transient provider failures are not counted as a successful cold-start result.
- The final `0.0.5 (5)` APK contains `armeabi-v7a`, `arm64-v8a`, and `x86_64`, passed the fixed-signature check, and upgraded successfully on Android `user 0` with `adb install -r`.

## [0.0.4] - 2026-08-16

### Added

- Windows and Android now keep an on-demand persistent cache for HLS media, including Range/206 responses, with bounded LRU eviction.
- Android fullscreen playback supports left-side brightness swipes, right-side media-volume swipes, and hold-for-2x playback with automatic speed restoration.
- HLS ad filtering is available in both clients and preserves active encryption keys and initialization maps when marked ad segments are removed.

### Fixed

- Removed automatic whole-video concurrent prefetching that competed with foreground playback and caused long-video stalls.
- Desktop history now migrates legacy local history once, saves playback progress from native video events, and opens cached play lines immediately after restart.
- Desktop library writes are atomic and retain a backup that can restore a damaged primary data file.
- Android history opens stored play lines immediately while refreshing expired details in the background.
- Desktop and Android caches now reuse matching Range requests and avoid caching manifests, HTML, JSON, or oversized media objects.

### Verification

- Windows online search returned 16 results for `Avatar`; remote HLS playback stayed ready, grew the disk cache, and replayed a segment with `X-VideoGET-Cache: HIT`.
- Desktop playback history survived an application restart, opened its stored detail in 34 ms, and resumed the same online stream from `00:45`.
- Android AVD online search and remote HLS playback completed through `10.0.2.2:7890`; persistent cache, history, brightness, volume, hold-for-2x, and `adb install -r` data preservation were verified.

## [0.0.3] - 2026-08-15

### v0.0.3 - Full Video Prefetch & Disk Cache

- **HLS segment disk cache (2GB LRU):** Desktop proxy server caches .ts/.m4s/.aac segments to disk with SHA-256 keying and atomic writes
- **Background prefetch of entire video:** New PrefetchManager pre-downloads all video segments (4 concurrent workers) when playback starts, ensuring 100% cache hit rate
- **Efficient /prefetch endpoint:** Dedicated proxy endpoint that fetches and caches segments without transferring video data back to the caller
- **HLS.js buffer tuning:** maxBufferLength 60s / maxMaxBufferLength 120s / 128MB buffer / 8 retries / 45s timeout
- **Android mpv full-video prefetch:** cache-secs=86400 (24h, effectively unlimited), demuxer-readahead-secs=1200 (20 min aggressive readahead), bufferSize=512MB, stream-buffer-size=2MB, demuxer-seekable-cache=yes
- **206 response caching fix:** Proxy now caches upstream 206 (Partial Content) HLS segments
- **Cache stats and clear endpoints:** /cache-stats and /cache-clear for monitoring and management

### Fixed

- Fix 206 status segments not being cached, requiring re-download on replay
- Fix history replay always re-downloading all segments - now loads from disk cache instantly

### Changed

- Desktop proxy server: VideoCache integration, X-VideoGET-Cache header, /prefetch endpoint
- Desktop: New PrefetchManager (electron/prefetch-manager.ts), prefetch IPC handlers
- Desktop: preload exposes startPrefetch/stopPrefetch/getPrefetchStatus/onPrefetchProgress
- Desktop: App.tsx auto-triggers prefetch on m3u8 playback start
- Android: mpv cache parameters dramatically increased for full-video prefetch strategy


## [0.0.2] - 2026-08-13

### 第二版修订

- 全屏进度条上移至系统手势区之上，并在横屏播放器中保留约 42 dp 的底部安全距离。
- 双击画面中央区域可暂停或继续播放；播放器自带的左右双击快进手势已关闭，避免手势冲突。
- 历史记录会将上次线路、集数和进度显式传入播放器；断点同时使用 mpv 原生起播位置与加载后的校验式补偿，避免媒体加载完成后把 seek 重置为 0 秒。
- 退出播放器前串行保存进度，销毁播放器时先捕获当前位置，避免异步保存被 mpv 状态清零覆盖。
- Android 设备测试覆盖全屏进度条、双击暂停/继续、退出保存和二次打开恢复；另以本地 31 分钟视频在飞行模式下连续实播 30 分钟，最终位置 `1,803,058 ms`，30 个逐分钟样本均持续播放且无缓冲事件。
- Release 构建会排除设备集成测试遗留的 `integration_test` 插件注册，确保测试后仍可生成并启动生产 APK。
- 版本保持 `0.0.2+2`，本次修订不创建 `v0.0.3` 标签或 GitHub Release。

### Fixed

- 修复播放器退出或切换剧集时异步保存晚于 mpv 销毁，导致观看记录回到 0 秒的问题。
- 修复历史记录进入详情页后没有沿用上次线路和集数的问题，并支持总时长尚未探测到时的断点续播。
- 修复自动画质启动时被固定到单一视频轨道，长视频无法持续自适应降档的问题。

### Changed

- Android 播放器在打开媒体前应用 128 MiB 缓冲、90 秒缓存、45 秒预读和缓存暂停策略，降低长视频连续播放中的卡顿。
- 小窗口不再显示倍速和清晰度菜单；全屏控制栏新增时间、电量、剧名、线路、选集、倍速和清晰度设置。
- Android 依赖增加 `battery_plus`，用于全屏顶栏电量显示。

## [0.0.1] - 2026-08-12

### Added

- 发布 Windows、Web 和 Android 共用核心能力的首个版本。
- Android 播放器增加受分辨率和码率约束的智能起播，并在持续卡顿时逐级降档。

### Changed

- 桌面和 Web 默认启用 HLS 自适应码率，1080P、720P 和不限制选项作为自适应上限。
- 调整 HLS 与 Android 缓冲、预读、超时和错误恢复参数，优先保障长视频连续播放。
- 代理在直连失败后短期记忆代理路由，减少每个分片重复等待直连超时。

### Fixed

- 修复默认强制最高画质导致 hls.js 无法持续自适应降档的问题。
- 修复客户端放弃分片后上游下载仍继续、长视频可能积累连接和监听器的问题。
- 修复旧版最高画质偏好迁移到智能适配后 Web 设置未写回的问题。
