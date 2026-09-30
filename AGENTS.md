# AGENTS.md — deepGit 工作区指南

deepGit Engine：基于 git 历史的本地项目群进度引擎（跨平台核心，**AI 无关**）。**100% 仓颉实现，零第三方依赖**（JSON/SHA-256/HTTP 服务/Markdown 渲染全部自研）。
外部依赖只有系统 `git` 与 `curl`。本仓库是引擎；各平台 UI 层在 deepgit-clients 仓库（macOS 客户端 deepGit.app 已实现：菜单栏常驻 + 主面板）。

## 构建与测试

```sh
# 环境（每次新 shell）
source ~/.local/share/cangjie/current/envsetup.sh
export SDKROOT="$HOME/.local/share/sdks/MacOSX.minimal/latest"  # macOS 26/27+ 必需，见下方说明

cd engine
cjpm build          # 构建 → target/release/bin/main
cjpm test           # 203 项测试
cjpm build -i       # 增量构建（改单文件时更快）
```

**运行二进制必须带运行时路径**（或直接用 `scripts/deepgit.sh` 包装）：

```sh
sh scripts/deepgit.sh status --json     # 推荐：自动处理工具链与 rpath
# 或
engine/target/release/bin/main status
```

- **macOS 26/27+ 关键坑**：系统 SDK 的 `libSystem.tbd` 只声明 `arm64e-macos`，
  仓颉自带的 `ld64.lld` 15.0.4 无法解析，链接会报
  `malformed file` / `unknown architecture` / 大量 undefined symbol。
  **解法**：极简兼容 SDK（~2MB，只含 libSystem/libc/libm/libdl/libpthread 的 arm64-macos TBD），
  `scripts/install.sh` 会自动下载 macOS 15.5 SDK 并裁剪到 `~/.local/share/sdks/MacOSX.minimal/latest`；
  也可 `sh scripts/build-minimal-sdk.sh <源SDK目录>` 手动生成，或 `export DEEPGIT_SDKROOT=` 指定现成 SDK。
  STS 1.2.0 / 1.3.0-alpha 的链接器同样是 15.0.4，升版本解决不了此问题。
- **deepGit（mac 客户端）注意**：双形态——MenuBarExtra `.window` 弹窗（bar，辅助）+
  NSWindow 主面板（PanelWindowController 承载 PanelView，可 `--open-panel --project X --section milestones`
  深链启动）。**它是纯客户端**：数据走 `APIClient`（Engine.swift）调引擎 HTTP API，
  写操作 POST `/api/update|deep|milestones(/action)`；CLI 进程调用只用于发现引擎与拉起 serve。
  契约模型集中在 `Models.swift`，键名与引擎 `flow/status.cj`、`flow/dashboard.cj`、
  `kernel/milestones.cj` 严格同名——引擎改键 = 破坏契约。引擎 `status` 单项目返回裸对象、
  多项目返回 `{projects, summary}`，客户端两种都兼容（已实现）。
  MenuBarExtra 内容是**懒加载**的：启动期逻辑放 AppDelegate，别放 BarView 的 `.task`。
- **运行期 rpath**：`cjpm.toml` 的 `link-option` 内嵌了运行时库路径与
  `-headerpad_max_install_names`（后者用于让 `build.sh` 能追加 `@executable_path/../Frameworks`）。
  修改 link-option 后要 `rm -rf target` 全量重建，否则链接器参数不会生效。
- **`--static-std` 不可用**：静态链接 std 后二进制在 macOS 上 dyld 加载失败。保持动态链接 + rpath。
- 新增子包（如 `src/xxx/`）后若链接报 undefined symbol，执行 `rm -rf target` 重建——
  cjpm 的包发现缓存需要全量刷新。

## 架构边界（依赖方向严格单向，改前必看）

```
util → kernel → ai → flow → cli
       (↑ ai 只依赖 kernel/util，绝不反向依赖 flow)
```

