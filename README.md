# 百度网盘上传值守脚本 v2（无人值守 → 自动关机）

睡觉前把上传任务丢给百度网盘、打开传输窗口，这个脚本帮你在后台值守：

1. 每 `POLL_SECONDS` 秒把百度网盘窗口的**全部 UI 元素**扫一遍（不只是按钮）；
2. 发现「重试 / 重新上传 / 继续上传」按钮 → **自动点击**（失败自动续传，暂停的也会被点「继续上传」恢复）；
3. 连续 `DONE_QUIET_CHECKS` 轮**没有失败项、也没有进行中上传** → 判定全部传完 → **自动关机**。

脚本文件：`baidu_upload_watch.sh`（本 README 对应 v2）

## v2 相比 v1 的关键修复

- **修复 v1 扫不到任何元素的 bug**：旧写法在 AppleScript 里必然报错被 try 吞掉，`clicked` 永远是 0；
- **修复误关机风险**：v1 的「进行中」判定只看按钮，而「正在上传 2.3MB/s」是静态文本——v2 扫全部元素的文本并用速度字样（`/s`）兜底；
- **armed 武装机制**：没见过传输窗口/上传活动就**绝不关机**，防止启动太早误判；
- **重试点击上限**：某个文件永久失败不会导致整夜死循环点重试；
- **窗口丢失保护**：传输窗口被关掉只会警告、不会关机；
- **进程退出判定**：百度网盘退出连续多轮 → 视为任务结束 → 关机；
- 调试期间修掉的三个 AppleScript 深坑（供后续维护参考）：
  - `system attribute` 读中文环境变量后在 tell 块里参与比较 → 不可捕获的 -1700（已改为 shell 直接内联列表字面量）；
  - `every process whose background only is false` 子句在进程瞬间退出时抛不可捕获的 -1700（已改为逐进程防御式读取）；
  - 变量名 `outLines` 与 System Events 词典的 UI 类 `outlines` 大小写不敏感冲突 → -10006 静默失败（已改名 `accLines`）。

---

## 一、开始前只做一件事：授权辅助功能

AppleScript 要读/点百度网盘的界面，必须把运行脚本的程序加进**辅助功能**白名单：

- **系统设置 → 隐私与安全性 → 辅助功能** → 点 `+` → 把**终端**（Terminal.app，或你运行脚本的程序）加进去并勾选
- 加完还是报错 → 重启一次终端让授权生效

不授权的表现：`found=1` 但 `wins=0`，日志里出现 `-25211` 报错。

---

## 二、第一次必跑：--dump 校准

不同版本百度网盘的界面文字可能不一样。第一次先把脚本「眼中」的界面导出来核对关键词：

```bash
cd /Users/rancho/Documents/Acode/Studio/Outbox/Automation
chmod +x baidu_upload_watch.sh
./baidu_upload_watch.sh --dump
```

前提：百度网盘已打开、**传输窗口已打开**（有失败项就让它挂着别管）。

输出两部分：

- `baidu_ui_dump.txt`：全部窗口的元素树（角色 / 可用性 / 名称 / 描述 / 值 / 标题）；
- 终端上的关键字命中统计（重试、正在上传、暂停……各有几处）。

对照检查：

| 检查点 | 不对就改 |
|--------|----------|
| 传输窗口出现在 dump 里 | `WINDOW_TITLE`（当前 `传输\|提示\|警告\|错误`） |
| 「重试」按钮文字能命中 | `CLICK_KEYWORDS`（当前 `重试\|重新上传\|继续上传`） |
| 「正在上传/2.3MB/s」类字样存在 | `BUSY_KEYWORDS` 和 `SPEED_HINT` |

> 若 dump 为空但窗口明明开着 → 十有八九是辅助功能没授权；实在不行可退回 [BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go) 命令行上传（`BaiduPCS-Go upload 本地目录 /目标目录`），失败重传和完成后关机都能在 shell 里稳稳实现，不依赖 UI。

---

## 三、干跑确认（不点击、不关机）

```bash
./baidu_upload_watch.sh --debug
```

每 `POLL_SECONDS` 秒输出一行：

```
[debug] clicked=0 busy=1 found=1 wins=1 fb=0 done=0 cap=0 armed=1 quiet=0/4 累计点击=0 扫描耗时=1s
```

| 字段 | 含义 |
|------|------|
| `clicked` | 本轮点了几次重试 |
| `busy` | 是否扫到「进行中」（含速度字样兜底） |
| `found` | 是否找到百度网盘进程 |
| `wins` / `fb` | 实际扫描的窗口数 / 是否在兜底扫全部窗口 |
| `armed` | 是否已「武装」（见过窗口或活动；未武装绝不关机） |
| `quiet` | 已连续几轮「无失败、无进行中」 |
| `cap` | 因元素太多被截断的窗口数（出现就调大 `POLL_SECONDS`） |

