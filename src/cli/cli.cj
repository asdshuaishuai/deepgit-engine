// CLI 命令层：解析参数并分派到各模块。
package deepgit.cli

import std.collection.*
import std.convert.*
import std.env.*
import deepgit.flow.*
import deepgit.kernel.*
import deepgit.util.*

public class CliContext {
    public let args: ArrayList<String>
    public var json: Bool = false
    public var quiet: Bool = false
    public var verbose: Bool = false
    public var cwd: String = "."

    public init(args: ArrayList<String>) {
        this.args = args
    }
}

/// 解析全局 flag，返回位置参数
func parseFlags(args: ArrayList<String>, ctx: CliContext): ArrayList<String> {
    let positionals = ArrayList<String>()
    var i: Int64 = 0
    while (i < args.size) {
        let a = args[i]
        match (a) {
            case "--json" =>
                ctx.json = true
                i += 1
            case "-q" => 
                ctx.quiet = true
                i += 1
            case "--quiet" =>
                ctx.quiet = true
                i += 1
            case "-v" =>
                ctx.verbose = true
                i += 1
            case "--verbose" =>
                ctx.verbose = true
                i += 1
            case "--help" =>
                positionals.add("--help")
                i += 1
            case "-h" =>
                positionals.add("--help")
                i += 1
            case _ =>
                positionals.add(a)
                i += 1
        }
    }
    return positionals
}

/// 取 flag 值（支持 --flag value 与 --flag=value）
func flagValue(args: ArrayList<String>, name: String): Option<String> {
    var i: Int64 = 0
    for (a in args) {
        if (a == name) {
            if (i + 1 < args.size) {
                return Some(args[i + 1])
            }
            return None
        }
        if (a.startsWith("${name}=")) {
            return Some(a[name.size + 1..])
        }
        i += 1
    }
    return None
}

func hasFlag(args: ArrayList<String>, name: String): Bool {
    for (a in args) {
        if (a == name || a.startsWith("${name}=")) {
            return true
        }
    }
    return false
}

/// 参数中用 -- 分隔后要剔除 flag 对
func positionalsOnly(args: ArrayList<String>, valueFlags: Array<String>): ArrayList<String> {
    let out = ArrayList<String>()
    var i: Int64 = 0
    while (i < args.size) {
        let a = args[i]
        if (a.startsWith("--") || (a.startsWith("-") && a.size == 2 && !isNumericLike(a))) {
            var needsValue = false
            for (vf in valueFlags) {
                if (a == vf) {
                    needsValue = true
                }
            }
            if (needsValue) {
                i += 2
            } else {
                i += 1
            }
        } else {
            out.add(a)
            i += 1
        }
    }
    return out
}

func isNumericLike(s: String): Bool {
    return s.size > 1 && s[1] >= 0x30u8 && s[1] <= 0x39u8
}

public func main2(argv: ArrayList<String>): Int64 {
    let ctx = CliContext(argv)
    var positionals = parseFlags(argv, ctx)
    Log.setQuiet(ctx.quiet)
    Log.setVerbose(ctx.verbose)
    if (ctx.json) {
        Log.setColor(false)
    }

    if (positionals.size == 0) {
        printHelp()
        return 0
    }
    let command = positionals[0]
    let rest = ArrayList<String>()
    for (i in 1..positionals.size) {
        rest.add(positionals[i])
    }

    match (command) {
        case "--help" => printHelp(); return 0
        case "help" => printHelp(); return 0
        case "version" => printOut("deepGit Engine 0.1.0 (Cangjie 1.0.5 LTS)"); return 0
        case "list" => return cmdList(rest, ctx)
        case "add" => return cmdAdd(rest, ctx)
        case "remove" => return cmdRemove(rest, ctx)
        case "scan" => return cmdScan(rest, ctx)
        case "status" => return cmdStatus(rest, ctx)
        case "track" => return cmdTrack(rest, ctx)
        case "update" => return cmdUpdate(rest, ctx)
        case "deep" => return cmdDeep(rest, ctx)
        case "journal" => return cmdJournal(rest, ctx)
        case "hook" => return cmdHook(rest, ctx)
        case "config" => return cmdConfig(rest, ctx)
        case "serve" => return cmdServe(rest, ctx)
        case "doctor" => return cmdDoctor(rest, ctx)
        case "verify" => return cmdVerify(rest, ctx)
        case "milestone" => return cmdMilestone(rest, ctx)
        case "git" => return cmdGit(rest, ctx)
        case "dashboard" => return cmdDashboard(rest, ctx)
        case "mcp" => return mcpRun()
        case "context" => return cmdContext(rest, ctx)
        case "tools" => return cmdTools(rest, ctx)
        case "skill" => return cmdSkill(rest, ctx)
        case "report" => return cmdReport(rest, ctx)
        case _ =>
            Log.error("未知命令：${command}")
            printHelp()
            return 2
    }
}


let HOOK_KINDS: Array<String> = ["post-commit", "post-merge"]

/// 所有带值的 flag（positionalsOnly 据此跳过 flag 及其值，避免值被当成位置参数）
let VALUE_FLAGS: Array<String> = [
    "--name", "--depth", "--docs", "--scope", "--branch", "--port",
    "--source", "--tag", "--date", "--desc", "--out", "--message",
]

func cmdGit(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    if (refs.size == 0) {
        throw DgError.usage("用法：deepgit git <pull|push|commit|stash|unstash|fetch> [项目] [--message M]")
    }
    let op = refs[0]
    var message = ""
    match (flagValue(rest, "--message")) {
        case Some(v) => message = v
        case None => ()
    }
    // 去掉操作词，resolveTargets 只应看到项目引用
    let restNoOp = ArrayList<String>()
    var skipped = false
    for (a in rest) {
        if (!skipped && a == op) {
            skipped = true
            continue
        }
        restNoOp.add(a)
    }
    let targets = resolveTargets(restNoOp, false)
    var failed = false
    for (p in targets) {
        try {
            let r = runGitOp(p.path, op, message)
            if (ctx.json) {
                let o = r.toJson()
                Json.set(o, "project", Json.of(p.name))
                printOut(Json.pretty(o))
            } else if (r.ok) {
                if (!ctx.quiet) {
                    Log.ok("${p.name}：${op} 完成")
                    if (!r.output.isEmpty()) {
                        printOut(r.output)
                    }
                }
            } else {
                failed = true
                Log.error("${p.name}：${op} 失败")
                if (!r.output.isEmpty()) {
                    printOut(r.output)
                }
            }
        } catch (e: Exception) {
            failed = true
            Log.error("${p.name}: ${e.message}")
        }
    }
    return if (failed) { 1 } else { 0 }
}