- **`ai` 不得引入 `flow`**：上层编排（浅/深更新）在 `flow/`，它依赖 `ai`。
  曾因把更新管线放进 `kernel/` 造成 `ai ↔ kernel` 循环依赖，被迫提升为独立 `flow` 包。
  **新增「调 AI 做编排」的代码一律进 `flow/`。**
- `util/` 是叶子，只依赖仓颉标准库。`kernel/` 依赖 `util`。`cli/` 在最上层。

## 编码约定（仓颉特有，踩过的坑）

- **多行字符串必须以换行开头**：`"""` 后紧跟内容会报 `must start with newline character`。
  拼接长文本用 `StringBuilder`，不要硬凑多行字面量。
- **没有 `?:` 三元运算符**，写 `if (cond) { a } else { b }`（是表达式，可直接用于 `const`/实参）。
- **`Option` 没有 `orDefault`**；用 `match` 或本项目在 `Json` 上提供的 `getOr(obj, key)`。
- **整数运算会溢出抛异常**：SHA-256 这类位运算必须用 `.wrappingAdd()`（`+%` 不是合法语法）。
- **字符串按字节索引**：`s[..n]` 可能切断 UTF-8 多字节序列并抛
  `Invalid utf8 byte sequence`。**任何外部来源的字符串截断都用 `safeSlice(s, n)` / `truncateChars`**
  （`util/text.cj`）。这个 bug 只在真实中文项目上暴露，测试数据不易发现。
- **读外部数据用 `fromUtf8Lossy(bytes)`**（`util/text.cj`），不要用 `String.fromUtf8` ——
  提交信息/文件可能是 GBK 等非 UTF-8 编码（deepOffice 的 git 历史就是）。
- **`for-each-ref` 的字段分隔用 `%1f`**（会被展开为 0x1f）；
  `git log` 的 `--format` 里则必须写 `%x1f`。两者行为不同，已验证。
- **`std.unittest` 不是自动导入**：新增含 `@Test` 的文件必须在 import 区加
  `import std.unittest.*` 与 `import std.unittest.testmacro.*`。
- **仓颉标准库里没有 SHA-256 类型**（`std.crypto.digest` 只给 `Digest` 接口和 `digest()` 函数），
  所以 `util/sha256.cj` 是自研实现。
- **进程与时间 API 在 `std.env`**：`getCommandLine()`、`getProcessId()`、`getWorkingDirectory()`、
  `getVariable(key)`（返回 `?String`）；进程 id 在 `std.posix.getpid()`。
- **`String` 方法名**：没有 `trim()`，用 `trimAscii()`；没有 `trimLeft`，见 `src/cli/http.cj` 的 `trimLeftSlashes`。
- **`extend` 对 std 类型不跨包可见**（1.0.5 实测）：`isBlank()` 等扩展在各包的 `strx.cj` 里
  各声明一份（util/text.cj、kernel/flow/cli/ai 的 strx.cj）。别指望在 util 里 extend、其他包直接用。
- **面板级 git 操作走 `runGitOp` 白名单**（kernel/git.cj）：pull（--ff-only）/ push（无 upstream 自动
  补 -u origin）/ commit（必须带 message，身份用 `gitUserName/gitUserEmail` 兜底）/ stash / unstash / fetch。
  **不要往里加 reset/clean/force-push**——这是给 GUI 客户端的按钮用的，误触即事故。
  HTTP 入口 `POST /api/git`；文档内容 `GET /api/docs`（readProjectDocs 单文件 200KB 截断）。
  注意：release 二进制改了路由后必须 `cjpm build` 重出 release，`cjpm test` 只构建测试目标——
  客户端内嵌的是 release 引擎，曾因此出现「测试全绿但内嵌引擎没有新路由」。
