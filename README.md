# VideoGET

VideoGET 是一个本地优先的 Windows 桌面影视聚合播放器。

## 当前能力

- Electron + React + TypeScript 桌面应用
- Apple 风格的简约深色界面
- CMS 多源聚合搜索与详情解析
- TVBox type 1 配置导入
- 内联 Spider 规则接口
- ArtPlayer + HLS.js 自适应高清播放
- 本地 HLS/分片代理与播放列表重写
- 电影、电视剧、动漫、短剧、AI 短剧分类
- 收藏、观看记录和本地设置
- IPTV/直播频道数据模型

## 开发

```powershell
npm install
npm run typecheck
npm run dev
```

## 构建

```powershell
npm run build
npm run dist
```

构建产物位于 `release` 目录。

## 内容来源

内置内容仅用于验证搜索与播放链路。其他内容通过用户自行配置的 CMS、TVBox 或 Spider 规则接入。实际分辨率取决于来源提供的媒体流。

