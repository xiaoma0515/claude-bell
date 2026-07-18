# claude-bell

给跑在**无头服务器**上的 [Claude Code](https://claude.com/claude-code) 加终端提示音。

SSH 上机器、丢一个长任务、切窗口去干别的 —— 这东西让机器在 Claude 干完活或需要你确认时响一声。不需要声卡，不需要桌面，不需要常驻进程。

[English](README.md)

---

## 为什么不直接播个声音

无头 VPS 上根本没东西能播。没有 PCM 设备（`/dev/snd` 里只有 `seq` 和 `timer`），`paplay`/`aplay` 全是死路；没有 `DISPLAY`，`notify-send` 发出去也没人收。

真正管用的是终端最老的那个招数：往 Claude Code 所在的 pts 里写一个 **BEL 字节**（`\a`，`0x07`）。SSH 顺着已有连接把它带回去，你本地的终端模拟器负责播声音。

```
   ┌─────────────────── VPS ────────────────────┐      ┌──────── 你的 PC ─────────┐
   │                                            │      │                          │
   │  Claude Code                               │      │                          │
   │      │ Stop / Notification hook            │      │                          │
   │      ▼                                     │      │                          │
   │  bell.sh ──── 往 /dev/pts/N 写 \a ─────────┼─SSH──┼──> 终端模拟器播放声音    │
   │                                            │      │                          │
   └────────────────────────────────────────────┘      └──────────────────────────┘
        ↑ 本仓库装的是这半边                             ↑ 配一次，对所有 SSH 主机生效
```

这个切分很关键：**服务器侧是每台机器都要装的，声音本身则 100% 在 PC 侧。** VPS 想装几台装几台，终端只配一次。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaoma0515/claude-bell/main/install.sh)
```

> 用进程替换 `<(...)`，**不要** `curl ... | bash`。管道起的 shell 没有控制终端，装完的自检会误报失败，测试音也听不到。同理，远程驱动时记得 `ssh -t`。

或者直接 clone：

```bash
git clone https://github.com/xiaoma0515/claude-bell.git
cd claude-bell && ./install.sh
```

安装器是**幂等**的，随时重跑即升级。它会合并进已有的 `~/.claude/settings.json` 而不是覆盖，写入前先摘掉自己上次留下的条目（所以不会越装响得越多），动过的文件都留备份。

```
./install.sh                   安装 / 升级
./install.sh --check           只体检，不碰任何文件
./install.sh --uninstall       卸载 hook 和脚本
./install.sh --quiet-readline  顺便关掉 readline 自己的铃（见下）
```

## 配置终端（PC 那半边）

终端收到 BEL 得真的出声。每台电脑配一次，不是每台主机。

**Windows Terminal** —— 在 `settings.json` 里，你用来 SSH 的那个 profile 下：

```json
{
  "bellStyle": "audible",
  "bellSound": "C:/Users/you/sounds/ding.wav"
}
```

`bellSound` 接受单个路径或路径数组（数组会随机挑一个）。需要 Windows Terminal 1.15+。注意这是**终端级**配置，没法只对 Claude Code 生效 —— 任何东西敲响铃都会播这个音。

**其他终端** —— 一般叫 "audible bell"：

| 终端 | 位置 |
|---|---|
| iTerm2 | Settings → Profiles → Terminal → 取消勾选 *Silence bell* |
| macOS Terminal.app | Settings → Profiles → Advanced → *Audible bell* |
| GNOME Terminal | Preferences → 对应 profile → Sound → *Terminal bell* |
| kitty | `enable_audio_bell yes`（自定义音用 `bell_path`） |
| WezTerm | `audible_bell = "SystemBeep"` |
| Alacritty | 没有内置播放，用 `bell.command` 钩子调播放器 |

## 什么时候响

| Hook | 时机 | 声音 |
|---|---|---|
| `Stop` | Claude 干完一轮 | 一声 |
| `Notification` | Claude 要你确认（权限提示、空闲提醒） | 两声 |

## 「装完之后开始乱响」

基本可以断定是 **bash**，不是 Claude Code。

打开响铃是**终端级**开关，没法只对某个程序生效 —— 终端收到的**任何** BEL 字节都会播。而 readline 一直在悄悄发这个字节：只要某个键按下去什么也干不成，它就响。

- 空行按退格
- 光标在行首按左方向键、在行尾按右方向键
- Tab 补全没有候选
- 反向搜索没有匹配

这个行为比本项目早了几十年。变的只是你把终端配成了「收到 BEL 就出声」，于是**开始听得见**了。而促使你去配这个开关的正是本项目，所以体感上像是它造成的。

关掉 readline 的铃，同时不影响本项目的提示音：

```bash
./install.sh --quiet-readline
```

它往 `~/.inputrc` 写 `set bell-style none`。安全的原因是：`bell.sh` 直接往 pts 设备写 BEL，readline 根本不在这条路径上，提示音照响。另外如果 `~/.inputrc` 原本不存在，安装器会先补一行 `$include /etc/inputrc` —— 因为一旦这个文件存在，bash 就不再读 `/etc/inputrc`，会丢掉发行版的键位绑定（很多系统上的 Home/End/Delete）。

新开的 shell 生效（或者当场 `bind -f ~/.inputrc`）。

**分不清某次响是不是本项目发的？** `bell.sh` 每次被调用都会记日志。如果你听见响的那一刻 `~/.claude/hooks/bell.log` 没有新增行，那 hook 压根没跑，声音是别处来的。

## 后台 agent 刻意不响

如果你会用后台 agent、开多个终端、或者同时跑几个项目，那么**每一个会话都是完整的 Claude Code 会话，各自触发自己的 `Stop` hook** —— 因为 `~/.claude/settings.json` 是全局的。

早先的版本有第三级兜底策略：会话没有控制终端时（后台 agent 正是这种情况，它们是脱离终端的 daemon 的子进程），就把 BEL 打到「最近活跃的登录 pts」。听着挺合理，其实是个 bug —— 最近活跃的 pts 就是**你正盯着的那个窗口**。于是某个不相干项目的后台 agent 干完活，铃响在你眼前这个空闲终端上。体感就是**「明明没任务却在响」**。

所以现在 `bell.sh` 只有两级策略，没有兜底：

1. `/dev/tty` —— 控制终端
2. 沿进程树上溯，找有 tty 的祖先

两级都失败，说明没有任何终端是真正属于这个会话的，直接静音退出。这个取舍是明确的：后台干完不响，你自己去看。总好过响错终端。

排查很简单，`bell.sh` 会记下是哪级策略赢的：

```
$ tail ~/.claude/hooks/bell.log
2026-07-18 09:19:11 [done] strategy2 walk found /dev/pts/5    ← 前台，正常
2026-07-18 09:11:25 [done] skip: no controlling tty           ← 后台，静音
```

## 排查

| 现象 | 查什么 |
|---|---|
| 没任务却在响 | 基本都是 readline 而非 hook —— 见上一节，`--quiet-readline` 可修 |
| 完全没声音 | `tail ~/.claude/hooks/bell.log`。看到 `strategy1`/`strategy2` 就说明服务器侧没问题，是终端配置的事 |
| 日志写 `no controlling tty` | 那个会话是后台 agent，设计上就不响 |
| 日志里什么都没有 | hook 没接上。重跑 `./install.sh`，顺便看下 `~/.claude/settings.json` |
| tmux 里没声 | tmux 吞 BEL：`set -g bell-action any` + `set -g visual-bell off` |
| screen 里没声 | `~/.screenrc` 加 `vbell off` |
| 响了但不是自定义音 | 终端回退到系统蜂鸣了 —— 检查 `bellSound` 路径存在且是 `.wav` |
| 直连正常，跳板机静音 | 嵌套 SSH 转发字节流没问题，确认每一跳都分配了 tty（`ssh -t`） |

## 依赖

- bash
- procps 的 `ps`（BusyBox 的 `ps` 不支持 `-o tty=`；Alpine 上 `apk add procps`）
- python3 **或** jq，用于安全合并 `settings.json`
- SSH 会话 —— 本地控制台、web 版、IDE 插件都没有 pts，这套方案在那些场景下静音

## License

MIT
