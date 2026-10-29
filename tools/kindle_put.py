"""Upload a local file to the Kindle over SFTP.

Usage: python kindle_put.py <host> <local_path> <remote_path>
Password from KINDLE_PW env var; user root.
"""
import os
import sys

import paramiko


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    host, local, remote = sys.argv[1:4]
    pw = os.environ.get("KINDLE_PW")
    if not pw:
        print("KINDLE_PW not set", file=sys.stderr)
        return 2
    t = paramiko.Transport((host, 22))
    t.connect(username="root", password=pw)
    try:
        sftp = paramiko.SFTPClient.from_transport(t)
        sftp.put(local, remote)
        st = sftp.stat(remote)
        print(f"uploaded {local} -> {remote} ({st.st_size} bytes)")
    finally:
        t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