func cmdMilestone(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    if (refs.size == 0) {
        throw DgError.usage("用法：deepgit milestone <add|list|done|drop|remove> [项目] [名称] [--tag T] [--date YYYY-MM-DD] [--desc S]")
    }
    let action = refs[0]
    match (action) {
        case "add" =>
            if (refs.size < 3) {
                throw DgError.usage("用法：deepgit milestone add <项目> <名称> [--tag T] [--date YYYY-MM-DD] [--desc S]")
            }
            let p = requireProject(refs[1])
            let name = refs[2]
            let tag = match (flagValue(rest, "--tag")) {
                case Some(v) => v
                case None => ""
            }
            let date = match (flagValue(rest, "--date")) {
                case Some(v) => v
                case None => ""
            }
            let desc = match (flagValue(rest, "--desc")) {
                case Some(v) => v
                case None => ""
            }
            let (m, created) = addMilestone(p.id, name, desc, date, tag)
            if (ctx.json) {
                let o = Json.obj()
                Json.set(o, "project", Json.of(p.name))
                Json.set(o, "milestone", m.toJson())
                Json.set(o, "created", Json.of(created))
                printOut(Json.pretty(o))
            } else {
                if (created) {
                    Log.ok("${p.name}：里程碑「${name}」已创建")
                } else {
                    Log.warn("${p.name}：里程碑「${name}」已存在")
                }
            }
            return 0
        case "list" =>
            let target: Option<ProjectEntry> = if (refs.size >= 2) { Some(requireProject(refs[1])) } else { Option<ProjectEntry>.None }
            let projects = ArrayList<ProjectEntry>()
            match (target) {
                case Some(p) => projects.add(p)
                case None =>
                    for (p in loadRegistry().projects) {
                        projects.add(p)
                    }
            }
            let items = ArrayList<JsonValue>()
            for (p in projects) {
                for (m in milestonesFor(p.id)) {
                    let prog = milestoneProgress(m, p.path, "")
                    items.add(milestoneJson(p, prog))
                }
            }
            if (ctx.json) {
                let arr = JArr(items)
                let o = Json.obj()
                Json.set(o, "milestones", arr)
                printOut(Json.pretty(o))
                return 0
            }
            if (items.size == 0) {
                printOut("（无里程碑）")
                return 0
            }
            for (it in items) {
                printOut(milestoneLine(it))
            }
            return 0
        case "done" | "drop" | "reopen" =>
            if (refs.size < 3) {
                throw DgError.usage("用法：deepgit milestone ${action} <项目> <名称>")
            }
            let p = requireProject(refs[1])
            let status = match (action) {
                case "done" => "done"
                case "drop" => "dropped"
                case _ => "open"
            }
            if (!setMilestoneStatus(p.id, refs[2], status)) {
                Log.error("${p.name}：未找到里程碑「${refs[2]}」")
                return 1
            }
            if (!ctx.quiet) {
                Log.ok("${p.name}：里程碑「${refs[2]}」→ ${status}")
            }
            return 0
        case "remove" =>
            if (refs.size < 3) {
                throw DgError.usage("用法：deepgit milestone remove <项目> <名称>")
            }
            let p = requireProject(refs[1])
            if (!removeMilestone(p.id, refs[2])) {
                Log.error("${p.name}：未找到里程碑「${refs[2]}」")
                return 1
            }
            if (!ctx.quiet) {
                Log.ok("${p.name}：里程碑「${refs[2]}」已删除")
            }
            return 0
        case _ =>
            throw DgError.usage("未知 milestone 子命令：${action}")
    }
}

func milestoneJson(p: ProjectEntry, prog: MilestoneProgress): JsonValue {
    let o = prog.milestone.toJson()
    Json.set(o, "projectName", Json.of(p.name))
    Json.set(o, "status", Json.of(prog.effectiveStatus))
    Json.set(o, "tagName", Json.of(prog.tagName))
    Json.set(o, "tagReached", Json.of(prog.tagReached))
    Json.set(o, "commitsSince", Json.of(prog.commitsSince))
    Json.set(o, "daysToTarget", Json.of(prog.daysToTarget))
    Json.set(o, "overdue", Json.of(prog.overdue))
    return o
}

func milestoneLine(it: JsonValue): String {
    let name = Json.strAt(it, "name", "")
    let proj = Json.strAt(it, "projectName", "")
    let status = Json.strAt(it, "status", "")
    let date = Json.strAt(it, "targetDate", "")
    let days = Json.intAt(it, "daysToTarget", -1)
    let commits = Json.intAt(it, "commitsSince", 0)
    let tagReached = Json.boolAt(it, "tagReached", false)
    let overdue = Json.boolAt(it, "overdue", false)
    let statusLabel = match (status) {
        case "done" => "✓ 已达成"
        case "dropped" => "✗ 已放弃"
        case _ => if (overdue) { "⚠ 已逾期" } else { "进行中" }
    }
    var when = ""
    if (!date.isEmpty()) {
        when = if (days >= 0) { "目标 ${date}（还剩 ${days} 天）" } else { "目标 ${date}（逾期 ${-days} 天）" }
    }
    let tagPart = if (tagReached) { "tag ✓" } else { "" }
    let parts = ArrayList<String>()
    parts.add("${proj}｜${name}")
    parts.add(statusLabel)
    if (!when.isEmpty()) {
        parts.add(when)
    }
    if (commits > 0) {
        parts.add("创建以来 ${commits} 提交")
    }
    if (tagReached) {
        parts.add(tagPart)
    }
    let sb = StringBuilder()
    var i: Int64 = 0
    for (pt in parts) {
        if (i > 0) {
            sb.append(" · ")
        }
        sb.append(pt)
        i += 1
    }
    return sb.toString()
}

func cmdReport(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    let config = loadConfig()
    let reg = loadRegistry()

    var targets = ArrayList<ProjectEntry>()
    if (refs.size > 0 && refs[0] != "--out") {
        targets.add(requireProject(refs[0]))
    } else {
        for (p in reg.projects) {
            if (!p.disabled) {
                targets.add(p)
            }
        }
    }
    if (targets.size == 0) {
        Log.error("没有已注册项目，先运行 deepgit scan")
        return 1
    }

    let statuses = allProjectStatuses(targets, config, false)
    let dash = buildDashboard(targets, config)
    let md = renderReportMarkdown(statuses, dash, config.language)

    var outPath = ""
    match (flagValue(rest, "--out")) {
        case Some(v) => outPath = expandHome(v)
        case None => outPath = deepgitPath(["reports", "report-${nowIso()[..10]}-${nowMillis() % 100000}.md"])
    }
    ensureDir(dirname(outPath))
    writeFileAtomic(outPath, md)

    if (ctx.json) {
        let o = Json.obj()
        Json.set(o, "file", Json.of(outPath))
        Json.set(o, "projects", Json.of(targets.size))
        Json.set(o, "bytes", Json.of(md.size))
        printOut(Json.pretty(o))
    } else {
        Log.ok("报告已生成：${outPath}（${targets.size} 个项目）")
    }
    return 0
}


