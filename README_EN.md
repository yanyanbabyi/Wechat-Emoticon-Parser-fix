# WeChat Decryptor (Fixed)

> A local data decryption tool for WeChat 4.1.x (Windows) — emoticon pack export, chat image decryption, database decryption

Decrypts WeChat's locally-encrypted data via memory scanning and key derivation: emoticon packs (including
store-pack caption naming), V2-format chat images, and the full set of WCDB databases.

This repository is a **fork of [CN-Grace/Wechat-Emoticon-Parser](https://github.com/CN-Grace/Wechat-Emoticon-Parser)
that fixes the "cannot derive the key / no seed found" failure** and removes the hard-coded data-directory
lookup. The algorithms and overall design come from the original project; upstream changes are kept in sync.

---

## What this fork fixes

**Root cause: the account directory suffix was hard-coded as `_b487`.**

A WeChat 4.x account data directory is named `<wxid>_<4 hex digits>`. Those 4 hex digits are derived from the
installation path and differ per machine (e.g. `wxid_xxx_2524` here, while many documents show `_b487`). The
original stripped the suffix only when it was exactly `_b487`; otherwise it used the whole directory name as the
wxid in `md5(f"{seed}{wxid}EMOTICON")`, so **every derived key was wrong**. Even when the correct seed *was*
found in memory, not a single candidate verified, and the tool reported `[!] Memory scan found no seed` — it
looked like a scan failure, but the wxid was the problem.

| # | Problem | Fix |
|---|---|---|
| 1 | `auto_wxid()` only recognised the `_b487` suffix; keys were wrong for every other suffix (**the root cause**) | Stop guessing the suffix: the C0 probe (first block of any emoticon file) decides among multiple wxid candidates; the winning wxid is carried into V2 chat-image decryption |
| 2 | `find_data_dir()` searched only 4 hard-coded paths and missed common locations such as `%USERPROFILE%\xwechat_files` | Multi-source locator chain: WeChat's own config ini → files opened by the running `Weixin.exe` → registry path values → common static paths; each level then picks the real account directory by content |
| 3 | `v2_find_xor()` sampled only the first 40 `.dat` files; if none was V2 it silently fell back to the hard-coded `0x88` (wrong), corrupting/failing chat images in bulk | Sampling widened to 2000 real V2 files plus a self-consistency check `tail[1]^0xD9 == tail[0]^0xFF` that discards non-JPEG trailers (PNG/HEVC) |
| 4 | The seed candidate upper bound was hard-coded to `4e9`, dropping accounts whose seed falls in 4.0e9–4.29e9 | Bound changed to `2**32` (the seed is a 32-bit unsigned integer) |
| 5 | `--seed <seed>` mode failed outright (passing a seed still reported "no key found" and exited) | An explicit seed now derives from each wxid candidate with C0 verification, and reports clearly if none matches |

Also added:

- When several account directories exist, the tool ranks them, prints which one it uses, and skips same-named
  copies under `Backup/`, `old_backup/` as well as empty directories;
- **wxid self-healing**: even a completely unknown directory-name shape (non-hex suffix, or no suffix at all) is
  resolved by verification;
- If only chat images are decrypted and no emoticon file is available for verification, 12 real `.dat` files are
  used to pick the correct wxid candidate.

---

## Features

- **Emoticon export**: store packs grouped by package name, files named by caption only (`拜拜啦.gif`);
  favorites named by collection order (`favorite_001.gif`); everything flattened into a single directory with `--notype`
- **One-shot pipeline**: locate data dir → scan seed in memory → derive key → self-contained DB decryption →
  decrypt files → stream-parse containers → name by DB metadata → CDN favorites
- **Fully self-contained DB decryption**: WCDB key scanned from process memory (no external tool)
- **wxgf animation support**: HEVC stream extraction + transcoding (GIF/PNG/JPEG output)
- **Chat image decryption**: V2-format `.dat` full restoration (`--images`)
- **Structured manifest**: `{packs, favorites, unknown, summary}` mirrored to the directory tree, sorted
- **Lightweight**: only requires `pycryptodome` (optional `imageio-ffmpeg` for transcoding)

---

## Algorithms

### 1. Emoticon file encryption

Emoticon files are encrypted under `business/emoticon/` in the `Persist` / `PersistStore` / `Thumb` /
`ThumbStore` directories (files named by content md5).

```
Cipher: AES-128-CBC + PKCS7, key = IV
key    = md5(f"{seed}{wxid}EMOTICON") hex-decoded, first 16 bytes
```

| Parameter | Source |
|---|---|
| `seed` | Account-level constant in the WeChat process memory (decimal, extracted by memory scan) |
| `wxid` | Data directory name minus its suffix (the suffix varies per installation; resolved by C0 verification — see fix 1) |

Notes:

- All emoticon files share a **single key** (different batches show a different first-block C0 only because the
  plaintext header — wxgf length fields — differs)
- `PersistStore` container files = multiple emoticons of a pack concatenated by magic (`GIF8` / `89PNG` /
  `FFD8FF`); split by a **streaming structural parse** (PNG→IEND, GIF→trailer 0x3B, JPEG→EOI) that ignores stray
  magic bytes inside compressed data — no corrupted slices
- `wxgf` files = raw H.265 stream after the magic (starting at the `00 00 00 01 40 01` VPS), transcoded via ffmpeg
- The key exists as raw 16 bytes in the main process heap, inside the account session key table (next to the wxid string)

### 2. Chat image encryption (V2 .dat)

Chat images live in `msg/`:

```
[15B header: 6B signature 07 08 56 32 08 07 | aes_size(4) | xor_size(4) | pad(1)]
[AES-128-ECB region][raw plaintext region][single-byte XOR tail]

key     = md5(f"{seed}{wxid}")[:16]   (16-char alphanumeric ASCII)
XOR key = derived from the JPEG tail FF D9 (single byte, constant per account)
```

### 3. Databases (WCDB)

WeChat 4.1+ no longer keeps the plaintext key in process memory (only the passphrase remains). The script
**fully embeds** runtime decryption: scan `com.Tencent.WCDB.Config.Cipher` objects in the WeChat process memory →
XOR deobfuscation → candidate key extraction → HMAC-SHA512 verification (SQLCipher4 spec) → AES-256-CBC
page-by-page decryption. `emoticon.db` holds all emoticon metadata (packs, captions, ordering, CDN mappings).
No external tool required.

### 4. Generic key discovery flow (memory scan → derive → verify)

```
1. Candidates  ReadProcessMemory over the Weixin.exe main process → regex-extract digit strings (seed candidates, bound 2^32)
2. Derive      md5(f"{seed}{wxid}EMOTICON"), first 16 bytes
3. Verify      AES-CBC(key=IV) decrypt any emoticon file's first block (C0) → magic hit confirms
               (89504e47 / GIF8 / FFD8FF / wxgf)
4. Resolve wxid  step 3 is repeated for every wxid candidate; the one that verifies is the real wxid
                 (no reliance on a suffix rule)
```

This flow depends on no third-party tool; only a running WeChat is required.

---

## Project structure

```
.
├── wechat_emoticon_export.py   unified tool: emoticon export + V2 images + DB decryption + key scan
├── 启动.bat                    one-click launcher for Windows (checks dependencies)
├── README.md                   Chinese documentation (default)
├── README_EN.md                this file
├── requirements.txt
└── LICENSE
```

## Output layout

```
emoticon_export/                  # default output
├── store/<pack>/<caption>.gif    # store stickers, named by caption (index/md5 kept in manifest)
├── favorite/001.gif              # favorites, named by collection order (kFavEmoticonOrderTable)
├── unknown/<md5>.jpg             # unmapped leftovers (intact files only)
└── manifest.json                 # structured: {packs, favorites, unknown, summary}

emoticon_export_all/              # with --notype: every file flattened, named pack_caption / favorite_index
decoded_images/                   # V2 chat images (menu [2] / --images)
decrypted_db/                     # ALL plaintext databases (menu [4]) — contact/message/sns/...
wechat_keys.txt                   # extracted keys (menu [5])
```

## Installation

```bash
pip install pycryptodome          # required
pip install imageio-ffmpeg        # optional: wxgf/hevc animation transcoding
```

On Windows you can simply double-click `启动.bat`, which detects and installs missing dependencies.

## Usage

```bash
# Interactive menu (no arguments):
#   [1] emoticon export   [2] V2 chat images   [3] flatten-only export
#   [4] decrypt ALL databases (db_storage -> decrypted_db/)
#   [5] extract & show keys (seed / emoticon key / V2 key)
#   [0] exit
python wechat_emoticon_export.py

# Argument mode (offline / custom paths)
python wechat_emoticon_export.py --key <hex key>                      # emoticon export (known key)
python wechat_emoticon_export.py --images --seed <seed>               # V2 images
python wechat_emoticon_export.py --data-dir <xwechat_files/wxid_xxx_xxxx> \
                                 --db <decrypted emoticon.db> --out <output dir> --notype

# Options
--no-cdn          skip CDN favorite download
--no-wxgf         skip wxgf/hevc transcoding
--notype          flatten-only output into emoticon_export_all/ (pack_caption / favorite_index)
--keep-decrypted  keep intermediate decrypted files & temp db
```

`--data-dir` is optional; when omitted the multi-source locator described above finds it automatically.

---

## Tested (after this fork's fixes)

Environment: Windows 11 + WeChat 4.1.13.12 (`Weixin.exe` running, **not** elevated)

| Path | Result |
|---|---|
| Key extraction (menu 5) | ~5.8k memory seed candidates verified across 2 wxid candidates; both the emoticon key and the V2 key were produced |
| Emoticon export (menu 1) | 31 packs / 186 store stickers / 265 favorites (CDN 265/265) / 34 unmapped = 485; 67 wxgf transcoded |
| Chat images (menu 2) | 22941 `.dat` files, of which 8329 are V2 → 8327 decrypted; 5024 jpg + 1577 png output (1727 hevc transcoded, 0 failed) |
| Databases (menu 4) | 27/27 decrypted and each opened with sqlite3 (`contact.db` 16 tables, `message_1.db` 203 tables, `general.db` 24 tables, …) |
| `--seed` argument mode | Works (this mode failed before the fix) |
| Output integrity | Decoded images decode cleanly (incl. an 8064×6048 photo and 2560×1440 screenshots); both wxid-resolution paths produce byte-identical output |

## Troubleshooting

- **"no seed found" / "cannot derive the key"**: make sure WeChat is running (the scan reads `Weixin.exe` memory).
  If it still fails, re-run as Administrator — some systems refuse memory reads from a non-elevated process.
- **`ModuleNotFoundError: No module named 'Crypto'`**: `pip install pycryptodome`.
- **wxgf/animated stickers not converted**: `pip install imageio-ffmpeg`.
- **Output is huge**: `decoded_images/`, `decrypted_db/`, `emoticon_export/` can reach several GB combined; delete
  them when not needed, or use `--no-cdn` / `--no-wxgf` to shrink the result.
- **Multiple WeChat accounts**: the tool prints which account directory it used; pass `--data-dir` to force one.
- **Does the key change?**: yes — the seed is session-scoped, so the key changes with it; WeChat must be running
  each time you extract.

---

## Acknowledgements

This project is forked from [CN-Grace/Wechat-Emoticon-Parser](https://github.com/CN-Grace/Wechat-Emoticon-Parser);
the algorithms and architecture belong to the original author. This branch only fixes key resolution, data
directory location, and V2 XOR-key sampling.

The key-extraction approach and memory-scanning methodology are inspired by the following open-source projects:

- [TANGandXue/wcdb-key-tool](https://github.com/TANGandXue/wcdb-key-tool) — WCDB database runtime scan & decryption
- [LifeArchiveProject/WeChatDataAnalysis](https://github.com/LifeArchiveProject/WeChatDataAnalysis) — key derivation formula & candidate verification
- [WeChatMsgDump](https://github.com/junuo-S/WeChatMsgDump) — process memory reading architecture
- [93857536-pixel/WeChatExporter](https://github.com/93857536-pixel/WeChatExporter) — emoticon CDN download & wxgf parsing
- [CipherTalk](https://github.com/CipherTalk/wechat-key-tool) — account seed extraction

## License

MIT — see [LICENSE](LICENSE); the original copyright notice (CN-Grace) is preserved.

## Disclaimer

This tool decrypts **your own, local** WeChat cache on **your own machine** (stickers, chat images, databases)
for personal backup and research purposes. Comply with the laws of your jurisdiction and never use it on
someone else's data or for any unauthorised purpose.
