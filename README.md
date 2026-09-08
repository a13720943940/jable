# jable-media-library

Jable 媒体库是一个面向 NAS 的家庭影音管理服务，提供 Docker Web 管理端和原生 iOS 客户端。项目把 Jable 影片浏览、详情抓取、磁力离线、115 网盘播放、本地媒体库整理、黄果短剧追更下载等能力整合到同一个服务里。

> 请在你拥有合法访问权和使用权的内容范围内使用本项目。

## 功能概览

- Jable 影片浏览：在本服务内展示影片列表、分页、详情、样图预览和磁力链接。
- 详情页操作：支持复制磁力、提交 115 离线、抓取影片媒体地址、创建本地下载任务。
- 磁力来源：支持 JavBus 数据源，并可通过 `SCRAPER_SOURCES` 配置备用域名。
- 115 网盘：支持 Cookie 模式和扫码登录，支持离线任务、播放链接解析、STRM 生成和本地媒体库关联。
- 本地媒体库：扫描 `/media`、海报/封面展示、播放本地文件或 STRM、任务状态联动。
- 黄果短剧：支持站点列表、追剧库、剧集下载、缺失补齐、追更检查、上传 115 和可选删除源文件。
- 服务中心：代理配置、Jable Cookie、115 配置、访问密码、授权中心、黄果配置、日志中心。
- 原生 iOS：SwiftUI 客户端，包含影片、媒体库、黄果、下载、设置等底部菜单。
- Docker 部署：提供 `linux/amd64` 镜像 tar 分卷和 Compose 文件，适合绿联、群晖等 x86_64 NAS。

## 快速部署

仓库已包含最新 amd64 Docker 镜像分卷和 Compose：

- `release/docker/compose.yaml`
- `release/docker/jable-media-library-20260908-latest-amd64.tar.part-*`
- `release/docker/jable-media-library-20260908-latest-amd64.tar.sha256`

在 NAS 上执行：

```bash
cd /volume2/docker/jable-media-library
cat jable-media-library-20260908-latest-amd64.tar.part-* > jable-media-library-20260908-latest-amd64.tar
shasum -a 256 -c jable-media-library-20260908-latest-amd64.tar.sha256
docker load -i jable-media-library-20260908-latest-amd64.tar
docker compose -f compose.yaml up -d
```

启动后访问：

```text
http://<NAS-IP>:8788
```

健康检查：

```bash
curl http://127.0.0.1:8788/api/health
```

正常会返回类似：

```json
{"architecture":"x86_64","browser":true,"downloader":true,"media":"/media","status":"ok"}
```

## Compose 配置

默认 Compose 位于 `release/docker/compose.yaml`：

```yaml
name: jable-media-library

services:
  app:
    image: jable-media-library:20260908-latest-amd64
    platform: linux/amd64
    container_name: jable-media-library
    restart: unless-stopped
    shm_size: "1gb"
    ports:
      - "8788:8788"
    dns:
      - 223.5.5.5
      - 119.29.29.29
    environment:
      TZ: Asia/Shanghai
      DATA_DIR: /data
      MEDIA_DIR: /media
      HTTP_PROXY: ${HTTP_PROXY:-}
      JABLE_COOKIE: ${JABLE_COOKIE:-}
      SCRAPER_SOURCES: ${SCRAPER_SOURCES:-www.javbus.com,www.busdmm.ink,www.dmmsee.bond}
      CLOUD115_MODE: ${CLOUD115_MODE:-bridge}
      CLOUD115_ENDPOINT: ${CLOUD115_ENDPOINT:-}
      CLOUD115_TOKEN: ${CLOUD115_TOKEN:-}
      CLOUD115_COOKIE: ${CLOUD115_COOKIE:-}
    volumes:
      - /volume2/docker/jable-media-library/data:/data
      - /volume1/观影/new/jable/img-cache:/tmp/img-cache
      - /volume1/观影/new/jable/strm:/strm
      - /volume1/观影/new/jable/video:/media
```

常用环境变量：

| 变量 | 说明 |
| --- | --- |
| `DATA_DIR` | 数据库、缓存、任务状态目录，容器内默认 `/data` |
| `MEDIA_DIR` | 本地媒体库扫描目录，容器内默认 `/media` |
| `HTTP_PROXY` | 网络代理，例如 `http://192.168.2.50:7890` |
| `JABLE_COOKIE` | Jable Cookie，可提高页面抓取成功率 |
| `SCRAPER_SOURCES` | JavBus 磁力/元数据源，逗号分隔 |
| `CLOUD115_MODE` | 115 模式，`bridge` 或 `cookie` |
| `CLOUD115_ENDPOINT` | 115 中转服务地址，bridge 模式使用 |
| `CLOUD115_TOKEN` | 115 中转服务令牌，bridge 模式使用 |
| `CLOUD115_COOKIE` | 115 Cookie，cookie 模式使用 |
| `HUANGGUO_SITE` | 黄果短剧主站地址 |
| `HUANGGUO_MIRRORS` | 黄果备用镜像地址，逗号或空格分隔 |
| `LICENSE_REVOCATION_URL` | 授权吊销列表地址 |

