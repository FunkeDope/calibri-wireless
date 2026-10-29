"""Run shell commands on the Kindle over SSH and print the output.

Usage:
  python kindle_ssh.py <host> "<command>" ["<command>" ...]
  python kindle_ssh.py <host> --script <file>   # run each non-empty, non-# line

Password comes from the KINDLE_PW environment variable (Jobman default: see
/mnt/us/jobman/ssh/etc/config.toml on the device). User is root.
"""
import os
import sys

import paramiko


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    host = sys.argv[1]
    if sys.argv[2] == "--script":
        with open(sys.argv[3], encoding="utf-8") as f:
            cmds = [l.rstrip("\n") for l in f if l.strip() and not l.lstrip().startswith("#")]
    else:
        cmds = sys.argv[2:]

    pw = os.environ.get("KINDLE_PW")
    if not pw:
        print("KINDLE_PW not set", file=sys.stderr)
        return 2

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(host, username="root", password=pw, timeout=15,
                   look_for_keys=False, allow_agent=False)
    try:
        for cmd in cmds:
            print(f"\n$ {cmd}")
            _, out, err = client.exec_command(cmd, timeout=60)
            o = out.read().decode(errors="replace").rstrip()
            e = err.read().decode(errors="replace").rstrip()
            if o:
                print(o)
            if e:
                print("[stderr]", e)
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
