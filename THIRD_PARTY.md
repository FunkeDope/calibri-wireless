# Third-party components

calibre wireless is MIT licensed (see LICENSE). It bundles the following
prebuilt, unmodified components so that it runs on a jailbroken Kindle without
any other software installed. All of them are taken from KOReader's official
release archives (`koreader-kindlehf-<ver>.zip`, `koreader-kindlepw2-<ver>.zip`,
currently v2026.07.1) by `tools/fetch_runtime.py`; KOReader's own license file is
included as `COPYING.koreader`.

| Component | Files | License | Source |
|---|---|---|---|
| LuaJIT | `runtime/<abi>/bin/luajit` | MIT | https://luajit.org / https://github.com/koreader/koreader-base |
| LuaSocket | `runtime/<abi>/lib/socket/score.so`, `src/lua/vendor/socket.lua` | MIT | https://github.com/lunarmodules/luasocket |
| LuaFileSystem | `runtime/<abi>/lib/lfs.so` | MIT | https://github.com/lunarmodules/luafilesystem |
| dkjson | `src/lua/vendor/dkjson.lua` | MIT | http://dkolf.de/dkjson-lua/ |
| FBInk | `runtime/<abi>/bin/fbink` | GPL-3.0 | https://github.com/NiLuJe/FBInk — full build (image + TrueType) taken from KindleModding's `jb.sh` kmc payload (build recipe: https://github.com/KindleModding/jb.sh) via `tools/extract_jb_fbink.py`. KOReader's fbink is a reduced build without image support and is not used. |

FBInk is used as a separate executable (spawned as a process); its source is
available at the link above. If you redistribute this package you must keep
this notice and the GPL-3.0 text (included in `COPYING.koreader`).

The calibre logo in `assets/` is derived from calibre's `library.png`
(calibre is GPL-3.0, (c) Kovid Goyal); it is used to identify the calibre
connection and is not an endorsement by the calibre project.

Amazon Ember fonts are read from the Kindle at runtime (`/usr/java/lib/fonts`)
and are not redistributed; the PNG assets were rendered with them.
