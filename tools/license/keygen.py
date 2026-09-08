#!/usr/bin/env python3
"""Generate Ed25519 keypair for NASSAV offline licensing.

Run once. Keep the private key file OFFLINE and OUT of the repo/image.
The public key gets embedded into docker-web.py (LICENSE_PUBKEY).
"""
import sys
import secrets
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ed25519 import publickey

OUT_DIR = os.path.dirname(os.path.abspath(__file__))


def main():
    priv_path = os.path.join(OUT_DIR, "nassav_private_key.hex")
    if os.path.exists(priv_path):
        print(f"已存在私钥: {priv_path}（不覆盖）。如需重新生成请先删除。")
        with open(priv_path) as f:
            seed = bytes.fromhex(f.read().strip())
    else:
        seed = secrets.token_bytes(32)
        with open(priv_path, "w") as f:
            f.write(seed.hex())
        os.chmod(priv_path, 0o600)
    pub = publickey(seed)
    print(f"私钥文件: {priv_path}（妥善保管，勿提交仓库/勿放进镜像）")
    print(f"公钥(hex, 嵌入 docker-web.py LICENSE_PUBKEY):")
    print(pub.hex())


if __name__ == "__main__":
    main()
