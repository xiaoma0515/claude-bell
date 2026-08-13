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

两种声音，两种含义：

| 声音 | 含义 | 接线 |
|---|---|---|
| **一声** | **你自己的**会话干完一轮 | `Stop` hook |
| **两声** | Claude 卡在你身上：工具权限、要你回答问题、MCP 表单、后台 agent 等你输入 | `Notification` hook，matcher 为 `permission_prompt` / `elicitation_dialog` / `elicitation_url_dialog` / `agent_needs_input` |

以及三种以前会响、1.2 起不再响的情况：

- **subagent / teammate 干完活。** 作为下属 agent 起的会话（agent teams、`claude agents` UI 里起的后台会话）每完成一次消息交换就触发一次 `Stop` —— 离你真正关心的任务跑完还远着呢，以前却会在你的终端上响出假的「干完了」。这类被派生的会话带着环境标志（`CLAUDE_CODE_SESSION_KIND=bg`、`CLAUDE_BG_SOURCE`、`CLAUDE_CODE_SESSION_NAME` 等），hook 会继承会话进程的环境，`bell.sh` 据此认出自己身处何地，把「done」按下不响。但它们的**权限请求照样响两声** —— 那是真的需要你。
- **空闲回声。** Claude Code 在每轮结束约 60 秒后会发一个 `idle_prompt` 通知。紧跟在「done」一声之后的它纯属重复：`bell.sh` 按会话记录上次结束时间，75 秒内的 `idle_prompt` 直接吞掉。而**没有**近期结束记录却冒出来的 `idle_prompt`，说明有个对话框挂着没人理 —— 这种响两声。
- **噪音通知类型。** `auth_success`、`agent_completed`、`elicitation_complete` 等根本不订阅。

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

> **你运行它的那个 shell 还会继续响。** readline 只在启动时读一次 `~/.inputrc`，
> 所以你装的时候所在的那个会话仍然是旧设置。要么敲 `bind -f ~/.inputrc` 当场生效，
> 要么断开重连 —— 新会话已经是对的。用 `bind -v | grep bell-style` 确认。

**分不清某次响是不是本项目发的？** `bell.sh` 每次被调用都会记日志。如果你听见响的那一刻 `~/.claude/hooks/bell.log` 没有新增行，那 hook 压根没跑，声音是别处来的。

## 铃打到哪个终端

如果你会用后台 agent、开多个终端、或者同时跑几个项目，那么**每一个会话都是完整的 Claude Code 会话，触发的是同一套全局 hook** —— 因为 `~/.claude/settings.json` 是全局的。所以「BEL 该打到哪」就是全部问题所在。

`bell.sh` 按三级策略定位目标，全部失败就静音：

1. `/dev/tty` —— 控制终端，前台会话走这条
2. 沿进程树上溯，找有 tty 的祖先
3. 正在运行的 `claude agents` UI 所占的 tty —— 给它派生出的那些祖先里压根没有 tty 的会话发权限提示用

刻意**没有**「最近活跃的登录 pts」这种兜底。早先版本试过：最近活跃的 pts 就是**你正盯着的那个窗口**，于是某个不相干项目的后台会话干完活，铃响在你眼前这个空闲终端上，体感是**「明明没任务却在响」**。目标不明确时（同时开着好几个 agents UI）也一样静音而不是乱猜。宁可漏一声，不能响错地方。

排查很简单，`bell.sh` 每个决定都记日志：

```
$ tail ~/.claude/hooks/bell.log
2026-08-13 10:38:19 [done] strategy2 walk found /dev/pts/5      ← 你的会话，响
2026-08-13 10:38:19 [done] skip: subordinate agent session …    ← teammate 干完一轮，静音
2026-08-13 10:38:20 [idle] skip: idle echo 1s after …           ← done 的回声，静音
2026-08-13 10:38:20 [ask]  BEL sent to /dev/pts/5               ← 需要你，响
```

## 排查

| 现象 | 查什么 |
|---|---|
| 没任务却在响 | 基本都是 readline 而非 hook —— 见上一节，`--quiet-readline` 可修 |
| 完全没声音 | `tail ~/.claude/hooks/bell.log`。看到 `strategy1`/`strategy2` 就说明服务器侧没问题，是终端配置的事 |
| 日志写 `no controlling tty` | 那个会话是后台 agent，设计上就不响 |
| subagent/teammate 干完还是响「done」 | `tail bell.log` —— 修好的样子是 `skip: subordinate agent session`。如果反而是 `BEL sent`，说明那个派生会话没带任何已知环境标志；提 issue 时附上 `tr '\0' '\n' < /proc/<pid>/environ \| grep CLAUDE` |
| 每次「done」一分钟后又响两声 | 那是本该被过滤的 `idle_prompt` 回声 —— 日志里应有 `skip: idle echo`。真响了就是状态目录 `~/.claude/hooks/bell.state.d/` 写不进去 |
| 日志里什么都没有 | hook 没接上。重跑 `./install.sh`，顺便看下 `~/.claude/settings.json` |
| tmux 里没声 | tmux 吞 BEL：`set -g bell-action any` + `set -g visual-bell off` |
| screen 里没声 | `~/.screenrc` 加 `vbell off` |
| 响了但不是自定义音 | 终端回退到系统蜂鸣了 —— 检查 `bellSound` 路径存在且是 `.wav` |
| 直连正常，跳板机静音 | 嵌套 SSH 转发字节流没问题，确认每一跳都分配了 tty（`ssh -t`） |

## 依赖

- bash
- procps 的 `ps`（BusyBox 的 `ps` 不支持 `-o tty=`；Alpine 上 `apk add procps`）
- python3 **或** jq，用于安全合并 `settings.json`
- Claude Code ≥ 2.1.198 才有 `agent_needs_input` 这个通知 matcher；老版本会忽略不认识的 matcher，其余功能不受影响
- SSH 会话 —— 本地控制台、web 版、IDE 插件都没有 pts，这套方案在那些场景下静音

## License

MIT