func cmdContext(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    var budget: Int64 = AGENT_DEFAULT_BUDGET
    match (flagValue(rest, "--budget")) {
        case Some(v) =>
            try {
                budget = Int64.parse(v)
            } catch (e: Exception) {
                throw DgError.usage("--budget 需要整数：${v}")
            }
        case None => ()
    }
    let config = loadConfig()
    let reg = loadRegistry()
    let scope = if (refs.size > 0) { "project" } else { "group" }
    let target = if (refs.size > 0) { refs[0] } else { "" }
    let text = buildAgentContext(reg.projects, config, scope, target, budget)
    if (ctx.json) {
        let o = Json.obj()
        Json.set(o, "scope", Json.of(scope))
        Json.set(o, "budget", Json.of(budget))
        Json.set(o, "context", Json.of(text))
        printOut(Json.pretty(o))
    } else {
        printOut(text)
    }
    return 0
}

func cmdTools(rest: ArrayList<String>, ctx: CliContext): Int64 {
    printOut(Json.pretty(agentToolsManifest()))
    return 0
}

let SKILL_FRONTMATTER = "---\nname: deepgit\ndescription: 用 deepGit 引擎管理本地 git 项目群的进度：查现状、记进度、浅/深更新文档、git 操作、里程碑。适用于任何关于本地项目状态、分支进度、项目文档维护的问题。\n---\n\n"

func skillMarkdown(): String {
    let engine = currentExecutable()
    let sb = StringBuilder()
    sb.append(SKILL_FRONTMATTER)
    sb.append("# deepGit — 本地项目群进度引擎（agent 使用指南）\n\n")
    sb.append("deepGit 是 **AI 无关** 的确定性内核：它提供事实与动作，你（agent）负责理解与表达。\n\n")
    sb.append("## 三种接入方式（按场景选）\n\n")
    sb.append("1. **MCP 服务器**（推荐，工具化接入）。宿主配置：\n")
    sb.append("   ```json\n")
    sb.append("   {\"mcpServers\": {\"deepgit\": {\"command\": \"" + engine + "\", \"args\": [\"mcp\"]}}}\n")
    sb.append("   ```\n")
    sb.append("   工具：list_projects / get_project_context / get_project_status / get_dashboard / get_project_docs / get_journal / run_shallow_update / run_deep_update / run_track / git_op / list_milestones / milestone_add / milestone_action / add_project\n\n")
    sb.append("2. **CLI**（一次性问答/脚本）：`" + engine + " status --json`、`context [项目] --budget N`、`tools`、`journal <项目>`、`dashboard --json`\n\n")
    sb.append("3. **HTTP API**（`deepgit serve` 后）：`GET /api/context`、`GET /api/tools`、`POST /api/update?name=`\n\n")
    sb.append("## 典型任务配方\n\n")
    sb.append("- **项目现状**：get_project_context(name) → 直接总结；要历史再 get_journal\n")
    sb.append("- **项目群周报**：get_group_context → get_dashboard → 按「活跃/风险/建议」输出\n")
    sb.append("- **收尾打扫**：git_op(op=commit, message=…) 提交未提交改动 → run_shallow_update 记进度\n")
    sb.append("- **项目说明文档**：get_project_context + get_project_docs → 生成 markdown 说明\n\n")
    sb.append("## 红线\n\n")
    sb.append("- git_op 只允许白名单操作（pull/push/commit/stash/unstash/fetch），没有 reset/clean/force-push\n")
    sb.append("- 文档更新只发生 deepGit 托管区域内（引擎保证），用户内容逐字节保留\n")
    sb.append("- 引擎是 AI 无关的：所有判断与表达由你完成，引擎只提供事实\n")
    return sb.toString()
}

func cmdSkill(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    let action = if (refs.size > 0) { refs[0] } else { "print" }
    let md = skillMarkdown()
    match (action) {
        case "print" =>
            printOut(md)
            return 0
        case "install" =>
            var dir = ""
            match (flagValue(rest, "--dir")) {
                case Some(v) => dir = expandHome(v)
                case None => dir = expandHome("~/.zcode/skills/deepgit")
            }
            ensureDir(dir)
            let file = dir + "/SKILL.md"
            writeFileAtomic(file, md)
            if (ctx.json) {
                let o = Json.obj()
                Json.set(o, "file", Json.of(file))
                Json.set(o, "bytes", Json.of(md.size))
                printOut(Json.pretty(o))
            } else {
                Log.ok("Skill 已安装：${file}")
            }
            return 0
        case _ =>
            throw DgError.usage("用法：deepgit skill <print|install> [--dir D]")
    }
}

func cmdDashboard(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let config = loadConfig()
    let reg = loadRegistry()
    let dash = buildDashboard(reg.projects, config)
    if (ctx.json) {
        printOut(Json.pretty(dash))
        return 0
    }
    let projs = Json.getOr(dash, "projects")
    printOut("项目群：共 ${Json.intAt(projs, "total", 0)} 个 · 近 7 天活跃 ${Json.intAt(projs, "active7d", 0)} · 近 30 天活跃 ${Json.intAt(projs, "active30d", 0)} · 有未提交改动 ${Json.intAt(projs, "dirty", 0)}")
    let work = Json.getOr(dash, "work")
    printOut("工作面：分支 ${Json.intAt(work, "branches", 0)} · 待合入分支 ${Json.intAt(work, "mergeCandidates", 0)} · 未跟踪文件 ${Json.intAt(work, "untrackedFiles", 0)} · stash ${Json.intAt(work, "stashes", 0)}")
    let ms = Json.getOr(dash, "milestones")
    let counts = Json.getOr(ms, "counts")
    printOut("里程碑：进行中 ${Json.intAt(counts, "open", 0)} · 已达成 ${Json.intAt(counts, "done", 0)} · 已放弃 ${Json.intAt(counts, "dropped", 0)}")
    let items = Json.arrAt(ms, "items")
    if (items.size > 0) {
        printOut("")
        var shown: Int64 = 0
        for (it in items) {
            if (shown >= 8) {
                printOut("  … 共 ${items.size} 条，完整列表：deepgit milestone list")
                break
            }
            printOut("  ${milestoneLine(it)}")
            shown += 1
        }
    }
    let langs = Json.arrAt(dash, "languages")
    if (langs.size > 0) {
        printOut("")
        let parts = ArrayList<String>()
        var n: Int64 = 0
        for (l in langs) {
            if (n >= 6) {
                break
            }
            parts.add("${Json.strAt(l, "language", "")} ${Json.intAt(l, "count", 0)}")
            n += 1
        }
        printOut("语言分布：${joinStrings(parts, " · ")}")
    }
    return 0
}

