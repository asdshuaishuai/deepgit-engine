# deepGit Engine

**基于 git 历史的本地项目群进度引擎（跨平台核心）。**

AI 开发时代，最容易丢失的不是代码，而是**进度和文档**——人和 AI 都会忘记「这个分支做到哪了」「README 是否还准」。
deepGit Engine 用 git 自己的历史回答这两个问题：

- **记录进度现状（按分支）**：每个分支做到哪、停滞多久、是否已合并，存进全局进度库。
- **浅更新文档**：把各分支进度写进 `README.md` / `AGENTS.md` / `CLAUDE.md` 的**托管区域**。
- **深度更新文档**（手动触发）：基于全量历史重写 `overview` / `architecture` / `commands` / `history` 章节。

> 文档更新只改写 deepGit 自己标记的区域，**其余内容逐字节保留**；写入前自动备份。

配套客户端（菜单栏常驻 + 管理面板）见 [deepgit-clients](https://github.com/asdshuaishuai/deepgit-clients) 仓库。

---

## 多平台路线

引擎是**唯一的业务核心**，所有 UI 交互层（各平台客户端）只消费它的两种接口：CLI `--json` 与本地 HTTP API。

| 平台 | 状态 | 说明 |
|---|---|---|
| **macOS** (arm64) | ✅ 已验证 | 当前开发平台；macOS 26/27 需极简兼容 SDK（install.sh 自动处理） |
| **Linux** (x86_64 / aarch64) | 🧭 路线内 | 仓颉官方支持 Linux 目标；引擎只用 `std.*` 与系统 `git`/`curl`，无 macOS 专有依赖 |
| **Windows** (x86_64) | 🧭 路线内 | 仓颉官方支持 Windows 目标；`cjpm.toml` 的 link-option 为 darwin 专属，移植时需按平台调整 |
| **鸿蒙 PC** | 🧭 路线内 | 仓颉是鸿蒙生态一等语言；走仓颉鸿蒙工具链编译，客户端层见 clients 仓库 |

> 引擎零第三方依赖（JSON / SHA-256 / HTTP 服务 / Markdown 渲染全部自研），外部依赖只有系统 `git` 与 `curl`——这是多平台移植成本低的关键。

## 快速开始

```sh
# 1. 安装仓颉 SDK LTS 1.0.5：https://cangjie-lang.cn/download/1.0.5
# 2. 构建并安装
sh scripts/install.sh        # macOS 自动处理 SDK 兼容问题，装到 ~/.local/bin/deepgit

# 3. 注册项目群
deepgit scan ~/dev --depth 4

# 4. 看现状 / 浅更新 / 深度更新
deepgit status
deepgit update
deepgit deep --scope readme

# 5. 启动本地服务（API-only，供客户端使用）
deepgit serve --port 5177
```

## 命令一览

```
deepgit list                      列出已注册项目及一句话现状
deepgit add <路径> [--name N]      注册项目
deepgit remove <项目> [--purge]    取消注册
deepgit scan [根目录...] [--depth N]
deepgit status [项目]              查看进度现状（只读，不写任何文件）
deepgit track [项目]               进度快照：只写进度库，不改文档（钩子用）
deepgit update [项目] [--docs S]   浅更新：记录分支进度 + 刷新文档
deepgit deep [项目] [--scope S]    深度更新：重写文档章节
deepgit journal [项目] [--branch B]
deepgit git <pull|push|commit|stash|unstash|fetch> [项目]
                                  面板级 git 操作（无破坏性命令）--message M 传提交信息
deepgit milestone <add|list|done|drop|remove> [项目] [名称]
                                  里程碑：--tag T（tag 存在即自动达成）--date --desc
deepgit dashboard                 跨项目聚合：活跃度 / 里程碑 / 语言分布 / 待合入
deepgit report [项目] [--out F]   导出自包含 Markdown 进度报告
deepgit hook <install|uninstall|status> [项目]   post-commit + post-merge 钩子
deepgit serve [--port N] [--open] 启动本地 HTTP 服务（API-only）
deepgit verify [项目]             校验文档完整性（用户内容是否被改动）
deepgit config <list|get|set> [k] [v]
deepgit doctor                    环境自检
```

全局选项：`--json`（机器可读）、`-q`（静默）、`-v`（详细日志）。

## HTTP API（客户端契约）

服务仅监听 `127.0.0.1`，本地单用户设计。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/health` | 健康检查 |
| GET | `/api/projects` | 已注册项目列表 |
| GET | `/api/status?name=&light=` | 项目状态（全量/轻量），多项目返回 `{projects, summary}` |
| GET | `/api/dashboard` | 跨项目聚合（活跃度/里程碑/语言分布） |
| GET | `/api/milestones[?name=]` | 里程碑（git 感知进度） |
| GET | `/api/docs?name=` | 项目 README/AGENTS/CLAUDE 原文（单文件 200KB 截断） |
| GET | `/api/journal?name=` | 进度日志 |
| GET | `/api/config` | 配置（apiKey 恒为空串脱敏） |
| POST | `/api/update`、`/api/deep`、`/api/track` | 更新动作（`?name=` 或 body） |
| POST | `/api/git` | git 操作 `{project, op, message}`，白名单见 CLI |
| POST | `/api/milestones`、`/api/milestones/action` | 里程碑创建 / done\|open\|drop\|remove |

`--json` CLI 与 HTTP API 输出同一套结构，键名即契约。

## 它怎么判断「进度」

| 状态 | 判定 |
|---|---|
| `active` | 3 天内有过提交 |
| `idle` | 14 天内 |
| `stale` | 超过 14 天未提交 |
| `merged` | 已是默认分支的祖先 |

每个项目还输出**工程脉搏**：提交类型构成（Conventional Commits 分类）、热点文件、
未跟踪文件 / stash / 多工作区提醒、当前分支的合入建议（fast-forward / 三方合并 / 已合入）。

## 设计取舍（重要）

1. **进度状态存全局库（`~/.deepgit/store/<项目>/`），不写进项目工作区。**
   天然跨分支安全，不污染 git status。项目内只写托管的文档区域与（可选）git 钩子。
2. **只改写自己标记的区域。** 用户手写内容逐字节保留；`overview` / `architecture` / `commands` / `history` 同理。
3. **内容未变则保留原时间戳**，避免文件抖动与提交噪音。
4. **客户端可驱动的 git 操作是白名单制**：pull（--ff-only）/ push / commit / stash / unstash / fetch，
   刻意不提供 reset/clean/force-push。
5. **非 git 目录降级但不放弃**：用文件 mtime 追踪并明确标注「非 git 模式」。
6. **零第三方依赖**：外部依赖只有系统 `git` 与 `curl`（AI 调用走 curl）。

## 配置 AI（可选）

```sh
export DEEPGIT_AI_API_KEY=sk-...        # 或 DEEPSEEK_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY
deepgit config set ai.preset deepseek   # deepseek | openai | anthropic | ollama | custom
```

不配 AI 也能用（内置规则引擎按提交前缀/关键词归类）；AI 失败自动降级，不中断更新。

## 项目结构

```
src/util/     JSON / SHA256 / 文本 / 时间 / 路径 / 进程 / 日志（叶子，仅依赖 std）
src/kernel/   配置 / 注册表 / 存储 / git 封装 / 事实采集 / 里程碑 / 进度 / 文档区域 / 渲染 / 钩子
src/ai/       provider（curl）/ 提示词 / 规则引擎
src/flow/     浅更新 / 深更新 / 状态聚合 / 仪表盘 / 报告 / 文档读取（编排层）
src/cli/      CLI 命令 + HTTP 服务
scripts/      install.sh（含极简 SDK 自动部署）/ deepgit.sh / build-minimal-sdk.sh
```

依赖方向严格单向：`util → kernel → ai → flow → cli`。

## 构建细节与已知边界

见 [AGENTS.md](AGENTS.md)（仓颉编码约定、macOS SDK 兼容、测试基线 203 项）。

- HTTP 服务无鉴权、CORS 全开、串行处理，**仅限本地单用户**，勿暴露公网。
- SHA-256 自研（通过官方测试向量），不用于密码学安全场景。
- AI 摘要质量取决于提交信息质量。
