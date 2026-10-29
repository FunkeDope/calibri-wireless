"""Download files from the Kindle over SFTP.

Usage: python kindle_get.py <host> <remote_path> <local_path> [<remote> <local> ...]
Password from KINDLE_PW env var; user root.
"""
import os
import sys

import paramiko


def main() -> int:
    if len(sys.argv) < 4 or (len(sys.argv) - 2) % 2:
        print(__doc__)
        return 2
    host = sys.argv[1]
    pairs = list(zip(sys.argv[2::2], sys.argv[3::2]))
    pw = os.environ.get("KINDLE_PW")
    if not pw:
        print("KINDLE_PW not set", file=sys.stderr)
        return 2
    t = paramiko.Transport((host, 22))
    t.connect(username="root", password=pw)
    try:
        sftp = paramiko.SFTPClient.from_transport(t)
        for remote, local in pairs:
            os.makedirs(os.path.dirname(os.path.abspath(local)), exist_ok=True)
            sftp.get(remote, local)
            print(f"downloaded {remote} -> {local} ({os.path.getsize(local)} bytes)")
    finally:
        t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