确认：传输中 `busy=1`；有失败按钮时 `clicked` 会涨；传完后 `quiet` 涨到 4/4。`fb=1` 说明没找到标题匹配的窗口（在兜底扫全部窗口，能工作但建议核对 `WINDOW_TITLE`）。

---

## 四、正式值守

先把上传任务加入百度网盘队列、**打开传输窗口**，然后：

```bash
# 前台跑, 关机前 10 秒按回车可取消
./baidu_upload_watch.sh

# 不确认直接关机
./baidu_upload_watch.sh --yes

# 挂后台, 关掉终端也能继续值守（推荐睡前这样跑）
nohup ./baidu_upload_watch.sh --yes >/dev/null 2>&1 &
```

关机条件（满足其一，且必须已 armed）：

1. 传输窗口可见 + 连续 `DONE_QUIET_CHECKS` 轮无任务（且已见过活动或超过启动缓冲期）；
2. 百度网盘进程连续 `EXIT_CONFIRM_ROUNDS` 轮消失；
3. 达到 `MAX_HOURS` 最长值守时间（0 = 不限）。

关机优先走 System Events；被拒则回退 `sudo shutdown -h now`（需配置免密 sudo，可选）：

```bash
echo 'rancho ALL=(ALL) NOPASSWD: /sbin/shutdown' | sudo tee /etc/sudoers.d/nopass-shutdown
```

### 两个必须知道的坑

- **传输窗口必须保持打开**。窗口被关 → 脚本只会兜底扫描并警告，永远不会自动关机（防止误判）。
- **别让 Mac 睡着**。合盖/休眠后脚本和网络都会停，上传不会继续。睡前建议：系统设置 → 锁定屏幕/显示器关闭时间调大，或插电源 + `caffeinated -i` 之类只防系统睡眠的方案（外接显示器合盖可设置「防止自动进入睡眠」）。

---

## 五、可调参数（脚本顶部）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `POLL_SECONDS` | `8` | 每轮间隔（秒）；窗口元素多时可调大 |
| `DONE_QUIET_CHECKS` | `4` | 连续多少轮无任务判定传完（4 轮 ≈ 32 秒） |
| `START_GRACE_SECONDS` | `180` | 启动缓冲期：期间从未见过活动就不判定完成 |
| `MAX_RETRY_CLICKS` | `60` | 累计重试点击上限，0=不限；达到后只等剩余任务传完 |
| `MAX_HOURS` | `0` | 最长值守小时数，0=不限；超时强制关机 |
| `EXIT_CONFIRM_ROUNDS` | `5` | 百度进程连续消失多少轮判定结束 |
| `NOTIFY` | `1` | 关键事件发 macOS 通知 |
| `APP_KEYWORDS` | `百度网盘\|BaiduNetdisk` | 进程名匹配，`\|` 分隔 |
| `CLICK_KEYWORDS` | `重试\|重新上传\|继续上传` | 命中就点的按钮文字 |
| `BUSY_KEYWORDS` | `正在上传\|传输中\|排队中\|等待中\|暂停\|取消上传\|继续上传` | 出现即视为「还在忙」 |
| `DONE_KEYWORDS` | `全部完成\|已完成` | 完成字样（仅日志参考） |
| `SPEED_HINT` | `/s` | 文本含此子串（如 2.3MB/s）视为进行中，留空关闭 |
| `WINDOW_TITLE` | `传输\|提示\|警告\|错误` | 深度扫描的窗口标题；一个都没匹配到时兜底扫全部 |

---

## 六、日志

脚本同目录：

```
baidu_upload_watch.log       # 主要日志（含每轮 debug、点击、关机判定）
baidu_upload_watch.log.err   # osascript 原始报错（一般空着；出现 -25211 = 辅助功能没授权）
baidu_ui_dump.txt            # --dump 导出的界面元素树
```

## 七、常见问题

- **`found=1` 但 `wins=0`**：辅助功能没授权（看 `.err` 文件有无 -25211），或百度网盘根本没开窗口。
- **有失败项却不点重试**：按钮文字不在 `CLICK_KEYWORDS` 里 → `--dump` 看真实文字再补。
- **一直 `fb=1` 警告**：传输窗口标题不含 `WINDOW_TITLE` 里任何词 → `--dump` 看窗口实际标题，补进 `WINDOW_TITLE`。
- **传完了却不关机**：看 `armed` 是否为 0（没武装——没见过窗口/活动）；或 `busy` 卡 1（某条 `BUSY_KEYWORDS` 在传完后仍常驻，如「暂停」按钮文字——用 `--dump` 核对并精简）。
- **关机弹确认框**：配置免密 sudo 走回退通道更省心。

---

## 推荐

如果你在找 OpenAI 兼容的大模型 API 中转 / 聚合服务，可以试试 [vsllm.cc](https://vsllm.cc/register?aff=K1Pe)（推荐链接）。
