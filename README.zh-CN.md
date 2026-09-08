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

以上是**服务器那半边**。还有一个可选的 **PC 那半边** `install-windows.ps1` —— 如果你要的不只是「响两声」，而是「Claude 需要你」时是一个真正不同的音色，见 [给「Claude 需要你」换一个真正不同的音色](#给claude-需要你换一个真正不同的音色)。

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
| **一声** | 某个会话干完一轮：你自己的会话响在它自己的终端，你在 `claude agents` UI 里起的会话响在 UI 所在的终端 | `Stop` hook |
| **两声** | Claude 卡在你身上：工具权限、要你回答问题、MCP 表单、后台 agent 等你输入 | `Notification` hook，matcher 为 `permission_prompt` / `elicitation_dialog` / `elicitation_url_dialog` / `agent_needs_input`；另加一个 `PreToolUse` hook 接在 `AskUserQuestion` 上，问题一提出就响，不用等约 7 秒后的通知 |

以及两种以前会响、1.2 起不再响的情况：

- **空闲回声。** Claude Code 在每轮结束约 60 秒后会发一个 `idle_prompt` 通知。紧跟在「done」一声之后的它纯属重复：`bell.sh` 按会话记录上次结束时间，75 秒内的 `idle_prompt` 直接吞掉。而**没有**近期结束记录却冒出来的 `idle_prompt`，说明有个对话框挂着没人理 —— 这种响两声。
- **噪音通知类型。** `auth_success`、`agent_completed`、`elicitation_complete` 等根本不订阅。

1.4 起又多了两种：

- **后台任务还在跑时的 Stop。** 主 agent 每让出一次控制权都触发一次 `Stop`，包括「说完话、转去等后台 subagent」的那一刻 —— 长任务因此每次被唤醒都响一声「done」。Stop 的 payload 里带 `background_tasks`，只要其中还有 running / pending / backgrounded 的，`bell.sh` 就把这次 Stop 当成暂停而非结束，不响。真正结束的那次 Stop 没有在途任务，照响。
- **同一个问题响第二声。** 一次 `AskUserQuestion` 会先立刻触发 `PreToolUse`，几秒后又为同一个对话框发一个 `permission_prompt` 通知。两者都接到 `ask` 上 —— 前者让你第一时间听到，后者兜底 —— `bell.sh` 按会话 15 秒内只响一次。

1.5 起有一种情况重新响了：

- **你在 `claude agents` UI 里起的会话。** 1.2 到 1.4 把它们当「下属会话」静音，理由是派生会话的一轮结束并不等于你关心的那件事做完。这条理由对 subagent 和 teammate 成立，对你亲手起的 agent 不成立 —— 它的一轮结束恰恰就是你在等的那个「干完了」；何况用来认出派生会话的环境标志（`CLAUDE_CODE_SESSION_KIND=bg` 等）从 Claude Code 2.1.233 前后起就传不到 hook 进程里了，那段判定早成了死代码。它当初要防的假「done」（只是在等后台任务的那种 Stop）现在由 `background_tasks` 过滤器负责。所以 1.5 起 agents UI 里的会话和别的会话一样响「done」和「ask」，响在 UI 所在的终端。为了让这一声真能听见还改了什么，见[铃打到哪个终端](#铃打到哪个终端)。

## 给「Claude 需要你」换一个真正不同的音色

响几声是一个维度，音色是另一个 —— 走 SSH 音色看似锁死了：BEL 只能播它所在终端 profile 配置的那**一个** `bellSound`。突破口在于：*每个 profile 各有各的* `bellSound`。第二个 profile 开的第二个标签页，**就是**第二种声音。

**Windows Terminal —— 在你 PC 上跑一条命令：**

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

（如果你的执行策略本来就允许跑本地脚本，直接 `.\install-windows.ps1` 也行。Windows 出厂是 `Restricted`，这种情况下跑 `.ps1` 会报 "running scripts is disabled on this system" —— 上面这种写法只对这一次运行放行，不改动系统任何设置。）

它会当场合成一个短促的「滴滴」wav（不用下载）、加一个把 BEL 映射到这个音的 profile，并把该 profile 的启动命令直接设成 `bell.sh listen` —— 于是**开标签页本身就是全部操作**，不用敲任何命令。它复用你现有 SSH profile 的连接命令、先备份 `settings.json`、可重复运行；`-Uninstall` 原样撤销。

```powershell
.\install-windows.ps1 -SshCommand "ssh myserver"   # 自动识别不了时手工指定
.\install-windows.ps1 -Uninstall
```

**其他终端 —— 同样的事手工做一遍：**

1. 复制你的 SSH profile，给副本配一个不同的响铃音（iTerm2、kitty、WezTerm、GNOME Terminal 都是按 profile 配的）。
2. 用那个 profile 开一个标签页，SSH 到服务器，运行 `~/.claude/hooks/bell.sh listen`。

两种方式都一样：标签页保持打开 —— 连上时会发一声试音，让你先听听自己选了什么。之后权限请求和问题就响在**那边**、用那个 profile 的音色；「done」仍然在你的会话终端上响原来的音。

有监听终端时，ask/idle 只发**一声** BEL：音色已经承担了区分职责，第二声纯属多余 —— 而且一个短促的「滴滴」wav 本来就该听成滴滴，而不是滴滴…滴滴。没有监听终端时仍然响两声，因为那时候节奏是唯一的区分信号。

`listen` 把标签页的 pid 和 tty 注册到 `~/.claude/hooks/bell.tty.ask`。ask/idle 路径优先查它（下文的 strategy 0），监听进程没了就自动回退到常规策略：关标签页或断线都会通过 trap 注销，残留文件也会先做存活检查再忽略。同一时间只有一个监听终端 —— 最后一次 `listen` 生效。

每次提醒还会在那个标签页打印一行，于是它顺便成了「谁在等你」的日志：

```
[10:32:49] myproject · AskUserQuestion · Which IP is right?
[10:41:07] myproject · permission_prompt · Claude needs your permission to use Bash
```

手工把 `listen` 写进 profile 时：把你平时 SSH profile 的参数原样保留（非默认端口的 `-p` 也别丢），再加 `-t` —— 否则 ssh 不会给命令分配 tty，监听脚本没法响；它会说明原因并停留 30 秒再退出，标签页不至于一闪而过。路径用相对远端家目录的写法，可以绕开 cmd、PowerShell、bash 对 `~` 各不相同的引号规则：

```
ssh -t -p 22 you@host .claude/hooks/bell.sh listen
```

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

`bell.sh` 按四级策略定位目标，全部失败就静音：

0. 注册过的 `listen` 监听终端 —— 只用于 ask/idle，见上一节
1. `/dev/tty` —— 控制终端，前台会话走这条
2. 沿进程树上溯，找有 tty 的祖先
3. 正在运行的 `claude agents` UI 所占的 tty —— 给它起的那些会话用。后台 daemon 给每个这种会话单独托管了一个 pty（会话 → `claude bg-pty-host` → `claude daemon run`），那就是它的控制终端，第 1、2 步都能「找到」它 —— 可它背后没接任何终端模拟器，写进去的 BEL 谁也听不见。所以 `bell.sh` 在走第 1、2 步**之前**先查祖先里有没有 daemon 的托管进程，有就直接跳到这一步（日志：`daemon-hosted session …`）

刻意**没有**「最近活跃的登录 pts」这种兜底。早先版本试过：最近活跃的 pts 就是**你正盯着的那个窗口**，于是某个不相干项目的后台会话干完活，铃响在你眼前这个空闲终端上，体感是**「明明没任务却在响」**。目标不明确时（同时开着好几个 agents UI）也一样静音而不是乱猜。宁可漏一声，不能响错地方。

排查很简单，`bell.sh` 每个决定都记日志：

```
$ tail ~/.claude/hooks/bell.log
2026-09-08 12:11:39 [done] strategy2 walk found /dev/pts/5        ← 你的会话，响
2026-09-08 12:12:44 [done] skip: 1 background task(s) in flight …  ← 只是暂停，静音
2026-09-08 12:13:44 [idle] skip: idle echo 60s after …             ← done 的回声，静音
2026-09-08 12:15:02 [done] daemon-hosted session (ancestor pid 3903217: claude bg-pty-host), …
2026-09-08 12:15:02 [done] strategy3 agents UI tty /dev/pts/0      ← agents UI 里的会话干完了，响在 UI 那边
2026-09-08 12:15:20 [ask]  BEL sent to /dev/pts/5                  ← 需要你，响
```

## 排查

| 现象 | 查什么 |
|---|---|
| 没任务却在响 | 基本都是 readline 而非 hook —— 见上一节，`--quiet-readline` 可修 |
| 完全没声音 | `tail ~/.claude/hooks/bell.log`。看到 `strategy1`/`strategy2`/`strategy3` 后面跟着 `BEL sent`，就说明服务器侧没问题，是终端配置的事 |
| 日志写 `no controlling tty` | 后台会话且无处可响：祖先里没有终端，也没开着 `claude agents` UI。设计上就不响 |
| agents UI 里的会话干完了没声 | `tail bell.log`。1.5 起应先有 `daemon-hosted session …`，后跟 `strategy3 agents UI tty`。若反而是 `strategy2 walk found`，说明 daemon 托管进程的 argv 里不再有 `bg-pty-host` / `bg-spare` —— 提 issue 时附上 `ps -o pid,ppid,tty,args -p <会话 pid>` 及其父进程的同样输出。`no controlling tty` 则是当时没开 agents UI |
| 每次「done」一分钟后又响两声 | 那是本该被过滤的 `idle_prompt` 回声 —— 日志里应有 `skip: idle echo`。真响了就是状态目录 `~/.claude/hooks/bell.state.d/` 写不进去 |
| 日志里什么都没有 | hook 没接上。重跑 `./install.sh`，顺便看下 `~/.claude/settings.json` |
| tmux 里没声 | tmux 吞 BEL：`set -g bell-action any` + `set -g visual-bell off` |
| screen 里没声 | `~/.screenrc` 加 `vbell off` |
| 响了但不是自定义音 | 终端回退到系统蜂鸣了 —— 检查 `bellSound` 路径存在且是 `.wav` |
| 直连正常，跳板机静音 | 嵌套 SSH 转发字节流没问题，确认每一跳都分配了 tty（`ssh -t`） |
| alerts 标签页提示 "no terminal attached" 然后关掉 | 启动命令少了 `-t`：`ssh host <cmd>` 不分配 tty，`ssh -t host <cmd>` 才分配 |
| alerts 标签页连接超时，会话标签页却正常 | 服务器 sshd 在非默认端口，alerts 的命令把 `-p` 丢了。照抄会话 profile 的完整 ssh 参数 |
| 一个长任务中「done」反复响 | 每一声都是后台 subagent 跑着时的一次 Stop。1.4 起日志里应有 `skip: … in flight`；还响的话，说明你的 Claude Code 版本太老，Stop payload 里没有 `background_tasks` |

## 依赖

- bash
- procps 的 `ps`（BusyBox 的 `ps` 不支持 `-o tty=`；Alpine 上 `apk add procps`）
- python3 **或** jq，用于安全合并 `settings.json`
- 运行时的 python3 可选：有它，监听页那行会带上问题原文，在途检查也是真正解析 payload；没有它两者都平稳降级
- Claude Code ≥ 2.1.198 才有 `agent_needs_input` 这个通知 matcher；老版本会忽略不认识的 matcher，其余功能不受影响
- SSH 会话 —— 本地控制台、web 版、IDE 插件都没有 pts，这套方案在那些场景下静音

## License

MIT
