# WeChat Decryptor（修复版）

> 微信 4.1.x（Windows）本地数据解密工具 —— 表情包导出 + 聊天图片解密 + 数据库解密

通过内存扫描与密钥派生，解密微信本地加密数据：表情包（含商店包标题命名）、V2 格式聊天图片、以及全部 WCDB 数据库。

本仓库是 [CN-Grace/Wechat-Emoticon-Parser](https://github.com/CN-Grace/Wechat-Emoticon-Parser) 的修复分支（fork），**修复了"解析不出密钥 / 扫描不到 seed"的问题**，并让数据目录定位不再依赖写死路径。算法与整体设计沿用原项目，上游的更新也会保持同步。

---

## 本仓库修了什么

**根因：账号目录后缀被写死成 `_b487`。**

微信 4.x 的账号数据目录名是 `<wxid>_<4 位十六进制>`，那 4 位十六进制由安装路径决定、每台机器不同（例如本机是 `wxid_xxx_2524`，而很多文档里是 `_b487`）。原版只在后缀恰好为 `_b487` 时才把它剥掉，其余情况会把整个目录名当成 wxid 参与 `md5(f"{seed}{wxid}EMOTICON")`，于是**派生出的密钥全部错误**，即使内存里正确扫到了 seed 也会一个都校验不通过，最终报 `[!] Memory scan found no seed`——看起来像"扫不到 seed"，其实是 wxid 错。

| # | 问题 | 修复 |
|---|---|---|
| 1 | `auto_wxid()` 只认 `_b487` 后缀，其它后缀账号密钥全错（**解不出密钥的根因**） | 不再"猜后缀"：由 C0 校验（表情文件首块）在多个候选 wxid 中定案，命中者即真 wxid，并把该 wxid 继续传给 V2 图片解密 |
| 2 | `find_data_dir()` 只搜 4 条写死路径，本机常见位置（如 `%USERPROFILE%\xwechat_files`）找不到 | 多来源定位链：微信自身 config ini → 运行中 `Weixin.exe` 已打开的文件 → 注册表路径值 → 常见静态路径；每级再按内容特征挑选真实账号目录 |
| 3 | `v2_find_xor()` 只抽样前 40 个 `.dat`，若这批不含 V2 条目就静默退回写死的 `0x88`（错误值），聊天图片成批解坏/解不出 | 抽样范围扩到 2000 个真实 V2 文件，并加入自洽校验 `tail[1]^0xD9 == tail[0]^0xFF`，排除 PNG/HEVC 等非 JPEG 尾部的干扰票 |
| 4 | seed 候选取值上界写死 `4e9`，会整体漏掉 seed 落在 4.0e9~4.29e9 的账号 | 上界改为 `2**32`（seed 是 32 位无符号整数） |
| 5 | `--seed <seed>` 参数模式直接失败（传了 seed 反而报"扫不到密钥"并退出） | 显式 seed 走"候选 wxid 派生 + C0 校验"，校验通过即导出，全不通过给出明确提示 |

另外新增：

- 多个账号目录时自动择优并打印实际使用的目录，`Backup/`、`old_backup/` 之类的同名副本与空目录会被排除；
- **wxid 自愈**：即使目录名形态完全未知（后缀不是十六进制、甚至没有后缀），也会通过校验定案；
- 只解聊天图片、没有表情文件可供校验时，用 12 个真实 `.dat` 实测挑选正确的 wxid 候选。

---

## 特性

- **表情包导出**：商店包按包名分组，文件按标题命名（`拜拜啦.gif`）；收藏按收藏顺序命名（`favorite_001.gif`）；`--notype` 全量平铺到单一目录
- **一键全通路**：定位数据目录 → 内存扫 seed → 派生密钥 → 自包含 db 解密 → 文件解密 → 流式容器分割 → db 匹配命名 → CDN 收藏
- **数据库解密完全内置**：WCDB 密钥内存扫描（无需外部工具）
- **wxgf 动图支持**：HEVC 流提取 + 首帧/整段转码（GIF/PNG/JPEG 直出）
- **聊天图片解密**：V2 格式 `.dat` 全量还原（`--images`）
- **结构化 manifest**：`{packs, favorites, unknown, summary}` 与目录树一一对应，已排序
- **轻依赖**：仅需 `pycryptodome`（转码可选 `imageio-ffmpeg`）

---

## 算法

### 1. 表情包文件加密（emoticon）

表情文件加密存储于 `business/emoticon/` 下 `Persist` / `PersistStore` / `Thumb` / `ThumbStore`
四个目录（文件名为内容 md5）。

```
算法: AES-128-CBC + PKCS7, key = IV
key = md5(f"{seed}{wxid}EMOTICON") hex 解码前 16 字节
```

| 参数 | 来源 |
|---|---|
| `seed` | 微信进程内存中的账号级常量（十进制数，内存扫描提取） |
| `wxid` | 数据目录名去掉后缀（后缀随安装路径变化，由 C0 校验定案，见上文修复 1） |

要点：

- 所有表情文件共用同一密钥（不同批次首块 C0 不同，只因明文头 wxgf 长度字段差异）
- `PersistStore` 容器文件 = 每包多表情按魔数（`GIF8`/`89PNG`/`FFD8FF`）连续拼接，
  **流式结构解析分割**（PNG→IEND、GIF→0x3B、JPEG→EOI），自动忽略压缩数据内部的魔数误匹配，不产生残缺切片
- `wxgf` 文件 = 魔数后为裸 H.265 流（从 `00 00 00 01 40 01` VPS 处截取），ffmpeg 转换
- 密钥以二进制 16 字节存于主进程堆的账号会话 key 表（wxid 字符串旁）

### 2. 聊天图片加密（V2 .dat）

聊天图片存于 `msg/` 目录，格式：

```
[15B 头: 6B 签名 07 08 56 32 08 07 | aes_size(4) | xor_size(4) | pad(1)]
[AES-128-ECB 区段][raw 明文区][单字节 XOR 尾部]

key    = md5(f"{seed}{wxid}")[:16]   (16 字符字母数字 ASCII)
XOR key = 由 JPEG 尾部 FF D9 反推（单字节，全账号一致）
```

### 3. 数据库（WCDB）

微信 4.1+ 进程内存不再缓存明文密钥（仅留 passphrase）。脚本**完整内置**运行时解密：
内存扫描 `com.Tencent.WCDB.Config.Cipher` 对象 → XOR 反混淆 → 候选 key 提取 →
HMAC-SHA512 校验（SQLCipher4 规范）→ AES-256-CBC 逐页解密。`emoticon.db` 含表情全部元数据
（包、标题、排序、CDN 映射）。无需外部工具。

### 4. 通用密钥发现流程（内存扫描 → 派生 → 校验）

```
1. 候选提取   ReadProcessMemory 读取 Weixin.exe 主进程 → 正则提取数字串（seed 候选，上界 2^32）
2. 派生       md5(f"{seed}{wxid}EMOTICON") 取前 16 字节
3. 校验       用任意 emoticon 文件首块（C0）AES-CBC(key=IV) 解密 → 魔数命中即确认
              （89504e47 / GIF8 / FFD8FF / wxgf）
4. wxid 定案  第 3 步对每个 wxid 候选各做一遍，命中的那个就是真 wxid（不依赖后缀规则）
```

该流程不依赖第三方工具，仅需微信处于运行状态。

---

## 项目结构

```
.
├── wechat_emoticon_export.py   统一工具：表情导出 + V2 图片解密 + 数据库解密 + key 扫描
├── 启动.bat                     Windows 一键启动（自动检查依赖）
├── README.md                    中文说明（本文件）
├── README_EN.md                 English documentation
├── requirements.txt
└── LICENSE
```

## 输出结构

```
emoticon_export/                  # 默认输出
├── store/<包名>/<标题>.gif        # 商店表情，标题命名（序号/md5 存 manifest）
├── favorite/001.gif              # 收藏表情，按收藏顺序命名（kFavEmoticonOrderTable）
├── unknown/<md5>.jpg             # 未匹配残留（仅完整文件）
└── manifest.json                 # 结构化：{packs, favorites, unknown, summary}

emoticon_export_all/              # --notype：全量平铺，命名 组名_表情名 / favorite_序号
decoded_images/                   # V2 聊天图片（菜单 [2] / --images）
decrypted_db/                     # 全部明文数据库（菜单 [4]）— contact/message/sns 等
wechat_keys.txt                   # 提取的密钥（菜单 [5]）
```

## 安装

```bash
pip install pycryptodome          # 必需
pip install imageio-ffmpeg        # 可选：wxgf/hevc 动图转码
pip install psutil                # 可选：数据目录定位多一条来源（读取运行中进程已打开的文件）
```

Windows 用户可直接双击 `启动.bat`（会自动检测并安装缺失依赖）。

## 使用

```bash
# 交互式菜单（无参数运行）:
#   [1] 表情包导出   [2] V2 聊天图片   [3] 平铺模式导出
#   [4] 解密全部数据库（db_storage → decrypted_db/）
#   [5] 提取并显示密钥（seed / emoticon key / V2 key）
#   [0] 退出
python wechat_emoticon_export.py

# 参数模式（离线 / 自定义路径）
python wechat_emoticon_export.py --key <hex key>                      # 表情导出（已知 key）
python wechat_emoticon_export.py --images --seed <seed>               # V2 图片
python wechat_emoticon_export.py --data-dir <xwechat_files/wxid_xxx_xxxx> \
                                 --db <已解密 emoticon.db> --out <输出目录> --notype

# 选项
--no-cdn          跳过 CDN 收藏下载
--no-wxgf         跳过 wxgf/hevc 转码
--notype          平铺模式输出到 emoticon_export_all/（组名_表情名 / favorite_序号）
--keep-decrypted  保留中间解密文件与临时 db
```

`--data-dir` 可省略；省略时按上文"多来源定位链"自动寻找。

---

## 实测记录（本仓库修复后）

测试环境：Windows 11 + 微信 4.1.13.12（`Weixin.exe` 运行中，未以管理员身份运行）

| 路径 | 结果 |
|---|---|
| 密钥提取（菜单 5） | 内存 seed 候选约 5.8k 个，跨 2 个 wxid 候选校验命中；同时算出 emoticon key 与 V2 key |
| 表情导出（菜单 1） | 31 个包 / 186 张商店表情 / 265 张收藏（CDN 265/265）/ 34 未匹配，合计 485；wxgf 转码 67 张 |
| 聊天图片（菜单 2） | 22941 个 `.dat`，其中 V2 格式 8329 个 → 8327 个解密成功；输出 5024 jpg + 1577 png（hevc 转码 1727 张，0 失败） |
| 数据库（菜单 4） | 27/27 全部解密成功，逐个用 sqlite3 打开验证（`contact.db` 16 表、`message_1.db` 203 表、`general.db` 24 表…） |
| `--seed` 参数模式 | 通过（修复前该模式直接失败） |
| 产物完整性 | 抽查解码后图片可正常解码（含 8064×6048 照片、2560×1440 截图）；两条 wxid 定案路径产物逐字节一致 |

## 常见问题

- **报"扫不到 seed / 解不出密钥"**：先确认微信正在运行（内存扫描需要读 `Weixin.exe`）；仍失败时用管理员身份重跑一次（个别系统会拒绝非提权进程读取）。
- **`ModuleNotFoundError: No module named 'Crypto'`**：`pip install pycryptodome`。
- **wxgf/动图没有转成 GIF/JPG**：`pip install imageio-ffmpeg`。
- **输出很大**：`decoded_images/`、`decrypted_db/`、`emoticon_export/` 合计可达 GB 级，不需要时直接删除；`--no-cdn`、`--no-wxgf` 可减小体积。
- **多个微信号**：脚本会打印实际使用的账号目录；如需指定，用 `--data-dir` 传具体路径。
- **密钥会变吗**：同一账号的 seed 随会话变化，密钥随之变化，因此每次使用都需要微信在运行状态重新提取。

---

## 致谢

本项目 fork 自 [CN-Grace/Wechat-Emoticon-Parser](https://github.com/CN-Grace/Wechat-Emoticon-Parser)，算法与整体架构来自原作者；本分支仅针对密钥解析、数据目录定位与 V2 图片 XOR key 抽样做了修复与增强。

密钥提取思路与内存扫描方法借鉴自以下开源项目：

- [TANGandXue/wcdb-key-tool](https://github.com/TANGandXue/wcdb-key-tool) — WCDB 数据库运行时扫描解密
- [LifeArchiveProject/WeChatDataAnalysis](https://github.com/LifeArchiveProject/WeChatDataAnalysis) — 密钥派生公式与候选验证方法
- [WeChatMsgDump](https://github.com/junuo-S/WeChatMsgDump) — 进程内存读取架构
- [93857536-pixel/WeChatExporter](https://github.com/93857536-pixel/WeChatExporter) — 表情 CDN 下载与 wxgf 解析逻辑
- [CipherTalk](https://github.com/CipherTalk/wechat-key-tool) — 账号 seed 提取方法

## License

MIT（见 [LICENSE](LICENSE)，保留原作者 CN-Grace 的版权声明）

## 免责声明

本工具用于解密**本机、本人账号**的本地缓存数据（表情包、聊天图片、数据库），仅供个人数据备份与研究学习。
请遵守所在地区法律法规，勿用于他人数据或任何未经授权的用途。
