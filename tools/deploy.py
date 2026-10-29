"""Install a built .kpkg on a Kindle over SSH, the way KPM would.

python tools/deploy.py <kindle-ip> dist/calibre-wireless_1.0.0_kindlehf-kindlepw2.kpkg [--uninstall]

Uploads the package, unpacks it under /mnt/us/kmc/kpm/tmp/ (or /tmp) and runs
its install.sh from inside the unpacked directory, with KPM-like environment
variables. Password from KINDLE_PW (Jobman default "kindle"), user root.
Needs paramiko (pip install paramiko).
"""
import os
import posixpath
import sys

import paramiko


def run(client, cmd, check=True):
    _, out, err = client.exec_command(cmd, timeout=600)
    o = out.read().decode(errors="replace")
    e = err.read().decode(errors="replace")
    rc = out.channel.recv_exit_status()
    if o.strip():
        print(o.rstrip())
    if e.strip():
        print(e.rstrip(), file=sys.stderr)
    if check and rc != 0:
        raise SystemExit(f"remote command failed ({rc}): {cmd}")
    return rc


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    host, pkg = sys.argv[1], sys.argv[2]
    uninstall = "--uninstall" in sys.argv
    pw = os.environ.get("KINDLE_PW", "kindle")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(host, username="root", password=pw, timeout=15, look_for_keys=False, allow_agent=False)
    try:
        abi = "kindlehf" if run(client, "test -e /lib/ld-linux-armhf.so.3", check=False) == 0 else "kindlepw2"
        work = "/mnt/us/kmc/kpm/tmp/calibre-wireless-deploy"
        run(client, f"mkdir -p {work} && rm -rf {work}/*")
        sftp = client.open_sftp()
        remote_pkg = posixpath.join(work, os.path.basename(pkg))
        sftp.put(pkg, remote_pkg)
        sftp.close()
        print(f"uploaded {pkg} -> {remote_pkg}")
        run(client, f"cd {work} && tar -xzf {os.path.basename(pkg)} && ls")
        env = f"KPM_PLATFORM={abi} KPM_VERSION_MAJOR=0 KPM_VERSION_MINOR=2 KPM_VERSION_PATCH=4"
        script = "uninstall.sh" if uninstall else "install.sh"
        run(client, f"cd {work} && {env} sh ./{script}")
        run(client, f"rm -rf {work}")
        if not uninstall:
            run(client, "/mnt/us/calibre-wireless/run.sh env")
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