## Web 使用

首次启动后进入 Web 页面，在右上角或设置页完成基础配置：

1. 配置网络代理：如果 NAS 自身无法访问 Jable、JavBus 或黄果，填写 Clash HTTP 代理地址。
2. 配置 Jable Cookie：可从能访问 Jable 的浏览器复制 Cookie。
3. 配置 115：可以使用扫码登录，也可以使用 Cookie 模式。
4. 配置访问密码：公网暴露时建议启用，内网自用可留空。
5. 配置授权中心：输入授权码后解锁受保护功能。

主要页面：

- `影片浏览`：浏览 Jable 最新影片，支持分页、详情、样图、磁力、抓取和离线。
- `本地下载`：查看本地下载任务进度，支持重试、取消、优先级等操作。
- `115 离线任务`：查看 115 离线状态，完成后可播放或生成 STRM。
- `本地媒体库`：查看 NAS 本地媒体文件和 STRM 媒体库。
- `黄果短剧`：浏览、加入追剧、下载剧集、补齐缺失、上传 115。
- `日志中心`：查看、筛选、导出和清理服务日志。
- `服务设置`：集中管理代理、Cookie、115、黄果、访问密码和授权。

## iOS 客户端

iOS 项目位于 `ios-app/JableTVMobile`，使用 SwiftUI 构建，最低部署目标为 iOS 18。

客户端能力：

- 首次进入连接页，填写服务地址和可选访问密码。
- 支持 HTTP 内网地址，已配置 `NSAppTransportSecurity` 放行 HTTP。
- 底部菜单包含影片、媒体库、黄果、下载、设置。
- 媒体库支持 Apple TV 风格详情页、分集播放和本地/115 分类。
- 设置页同步 Web 服务中心的代理、115、授权、访问密码等配置。

本地构建：

```bash
cd ios-app
xcodebuild -project JableTVMobile.xcodeproj -scheme JableTVMobile -configuration Release -sdk iphoneos build
```

未签名 IPA 输出通常放在：

```text
release/ios/
```

## 本地开发

后端依赖：

```bash
pip install -r requirements.txt
```

Web 前端：

```bash
cd web-115
npm install
npm run dev
npm run build
```

Docker 镜像构建：

```bash
npm --prefix web-115 run build
docker buildx build --platform linux/amd64 -f Dockerfile.web -t jable-media-library:20260908-latest-amd64 --load .
docker save jable-media-library:20260908-latest-amd64 -o release/docker/jable-media-library-20260908-latest-amd64.tar
```

重新生成 GitHub 可提交分卷：

```bash
cd release/docker
split -b 95m jable-media-library-20260908-latest-amd64.tar jable-media-library-20260908-latest-amd64.tar.part-
shasum -a 256 jable-media-library-20260908-latest-amd64.tar > jable-media-library-20260908-latest-amd64.tar.sha256
```

## 常见问题

### iOS 提示 App Transport Security

请安装包含 HTTP 权限修复的新 IPA。当前 iOS 项目通过 `ios-app/JableTVMobile/Info.plist` 放行 HTTP，适配内网 `http://192.168.x.x:8788` 和普通 HTTP 域名访问。

### 域名首页能打开，但 `/api/health` 不正常

说明反代或网关只转发了网页首页，没有正确转发 API。请确认域名到 NAS 的 `8788` 端口完整代理了所有路径，尤其是 `/api/*`。

### 影片列表为空

优先检查代理和 Cookie：

- NAS 容器内需要能访问 `https://jable.tv/`。
- 如果 Jable 有风控，填写可访问浏览器中的 Jable Cookie。
- Clash 代理地址应使用 NAS 可访问地址，例如 `http://192.168.2.50:7890`，不要填容器内不可达的本机地址。

### 115 无法离线或播放

检查 115 登录方式：

- Cookie 模式需要保存有效的 115 Cookie。
- 扫码登录需要二维码状态变为已授权。
- bridge 模式需要 `CLOUD115_ENDPOINT` 和 `CLOUD115_TOKEN` 可用。

## 目录说明

| 路径 | 说明 |
| --- | --- |
| `docker-web.py` | Flask 后端和主要 API 服务 |
| `web-115/` | React + Ant Design Web 管理端 |
| `ios-app/` | SwiftUI 原生 iOS 客户端 |
| `src/` | 下载器、刮削器和通用下载逻辑 |
| `tools/` | m3u8 下载器、辅助脚本、授权服务 |
| `release/docker/` | Docker Compose、镜像分卷和校验文件 |
| `release/ios/` | 本地生成的 IPA 输出目录 |

## 致谢

- [m3u8-Downloader-Go](https://github.com/Greyh4t/m3u8-Downloader-Go)
- 原 NASSAV 项目结构和下载器实现
