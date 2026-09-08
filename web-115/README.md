# Jable 媒体库前端

此页面由 Docker 容器根路径提供，包含影片浏览、本地下载队列、媒体库和 115 离线任务。

## 115 离线服务协议

为避免在容器中保存 115 网页 Cookie，前端通过一个由用户控制的授权中转服务提交离线任务。服务地址配置在“服务设置”中，容器会向该地址发送 `POST` JSON：

```json
{
  "id": "任务 UUID",
  "url": "magnet:?xt=... 或 https://...",
  "name": "影片标题",
  "catalog": "影片番号",
  "detail_url": "影片详情页"
}
```

中转服务可返回以下字段：

```json
{
  "state": "submitted",
  "message": "已提交到 115",
  "play_url": "https://115.com/..."
}
```

`play_url` 会显示为任务表中的“播放”按钮。