func printHelp(): Unit {
    printOut("deepGit Engine — git-based local project progress engine")
    printOut("")
    printOut("用法：deepgit <命令> [参数] [--json] [-q] [-v]")
    printOut("")
    printOut("命令：")
    printOut("  list                     列出已注册项目及一句话现状")
    printOut("  add <路径> [--name N]    注册项目")
    printOut("  remove <项目> [--purge]  取消注册（--purge 一并删除进度数据）")
    printOut("  scan [根目录...] [--depth N]  扫描发现项目并注册")
    printOut("  status [项目]            查看项目进度现状（不写任何文件）")
    printOut("  track [项目]             进度快照：只记录，不改文档（钩子用）")
    printOut("  update [项目] [--docs S]  浅更新：记录各分支进度 + 刷新文档进度区域")
    printOut("  deep [项目] [--scope S]   深度更新：重写 overview/architecture/commands/history")
    printOut("  journal [项目] [--branch B]  查看进度日志")
    printOut("  hook <install|uninstall|status> [项目]  管理 post-commit 钩子")
    printOut("  milestone <add|list|done|drop|remove> …  里程碑管理")
    printOut("  dashboard                跨项目聚合仪表盘（活跃度/里程碑/语言分布）")
    printOut("  context [项目] [--budget N]  输出 agent 上下文包（markdown，budget=字符预算）")
    printOut("  tools                    输出 agent 工具清单（JSON）")
    printOut("  mcp                      以 MCP 服务器运行（stdio JSON-RPC；供 Claude 等 agent 宿主接入）")
    printOut("  skill <print|install>    输出/安装 agent Skill 教学包（--dir 指定目录）")
    printOut("  report [项目] [--out F]  导出 Markdown 进度报告")
    printOut("  config <list|get|set> [k] [v]  配置（AI 预设等）")
    printOut("  serve [--port N] [--open]  启动本地 HTTP 服务（客户端 / API 用）")
    printOut("  verify [项目]            校验文档完整性（用户内容是否被改动）")
    printOut("  doctor                   环境自检")
    printOut("")
    printOut("选项：")
    printOut("  --json                   机器可读输出")
    printOut("  -q, --quiet              静默")
    printOut("  -v, --verbose            详细日志")
    printOut("")
    printOut("示例：")
    printOut("  deepgit scan ~/dev --depth 3        # 扫描并注册项目群")
    printOut("  deepgit status                      # 看全部项目现状")
    printOut("  deepgit update deepGit              # 浅更新指定项目")
    printOut("  deepgit deep --scope readme         # 手动触发 README 深度更新")
    printOut("  deepgit hook install                # 装 post-commit 钩子")
    printOut("  deepgit milestone add myapp v1.0 --tag v1.0.0 --date 2026-12-01")
    printOut("  deepgit dashboard                   # 项目群全景")
    printOut("  deepgit report --out ~/Desktop/progress.md  # 导出报告")
}

/// 解析目标项目：给了就用，没给则用 cwd 推断
func resolveTargets(rest: ArrayList<String>, allowAll: Bool): ArrayList<ProjectEntry> {
    let out = ArrayList<ProjectEntry>()
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    if (refs.size > 0) {
        for (r in refs) {
            out.add(requireProject(r))
        }
        return out
    }
    if (allowAll) {
        let reg = loadRegistry()
        for (p in reg.projects) {
            if (!p.disabled) {
                out.add(p)
            }
        }
        return out
    }
    // cwd 推断
    let cwd = normalizePath(expandHome(getCwd()))
    match (findProject(cwd)) {
        case Some(p) => out.add(p)
        case None => throw DgError.notFound("当前目录不属于任何已注册项目（可用 `deepgit add .` 注册）")
    }
    return out
}

func cmdList(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let reg = loadRegistry()
    let config = loadConfig()
    if (ctx.json) {
        let arr = ArrayList<JsonValue>()
        for (p in reg.projects) {
            let o = Json.obj()
            Json.set(o, "id", Json.of(p.id))
            Json.set(o, "name", Json.of(p.name))
            Json.set(o, "path", Json.of(p.path))
            Json.set(o, "kind", Json.of(p.kind))
            Json.set(o, "remote", Json.of(p.remote))
            Json.set(o, "disabled", Json.of(p.disabled))
            arr.add(o)
        }
        printOut(Json.pretty(JArr(arr)))
        return 0
    }
    if (reg.projects.size == 0) {
        Log.info("尚未注册任何项目。运行 `deepgit scan <根目录>` 或 `deepgit add <路径>`。")
        return 0
    }
    let rows = ArrayList<Array<String>>()
    for (p in reg.projects) {
        var headline = ""
        try {
            let facts = collectFacts(p.path, p.kind, config, 3, false)
            let progress = readProgress(p.id)
            headline = computeHeadline(facts, progress, config.language)
        } catch (e: Exception) {
            headline = "（读取失败：${e.message}）"
        }
        rows.add([p.name, p.kind, prettyPath(p.path, 42, ), headline])
    }
    printOut(renderTable(["项目", "类型", "路径", "现状"], rows.toArray()))
    Log.info("")
    Log.info("共 ${reg.projects.size} 个项目。用 `deepgit status <项目>` 看详情。")
    return 0
}

func cmdAdd(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    if (refs.size == 0) {
        throw DgError.usage("用法：deepgit add <路径> [--name 名称]")
    }
    var name = ""
    match (flagValue(rest, "--name")) {
        case Some(n) => name = n
        case None => ()
    }
    let cwd = normalizePath(expandHome(getCwd()))
    let (entry, added) = addProject(refs[0], name, ArrayList<String>(), cwd)
    if (ctx.json) {
        printOut(Json.pretty(entry.toJson()))
    } else if (added) {
        Log.ok("已注册：${entry.name}（${entry.kind}）→ ${entry.path}")
        if (!entry.remote.isEmpty()) {
            Log.info("  远端：${entry.remote}")
        }
    } else {
        Log.info("项目已存在：${entry.name}（${entry.path}）")
    }
    return 0
}

func cmdRemove(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    if (refs.size == 0) {
        throw DgError.usage("用法：deepgit remove <项目> [--purge]")
    }
    let purge = hasFlag(rest, "--purge")
    let removed = removeProject(refs[0], purge)
    if (ctx.json) {
        printOut(Json.pretty(removed.toJson()))
    } else {
        Log.ok("已取消注册：${removed.name}${if (purge) { "（进度数据已删除）" } else { "" }}")
    }
    return 0
}