- **`git worktree list` 不支持 `--format=`**，只有 `--porcelain`（records 以 `worktree ` 行开头）；
  `git stash list` 要用 `--pretty=format:`（`--format=` 会把 `%x1f` 原样输出，`%1f` 也一样）。
  porcelain/相对路径里的 `/tmp` 会被 git 输出成 `/private/tmp`——路径比较一律走 `util/paths.cj` 的
  `samePath()`（词法规范化 + macOS 符号链接容忍）。
- **引擎保持 AI 无关（deepDesign 模式，改前必读）**：`src/ai` 包已删除——provider/prompts 不在引擎里，
  规则启发式在 `kernel/narrative.cj`。AI 的配置、调用、工具循环全部在客户端（AIProvider.swift / AgentView.swift）。
  引擎对 agent 只暴露两个喂养端点：`/api/context`（flow/agent.cj，预算内 markdown 事实包）与
  `/api/tools`（工具清单）。**往引擎里加 LLM 调用 = 违反架构**；要让 agent 能做新动作，加引擎工具 + 更新清单即可。
  注意 `cjpm test` 不重建 release——改了路由必须 `cjpm build` 后再装，否则客户端内嵌引擎没有新端点。
- **CLI 位置参数解析统一走 `VALUE_FLAGS`**（`cli/cli.cj`）：新增「带值 flag」必须加进这个名单，
  否则它的值会被当成项目名（曾导致 `hook --source hook` 静默解析失败）。
- **`const` 不能用于数组字面量初始化**，用 `let`（如 `util/sha256.cj` 的 `SHA256_K`）。

## 关键不变量（做错很难回头）

1. **进度状态永不写进项目工作区。**
   状态在 `~/.deepgit/store/<projectId>/`（`state.json` / `progress.json` / `journal.jsonl`）。
   项目内只允许写：托管文档区域、可选的 post-commit 钩子。
   这条保证进度记录跨分支安全，且不污染 `git status`。

2. **文档只改托管区域。**
   `kernel/docs.cj` 的 `listRegions` / `upsertRegion` / `applyRegions` 是唯一写文档的入口。
   `upsertRegion` 里有「去时间戳后内容等价则不刷新」的逻辑，**不要删**——否则每次运行都会抖动文件。

3. **`git log` 解析依赖 `%x1f`/`%x1e` 分隔符**，字段顺序在 `kernel/git.cj` 的 `logCommits` 里，
   改格式必须同步改解析（`logRange`/`oldestCommits`/`authorStats` 都建立在此之上）。

4. **AI 失败必须降级而非中断**：`flow/update.cj` 与 `flow/deep.cj` 都用 `match` 而非 `try?`
   语义处理 `aiChatJson` 的失败，并在结果里回报 `aiError`。降级后仍要写进度库与日志。

5. **钩子必须后台异步且永不非零退出**：`post-commit` 与 `post-merge` 共用同一套托管块
   （`(deepgit track --quiet --source hook >/dev/null 2>&1 &)`），可重复安装/卸载而不破坏用户已有钩子内容。

6. **状态聚合并发化的边界**：`flow/status.cj` 的 `allProjectStatuses` 用 `std.sync.spawn` 并发采集，
   前提是「只读 + 每项目独立 store」。往 `projectStatus` 里加**写操作**前必须三思；
   若出现并发问题，最小回退是改回串行 for 循环。

6. **HTTP 服务是本地单用户设计**：`kernel` 层不假设并发安全；服务串行处理连接。
   不要把它暴露到公网（无鉴权 + CORS `*`）。`cli/http.cj` 的 `containsTraversal` 是路径穿越防护，勿删。

## 常用命令

