FROM docker.m.daocloud.io/library/golang:1.22-alpine AS m3u8-builder

WORKDIR /build

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories && apk add --no-cache git

RUN git clone https://github.com/Greyh4t/m3u8-Downloader-Go.git src && \
    cd src && git checkout tags/v1.5.2 && \
    GOPROXY=https://goproxy.cn,direct go build -o /build/m3u8-Downloader-Go

FROM docker.m.daocloud.io/library/alpine:3.19 AS nassav

WORKDIR /NASSAV

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories && \
    apk add --no-cache ffmpeg python3 && \
    rm -rf /var/cache/apk/*

COPY . .

COPY --from=m3u8-builder /build/m3u8-Downloader-Go tools/m3u8-Downloader-Go

RUN python -m venv .

RUN ./bin/pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt

ENTRYPOINT ["./bin/python", "main.py"]