func cmdScan(rest: ArrayList<String>, ctx: CliContext): Int64 {
    var depth: Int64 = 4
    match (flagValue(rest, "--depth")) {
        case Some(v) =>
            try {
                depth = Int64.parse(v)
            } catch (e: Exception) {
                throw DgError.usage("--depth 需要整数")
            }
        case None => ()
    }
    let includeNonGit = !hasFlag(rest, "--git-only")
    let roots = positionalsOnly(rest, VALUE_FLAGS)
    if (roots.size == 0) {
        let config = loadConfig()
        if (config.roots.size == 0) {
            throw DgError.usage("用法：deepgit scan <根目录...> [--depth N]\n（可在配置里设 roots 作为默认扫描根：deepgit config set roots a,b）")
        }
        for (r in config.roots) {
            roots.add(r)
        }
    }
    let cwd = normalizePath(expandHome(getCwd()))
    let resolvedRoots = ArrayList<String>()
    for (r in roots) {
        let p = resolvePath(r, cwd)
        if (!isDirectoryPath(p)) {
            Log.warn("跳过不存在的目录：${p}")
            continue
        }
        resolvedRoots.add(p)
    }
    if (resolvedRoots.size == 0) {
        throw DgError.usage("没有可扫描的有效目录")
    }

    Log.step("扫描 ${resolvedRoots.size} 个根目录（深度 ${depth}）…")
    let result = scanRoots(resolvedRoots, depth, includeNonGit)
    let (added, existing) = registerCandidates(result.candidates)

    if (ctx.json) {
        let o = Json.obj()
        let arr = ArrayList<JsonValue>()
        for (c in result.candidates) {
            let e = Json.obj()
            Json.set(e, "name", Json.of(c.name))
            Json.set(e, "path", Json.of(c.path))
            Json.set(e, "kind", Json.of(c.kind))
            Json.set(e, "remote", Json.of(c.remote))
            arr.add(e)
        }
        Json.set(o, "candidates", JArr(arr))
        Json.set(o, "added", Json.of(added))
        Json.set(o, "existing", Json.of(existing))
        Json.set(o, "dirsVisited", Json.of(result.dirsVisited))
        Json.set(o, "truncated", Json.of(result.truncated))
        printOut(Json.pretty(o))
        return 0
    }

    if (result.candidates.size == 0) {
        Log.info("未发现项目（已访问 ${result.dirsVisited} 个目录）")
        return 0
    }
    let rows = ArrayList<Array<String>>()
    for (c in result.candidates) {
        rows.add([c.name, c.kind, prettyPath(c.path, 46), if (c.remote.isEmpty()) { "-" } else { c.remote }])
    }
    printOut(renderTable(["项目", "类型", "路径", "远端"], rows.toArray()))
    Log.info("")
    Log.ok("发现 ${result.candidates.size} 个项目：新增 ${added}，已存在 ${existing}")
    if (result.truncated) {
        Log.warn("扫描被截断（目录过多），可增加 --depth 精确度或分根扫描")
    }
    return 0
}

func cmdStatus(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    let config = loadConfig()
    if (targets.size == 0) {
        Log.info("尚未注册任何项目。")
        return 0
    }
    if (ctx.json) {
        let statuses = allProjectStatuses(targets, config, false)
        if (statuses.size == 1) {
            printOut(Json.pretty(statuses[0]))
        } else {
            let o = Json.obj()
            Json.set(o, "projects", JArr(statuses))
            Json.set(o, "summary", groupSummary(statuses, config))
            printOut(Json.pretty(o))
        }
        return 0
    }
    if (targets.size == 1) {
        return printSingleStatus(targets[0], config)
    }
    // 多项目概览
    let light = positionalsOnly(rest, VALUE_FLAGS).size == 0
    let statuses = allProjectStatuses(targets, config, light)
    let rows = ArrayList<Array<String>>()
    for (s in statuses) {
        rows.add([
            Json.strAt(s, "name", "?"),
            Json.strAt(s, "kind", ""),
            Json.strAt(s, "currentBranch", "-"),
            Json.strAt(s, "headline", ""),
        ])
    }
    printOut(renderTable(["项目", "类型", "当前分支", "现状"], rows.toArray()))
    let summary = groupSummary(statuses, config)
    Log.info("")
    Log.info("共 ${Json.intAt(summary, "projectCount", 0)} 个项目 · ${Json.intAt(summary, "branchCount", 0)} 个分支 · 活跃 ${Json.intAt(summary, "activeProjects", 0)} · 停滞 ${Json.intAt(summary, "staleProjects", 0)}")
    return 0
}

func printSingleStatus(project: ProjectEntry, config: Config): Int64 {
    let status = projectStatus(project, config, 8)
    let zh = config.language != "en"
    printOut("${Json.strAt(status, "name", "")}  ${if (Json.strAt(status, "kind", "") == "git") { "（git）" } else { "（非 git）" }}")
    printOut("路径：${Json.strAt(status, "path", "")}")
    if (Json.strAt(status, "remote", "").size > 0) {
        printOut("远端：${Json.strAt(status, "remote", "")}")
    }
    printOut("现状：${Json.strAt(status, "headline", "")}")
    printOut("")
    let branches = Json.arrAt(status, "branches")
    if (branches.size > 0) {
        printOut(if (zh) { "分支进度" } else { "Branches" })
        let rows = ArrayList<Array<String>>()
        for (b in branches) {
            let flags = ArrayList<String>()
            if (Json.boolAt(b, "isCurrent", false)) {
                flags.add(if (zh) { "当前" } else { "cur" })
            }
            if (Json.boolAt(b, "isDefault", false)) {
                flags.add(if (zh) { "默认" } else { "def" })
            }
            let extra = ArrayList<String>()
            let ahead = Json.intAt(b, "aheadOfDefault", 0)
            if (ahead > 0 && !Json.boolAt(b, "isDefault", false)) {
                extra.add("+${ahead}")
            }
            let pending = Json.intAt(b, "pendingCommits", 0)
            if (pending > 0) {
                extra.add(if (zh) { "${pending} 待记录" } else { "${pending} pending" })
            }
            rows.add([
                Json.strAt(b, "name", ""),
                Json.strAt(b, "statusLabel", ""),
                Json.strAt(b, "headShort", "-"),
                Json.strAt(b, "headAgo", "-"),
                "${joinStrings(flags, "/")}${if (extra.size > 0) { " " + joinStrings(extra, " ") } else { "" }}",
                truncate(oneLine(Json.strAt(b, "summary", "")), 44, "…"),
            ])
        }
        printOut(renderTable(["分支", "状态", "HEAD", "最近提交", "标记", "摘要"], rows.toArray()))
    } else {
        printOut(if (zh) { "（暂无进度记录，运行 `deepgit update` 生成）" } else { "(no progress yet)" })
    }

    let progressMeta = Json.getOr(status, "progress")
    printOut("")
    let lastUpdate = Json.strAt(progressMeta, "lastUpdateAt", "")
    let lastDeep = Json.strAt(progressMeta, "lastDeepAt", "")
    printOut("进度更新：${if (lastUpdate.size > 0) { formatDateTime(lastUpdate) } else { "从未" }} · 深度更新：${if (lastDeep.size > 0) { formatDateTime(lastDeep) } else { "从未" }}")
    if (Json.intAt(status, "userDirtyCount", 0) > 0) {
        printOut("工作区：${Json.intAt(status, "userDirtyCount", 0)} 处未提交改动（不含 deepGit 托管文档）")
    }

    let journal = Json.arrAt(status, "journal")
    if (journal.size > 0) {
        printOut("")
        printOut(if (zh) { "最近进度" } else { "Recent" })
        var i: Int64 = 0
        for (e in journal) {
            if (i >= 5) {
                break
            }
            printOut("- ${formatDateTime(Json.strAt(e, "at", ""))} · ${modeLabel(Json.strAt(e, "mode", ""), config.language)} · `${Json.strAt(e, "branch", "-")}` · ${truncate(oneLine(Json.strAt(e, "summary", "")), 70, "…")}")
            i += 1
        }
    }
    match (Json.get(status, "overall")) {
        case Some(overall) =>
            let notes = Json.strArrAt(overall, "notes")
            if (notes.size > 0) {
                printOut("")
                printOut(if (zh) { "需要注意" } else { "Attention" })
                for (n in notes) {
                    printOut("- ${n}")
                }
            }
        case None => ()
    }
    return 0
}