```sh
# 引擎
sh scripts/deepgit.sh scan ~/dev --depth 4
sh scripts/deepgit.sh status --json | jq '.projects | length'
sh scripts/deepgit.sh update <项目> --no-ai      # 跳过 AI，用规则引擎
sh scripts/deepgit.sh deep <项目> --scope readme --dry-run
sh scripts/deepgit.sh serve --port 5177 --open

# 测试隔离（不污染真实 ~/.deepgit）
export DEEPGIT_HOME=/tmp/deepgit-test
cjpm test

# macOS 客户端（独立 SwiftPM 项目；主面板 + 菜单栏 bar，纯展示层）
cd clients/macos/deepGit
sh build.sh                    # swift build -c release + 组装 .app + ad-hoc 签名
open deepGit.app --args --open-panel    # 启动即开主面板（--project X 直达详情）
# 深链调试：--section milestones | --project deepGit
# 构建期会尝试把引擎（~/.local/bin/deepgit 或 engine/target/release/bin/main）
# 与仓颉运行时 dylib 内嵌进 .app（~59MB），使 app 可独立分发；不内嵌则按
# DEEPGIT_BIN → 内嵌副本 → ~/.local/bin → 登录 shell PATH 的顺序发现引擎。
```

## 数据与日志位置

```
~/.deepgit/
  config.json              全局配置（AI 预设、扫描根、服务端口）
  registry.json            已注册项目
  store/<projectId>/
    progress.json          各分支进度（结构化）
    state.json             运行元信息（上次更新/深度更新时间）
    journal.jsonl          追加式日志（机器读）
    journal.md             同上的人类可读版
    backups/               文档写入前的备份（保留 config.update.backupKeep 份）
    locks/                 并发锁
```

项目 ID = `p_` + SHA-256(规范化绝对路径) 前 12 位，路径不变则 ID 稳定。

## 已知边界

- SHA-256 自研（通过官方测试向量），**不用于密码学安全场景**。
- HTTP 服务无鉴权、CORS 全开、串行处理，仅适本地单用户。
- 深度更新的 `history` 章节不做语义去重，同义提交多时章节会长。
- 非 git 模式只能感知 mtime，无法得知改动内容。
- macOS 菜单栏应用为 ad-hoc 签名（`codesign -s -`），分发给他人时对方首次打开需在
  「系统设置 → 隐私与安全性」中放行。

<!-- deepgit:begin progress -->
## 当前进度（deepGit 维护）

> 深度更新 · 2026-09-30 12:00 · 追踪 1 个分支

- **`main`**（默认 · 当前）：活跃 · head `e48df23d`（2 分钟前） —— 新增 1 个提交（修复×1），涉及 (根目录)（2 文件）、engine（1 文件）、scripts（1 文件）

**最近提交**
- `4294b0f4` feat: deepgit verify 命令 —— 自查文档完整性承诺（2026-09-30）
- `e48df23d` fix: 文档非托管部分逐字节保留（2026-09-30）
- `735a653a` fix: 托管区域容忍缩进标记 + 排除构建产物（2026-09-30）
<!-- deepgit:end progress -->

<!-- deepgit:begin overview -->
## 项目概览

- **技术构成**：`其他` 60 文件、`Cangjie` 29 文件、`Shell` 3 文件、`Markdown` 2 文件
- **工程规模**：100 个跟踪文件 · 4 个提交 · 始于 2026-09-30
- **分支**：`main`

_（本节由 deepGit 依据仓库事实生成，可运行 `deepgit update --mode deep` 用 AI 深化）_
<!-- deepgit:end overview -->

<!-- deepgit:begin architecture -->
## 架构与目录

**目录结构（跟踪文件聚合）**：

```
(根目录 4 个文件)
clients/ (63)
  macos/ (60)
    deepGit/ (60)
  web/ (3)
    assets/ (2)
engine/ (31)
  src/ (29)
    ai/ (3)
    cli/ (2)
    flow/ (3)
    kernel/ (11)
    util/ (9)
scripts/ (2)
```
<!-- deepgit:end architecture -->

<!-- deepgit:begin commands -->
## 常用命令

_未检测到标准构建清单，请参考 README。_
<!-- deepgit:end commands -->
