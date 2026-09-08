#!/usr/bin/env python3
"""Issue a NASSAV license code for a device.

Usage: python gen_license.py <device_id> [days]
  days > 0  -> expires after N days (default 365)
  days = 0  -> permanent license

Requires tools/license/nassav_private_key.hex (created by keygen.py).
"""
import sys
import os
import time
import base64

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ed25519 import sign

PRIV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nassav_private_key.hex")


def issue(device_id: str, days: int) -> str:
    with open(PRIV_PATH) as f:
        seed = bytes.fromhex(f.read().strip())
    expires = 0 if days <= 0 else int(time.time()) + days * 86400
    payload = b"NASSAV1|" + device_id.strip().encode() + b"|" + str(expires).encode()
    sig = sign(seed, payload)
    code = base64.b64encode(payload + sig).decode()
    return "-".join(code[i:i + 7] for i in range(0, len(code), 7))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    if not os.path.exists(PRIV_PATH):
        print("缺少私钥文件，请先运行 keygen.py")
        sys.exit(1)
    device_id = sys.argv[1]
    days = int(sys.argv[2]) if len(sys.argv) > 2 else 365
    code = issue(device_id, days)
    expires_ts = 0 if days <= 0 else time.time() + days * 86400
    expire_text = "永久" if days <= 0 else "%d 天（至 %s）" % (days, time.strftime("%Y-%m-%d", time.localtime(expires_ts)))
    print(f"设备码: {device_id}")
    print(f"有效期: {expire_text}")
    print(f"授权码:\n{code}")


if __name__ == "__main__":
    main()