func cmdTrack(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, false)
    let config = loadConfig()
    var source = "cli"
    match (flagValue(rest, "--source")) {
        case Some(s) => source = s
        case None => ()
    }
    var failed = false
    for (p in targets) {
        try {
            let result = runTrack(p, config, source)
            if (ctx.json) {
                printOut(Json.pretty(updateResultToJson(result)))
            } else {
                Log.ok("已记录 ${p.name}：${result.branchCount} 个分支，${result.commitCount} 个提交")
            }
        } catch (e: Exception) {
            failed = true
            if (ctx.json) {
                printOut(Json.pretty(chainError("track 失败", e).toJson()))
            } else {
                Log.error("${p.name}: ${e.message}")
            }
        }
    }
    return if (failed) { 1 } else { 0 }
}

func cmdUpdate(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    let config = loadConfig()
    var docs = ""
    match (flagValue(rest, "--docs")) {
        case Some(d) => docs = d
        case None => ()
    }
    let dryRun = hasFlag(rest, "--dry-run")
    var notes = ArrayList<String>()
    match (flagValue(rest, "--note")) {
        case Some(n) => notes.add(n)
        case None => ()
    }
    var failed = false
    let results = ArrayList<JsonValue>()
    for (p in targets) {
        try {
            let opts = UpdateOptions()
            opts.mode = "shallow"
            opts.docs = docs
            opts.dryRun = dryRun
            opts.source = "cli"
            opts.notes = notes
            let result = runUpdate(p, config, opts)
            if (ctx.json) {
                results.add(updateResultToJson(result))
            } else {
                Log.info("")
                Log.ok("${result.projectName}：${result.branchCount} 个分支，${result.commitCount} 个提交（摘要来源：${providerLabel(result.provider)}）")
                for ((file, changed, created, _) in result.docChanges) {
                    if (changed) {
                        Log.info("  · ${file}${if (created) { "（新建）" } else { "" }}")
                    }
                }
            }
        } catch (e: Exception) {
            failed = true
            if (ctx.json) {
                results.add(chainError("${p.name} 更新失败", e).toJson())
            } else {
                Log.error("${p.name}: ${e.message}")
            }
        }
    }
    if (ctx.json) {
        if (results.size == 1) {
            printOut(Json.pretty(results[0]))
        } else {
            printOut(Json.pretty(JArr(results)))
        }
    }
    return if (failed) { 1 } else { 0 }
}

func cmdDeep(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    let config = loadConfig()
    var scope = "all"
    match (flagValue(rest, "--scope")) {
        case Some(s) => scope = s
        case None => ()
    }
    if (scope != "all" && scope != "readme" && scope != "agent") {
        throw DgError.usage("--scope 只能是 all | readme | agent")
    }
    let dryRun = hasFlag(rest, "--dry-run")
    var failed = false
    let results = ArrayList<JsonValue>()
    for (p in targets) {
        try {
            let opts = DeepOptions()
            opts.scope = scope
            opts.dryRun = dryRun
            opts.source = "cli"
            let result = runDeep(p, config, opts)
            if (ctx.json) {
                results.add(deepResultToJson(result))
            } else {
                Log.info("")
                Log.ok("${result.projectName} 深度更新完成（摘要来源：${providerLabel(result.provider)}）")
                for ((file, changed, created, _) in result.docChanges) {
                    Log.info("  · ${file}${if (created) { "（新建）" } else if (changed) { "" } else { "（无变化）" }}")
                }
                if (result.highlights.size > 0) {
                    Log.info("")
                    Log.info("关键结论：")
                    for (h in result.highlights) {
                        Log.info("  - ${h}")
                    }
                }
            }
        } catch (e: Exception) {
            failed = true
            if (ctx.json) {
                results.add(chainError("${p.name} 深度更新失败", e).toJson())
            } else {
                Log.error("${p.name}: ${e.message}")
            }
        }
    }
    if (ctx.json) {
        if (results.size == 1) {
            printOut(Json.pretty(results[0]))
        } else {
            printOut(Json.pretty(JArr(results)))
        }
    }
    return if (failed) { 1 } else { 0 }
}

func updateResultToJson(r: UpdateResult): JsonValue {
    let o = Json.obj()
    Json.set(o, "ok", Json.of(r.ok))
    Json.set(o, "mode", Json.of(r.mode))
    Json.set(o, "projectId", Json.of(r.projectId))
    Json.set(o, "project", Json.of(r.projectName))
    Json.set(o, "provider", Json.of(r.provider))
    Json.set(o, "providerLabel", Json.of(providerLabel(r.provider)))
    Json.set(o, "branchCount", Json.of(r.branchCount))
    Json.set(o, "commitCount", Json.of(r.commitCount))
    let docs = ArrayList<JsonValue>()
    for ((file, changed, created, preview) in r.docChanges) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(file))
        Json.set(d, "changed", Json.of(changed))
        Json.set(d, "created", Json.of(created))
        if (preview.size > 0) {
            Json.set(d, "preview", Json.of(preview))
        }
        docs.add(d)
    }
    Json.set(o, "docs", JArr(docs))
    Json.set(o, "journalEntry", r.journalEntry)
    Json.set(o, "at", Json.of(r.at))
    return o
}

