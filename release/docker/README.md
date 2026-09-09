# jable-media-library Docker Release

This folder contains amd64 Docker deployment files.

## Files

- `compose.yaml`: default NAS deployment compose file.
- `compose-20260909-signin-verified-amd64.yaml`: timestamped copy of the latest deployment config.
- `jable-media-library-20260909-signin-verified-amd64.tar.part-*`: split Docker image archive parts.
- `jable-media-library-20260909-signin-verified-amd64.tar.sha256`: checksum for the restored tar file.

## Restore The Image Tar

GitHub rejects normal repository files larger than 100 MB, so the Docker image tar is committed as split parts.

```bash
cat jable-media-library-20260909-signin-verified-amd64.tar.part-* > jable-media-library-20260909-signin-verified-amd64.tar
shasum -a 256 -c jable-media-library-20260909-signin-verified-amd64.tar.sha256
docker load -i jable-media-library-20260909-signin-verified-amd64.tar
docker compose -f compose.yaml up -d
```