func deepResultToJson(r: DeepResult): JsonValue {
    let o = Json.obj()
    Json.set(o, "ok", Json.of(r.ok))
    Json.set(o, "mode", Json.of("deep"))
    Json.set(o, "projectId", Json.of(r.projectId))
    Json.set(o, "project", Json.of(r.projectName))
    Json.set(o, "provider", Json.of(r.provider))
    Json.set(o, "providerLabel", Json.of(providerLabel(r.provider)))
    let hl = ArrayList<JsonValue>()
    for (h in r.highlights) {
        hl.add(Json.of(h))
    }
    Json.set(o, "highlights", JArr(hl))
    let docs = ArrayList<JsonValue>()
    for ((file, changed, created, preview) in r.docChanges) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(file))
        Json.set(d, "changed", Json.of(changed))
        Json.set(d, "created", Json.of(created))
        if (preview.size > 0) {
            Json.set(d, "preview", Json.of(preview))
        }
        docs.add(d)
    }
    Json.set(o, "docs", JArr(docs))
    Json.set(o, "journalEntry", r.journalEntry)
    Json.set(o, "at", Json.of(r.at))
    return o
}

func cmdJournal(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    var branch = ""
    match (flagValue(rest, "--branch")) {
        case Some(b) => branch = b
        case None => ()
    }
    var limit: Int64 = 20
    match (flagValue(rest, "--limit")) {
        case Some(v) =>
            try {
                limit = Int64.parse(v)
            } catch (e: Exception) {
                ()
            }
        case None => ()
    }
    for (p in targets) {
        let entries = readJournal(p.id, limit * 4)
        let filtered = ArrayList<JsonValue>()
        for (e in entries) {
            if (branch.size == 0 || Json.strAt(e, "branch", "") == branch) {
                filtered.add(e)
            }
        }
        if (ctx.json) {
            printOut(Json.pretty(JArr(filtered)))
            continue
        }
        printOut("# ${p.name} 进度日志${if (branch.size > 0) { "（分支 ${branch}）" } else { "" }}")
        printOut("")
        if (filtered.size == 0) {
            printOut("（暂无记录）")
            continue
        }
        var i: Int64 = 0
        for (e in filtered) {
            if (i >= limit) {
                break
            }
            let mode = modeLabel(Json.strAt(e, "mode", ""), "zh")
            printOut("## ${formatDateTime(Json.strAt(e, "at", ""))} · `${Json.strAt(e, "branch", "-")}` · ${mode}")
            let commits = Json.intAt(e, "commitCount", 0)
            if (commits > 0) {
                printOut("- 涉及 ${commits} 个提交 · 摘要来源：${providerLabel(Json.strAt(e, "provider", ""))}")
            }
            let summary = Json.strAt(e, "summary", "")
            if (summary.size > 0) {
                printOut("")
                printOut("**摘要**：${oneLine(summary)}")
            }
            let hl = Json.strArrAt(e, "highlights")
            if (hl.size > 0) {
                printOut("")
                for (h in hl) {
                    printOut("- ${oneLine(h)}")
                }
            }
            printOut("")
            i += 1
        }
    }
    return 0
}

func cmdHook(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let sub = positionalsOnly(rest, VALUE_FLAGS)
    if (sub.size == 0) {
        throw DgError.usage("用法：deepgit hook <install|uninstall|status> [项目]")
    }
    let action = sub[0]
    // 去掉动作词本身，resolveTargets 只应看到项目引用
    let restNoAction = ArrayList<String>()
    var skipped = false
    for (a in rest) {
        if (!skipped && a == action) {
            skipped = true
            continue
        }
        restNoAction.add(a)
    }
    let targets = resolveTargets(restNoAction, false)
    var failed = false
    for (p in targets) {
        if (p.kind != "git") {
            Log.warn("${p.name} 不是 git 仓库，跳过")
            continue
        }
        try {
            match (action) {
                case "install" =>
                    let engine = currentExecutable()
                    if (ctx.json) {
                        let arr = ArrayList<JsonValue>()
                        for (hn in HOOK_KINDS) {
                            let res = installHookFor(p.path, engine, hn)
                            let o = Json.obj()
                            Json.set(o, "project", Json.of(p.name))
                            Json.set(o, "hook", Json.of(hn))
                            Json.set(o, "file", Json.of(res.file))
                            Json.set(o, "installed", Json.of(res.installed))
                            Json.set(o, "created", Json.of(res.created))
                            arr.add(o)
                        }
                        printOut(Json.pretty(JArr(arr)))
                    } else {
                        for (hn in HOOK_KINDS) {
                            let res = installHookFor(p.path, engine, hn)
                            Log.ok("${p.name}：已安装 ${hn} 钩子 → ${res.file}")
                        }
                    }
                case "uninstall" =>
                    if (ctx.json) {
                        let arr = ArrayList<JsonValue>()
                        for (hn in HOOK_KINDS) {
                            let res = uninstallHookFor(p.path, hn)
                            let o = Json.obj()
                            Json.set(o, "project", Json.of(p.name))
                            Json.set(o, "hook", Json.of(hn))
                            Json.set(o, "file", Json.of(res.file))
                            Json.set(o, "removed", Json.of(res.replaced))
                            arr.add(o)
                        }
                        printOut(Json.pretty(JArr(arr)))
                    } else {
                        for (hn in HOOK_KINDS) {
                            let res = uninstallHookFor(p.path, hn)
                            if (res.replaced) {
                                Log.ok("${p.name}：已卸载 ${hn} 钩子块")
                            }
                        }
                    }
                case "status" =>
                    if (ctx.json) {
                        let o = Json.obj()
                        Json.set(o, "project", Json.of(p.name))
                        let arr = ArrayList<JsonValue>()
                        for (hn in HOOK_KINDS) {
                            arr.add(Json.of(hookInstalledFor(p.path, hn)))
                        }
                        Json.set(o, "installed", JArr(arr))
                        printOut(Json.pretty(o))
                    } else {
                        let states = ArrayList<String>()
                        for (hn in HOOK_KINDS) {
                            let on = hookInstalledFor(p.path, hn)
                            states.add("${hn} ${if (on) { "✓" } else { "—" }}")
                        }
                        printOut("${p.name}：${joinStrings(states, " · ")}")
                    }
                case _ =>
                    throw DgError.usage("未知 hook 子命令：${action}")
            }
        } catch (e: Exception) {
            failed = true
            Log.error("${p.name}: ${e.message}")
        }
    }
    return if (failed) { 1 } else { 0 }
}

func cmdConfig(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let sub = positionalsOnly(rest, VALUE_FLAGS)
    let cfg = loadConfig()
    if (sub.size == 0 || sub[0] == "list") {
        if (ctx.json) {
            printOut(Json.pretty(configToJson(cfg)))
            return 0
        }
        printOut("语言：${cfg.language}")
        printOut("扫描根：${if (cfg.roots.size == 0) { "（未设置）" } else { joinStrings(cfg.roots, ", ") } }")
        printOut("文档：${joinStrings(cfg.docs, ", ")}")
        printOut("分支上限：${cfg.maxShallowBranches}")
        printOut("AI：由客户端层负责（deepGit.app 设置），引擎保持 AI 无关")
        return 0
    }
    if (sub[0] == "get") {
        if (sub.size < 2) {
            throw DgError.usage("用法：deepgit config get <键>")
        }
        let key = sub[1]
        let value = configGetValue(cfg, key)
        if (ctx.json) {
            printOut(Json.pretty(value))
        } else {
            printOut(Json.compact(value))
        }
        return 0
    }
    if (sub[0] == "set") {
        if (sub.size < 3) {
            throw DgError.usage("用法：deepgit config set <键> <值>")
        }
        let key = sub[1]
        let value = sub[2]
        let updated = configSetValue(cfg, key, value)
        saveConfig(updated)
        Log.ok("已设置 ${key} = ${value}")
        return 0
    }
    throw DgError.usage("未知 config 子命令：${sub[0]}")
}

func configGetValue(cfg: Config, key: String): JsonValue {
    match (key) {
        case "language" => return Json.of(cfg.language)
        case "update.backupKeep" => return Json.of(cfg.backupKeep)
        case "update.maxShallowBranches" => return Json.of(cfg.maxShallowBranches)
        case "server.port" => return Json.of(cfg.serverPort)
        case "server.host" => return Json.of(cfg.serverHost)
        case "roots" => return jsonStrArray(cfg.roots)
        case _ => return Json.null()
    }
}

func configSetValue(cfg: Config, key: String, value: String): Config {
    match (key) {
        case "language" =>
            cfg.language = value
        case "update.backupKeep" => cfg.backupKeep = parseInt(value, cfg.backupKeep)
        case "update.maxShallowBranches" => cfg.maxShallowBranches = parseInt(value, cfg.maxShallowBranches)
        case "server.port" => cfg.serverPort = parseInt(value, cfg.serverPort)
        case "server.host" => cfg.serverHost = value
        case "roots" =>
            let parts = value.split(",")
            let arr = ArrayList<String>()
            for (p in parts) {
                let t = p.trimAscii()
                if (t.size > 0) {
                    arr.add(t)
                }
            }
            cfg.roots = arr
        case _ => throw DgError.usage("未知配置键：${key}")
    }
    return cfg
}

func parseInt(s: String, fallback: Int64): Int64 {
    try {
        return Int64.parse(s.trimAscii())
    } catch (e: Exception) {
        return fallback
    }
}

/// 校验「只改托管区域」承诺：对比备份与当前文档的用户内容
func cmdVerify(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    var failures = 0
    var checked = 0
    let rows = ArrayList<Array<String>>()
    for (p in targets) {
        let store = StorePaths(p.id)
        let backupRoot = "${store.backups}"
        if (!isDirectoryPath(backupRoot)) {
            continue
        }
        for (entry in listDir(backupRoot)) {
            if (!entry.isDirectory()) {
                continue
            }
            let docName = entry.name
            let docPath = "${p.path}/${docName}"
            if (!fileExists(docPath)) {
                continue
            }
            let backups = listDir(entry.path.toString())
            if (backups.size == 0) {
                continue
            }
            // 取最新备份（= 本次写入前）
            var latest = backups[0]
            for (b in backups) {
                if (b.name > latest.name) {
                    latest = b
                }
            }
            checked += 1
            let (ok, reason) = verifyPreservation(docPath, latest.path.toString())
            if (!ok) {
                failures += 1
            }
            rows.add([p.name, docName, if (ok) { "OK" } else { "不一致" }, reason])
        }
    }
    if (ctx.json) {
        let o = Json.obj()
        Json.set(o, "checked", Json.of(checked))
        Json.set(o, "failures", Json.of(failures))
        let arr = ArrayList<JsonValue>()
        for (row in rows) {
            let e = Json.obj()
            Json.set(e, "project", Json.of(row[0]))
            Json.set(e, "doc", Json.of(row[1]))
            Json.set(e, "ok", Json.of(row[2] == "OK"))
            Json.set(e, "note", Json.of(row[3]))
            arr.add(e)
        }
        Json.set(o, "documents", JArr(arr))
        printOut(Json.pretty(o))
        return if (failures > 0) { 1 } else { 0 }
    }
    if (checked == 0) {
        Log.info("暂无可校验的文档（需要先执行 deepgit update）")
        return 0
    }
    printOut(renderTable(["项目", "文档", "结果", "说明"], rows.toArray()))
    Log.info("")
    if (failures == 0) {
        Log.ok("校验通过：${checked} 份文档的用户内容均未被改动")
        return 0
    }
    Log.error("${failures} 份文档存在非托管内容改动（可用备份恢复）")
    return 1
}

func cmdDoctor(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let checks = ArrayList<Array<String>>()
    let gitOk = commandExists("git")
    checks.add(["git", if (gitOk) { "OK" } else { "缺失" }, if (gitOk) { gitRun(".", ["--version"], true) } else { "需要安装 git" }])
    let curlOk = commandExists("curl")
    checks.add(["curl", if (curlOk) { "OK" } else { "缺失" }, "部分操作可用性探测"])
    checks.add(["数据目录", if (isDirectoryPath(deepgitHome())) { "OK" } else { "未创建" }, deepgitHome()])
    let reg = loadRegistry()
    checks.add(["注册项目", "${reg.projects.size}", "用 `deepgit scan` 添加"])
    let missing = ArrayList<String>()
    for (p in reg.projects) {
        if (!isDirectoryPath(p.path)) {
            missing.add(p.name)
        }
    }
    checks.add(["路径有效", if (missing.size == 0) { "OK" } else { "${missing.size} 个失效" }, joinStrings(missing, ", ")])
    checks.add(["当前目录", "项目内", normalizePath(expandHome(getCwd()))])

    if (ctx.json) {
        let o = Json.obj()
        let arr = ArrayList<JsonValue>()
        for (row in checks) {
            let e = Json.obj()
            Json.set(e, "check", Json.of(row[0]))
            Json.set(e, "result", Json.of(row[1]))
            Json.set(e, "detail", Json.of(row[2]))
            arr.add(e)
        }
        Json.set(o, "checks", JArr(arr))
        printOut(Json.pretty(o))
        return 0
    }
    printOut(renderTable(["检查项", "结果", "详情"], checks.toArray()))
    return 0
}

/// 当前可执行文件路径（用于钩子内嵌回退）
func currentExecutable(): String {
    match (getVariable("DEEPGIT_BIN")) {
        case Some(v) =>
            if (v.trimAscii().size > 0) {
                return v.trimAscii()
            }
        case None => ()
    }
    // 从进程参数第 0 项推断
    let args = getCommandLine()
    if (args.size > 0 && args[0].startsWith("/")) {
        return args[0]
    }
    return "deepgit"
}

func getCwd(): String {
    return getWorkingDirectory().toString()
}

// serve 命令在 http.cj 中实现（被 cli 引用）
