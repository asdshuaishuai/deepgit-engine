// Agent 接口：为上层 AI 实现（deepGit.app / 未来的 deepDesign 式层）提供
// 「所需的一切」——预算内的 markdown 上下文包 + 可执行工具清单。
// 引擎本身是 AI 无关的：这里只做确定性的事实组装与裁剪。
package deepgit.flow

import std.collection.*
import deepgit.kernel.*
import deepgit.util.*
import std.unittest.*
import std.unittest.testmacro.*

public let AGENT_DEFAULT_BUDGET: Int64 = 12000

func projectByName(projects: ArrayList<ProjectEntry>, idOrName: String): Option<ProjectEntry> {
    for (p in projects) {
        if (p.id == idOrName || p.name == idOrName) {
            return Some(p)
        }
    }
    return None
}

/// 单项目上下文小节（输入为 allProjectStatuses 的条目）
func projectContextSection(s: JsonValue, budget: Int64): String {
    let sb = StringBuilder()
    let name = Json.strAt(s, "name", "")
    sb.append("### ${name}\n\n")
    if (Json.has(s, "error")) {
        sb.append("- 状态获取失败：${Json.strAt(s, "error", "")}\n")
        return safeSlice(sb.toString(), budget)
    }
    sb.append("- 路径：${Json.strAt(s, "path", "")}${if (Json.strAt(s, "kind", "") == "git") { "" } else { "（非 git）" }}\n")
    sb.append("- 现状：${Json.strAt(s, "headline", "")}\n")
    let currentBranch = Json.strAt(s, "currentBranch", "")
    if (!currentBranch.isEmpty()) {
        sb.append("- 分支：当前 ${currentBranch} · 默认 ${Json.strAt(s, "defaultBranch", "")}\n")
    }
    // 脉搏
    let notes = ArrayList<String>()
    let dirty = Json.intAt(s, "userDirtyCount", 0)
    let untracked = Json.intAt(s, "untrackedCount", 0)
    let stash = Json.intAt(s, "stashCount", 0)
    let worktrees = Json.intAt(s, "worktreeCount", 0)
    if (dirty > 0) {
        notes.add("未提交 ${dirty}")
    }
    if (untracked > 0) {
        notes.add("未跟踪 ${untracked}")
    }
    if (stash > 0) {
        notes.add("stash ${stash}")
    }
    if (worktrees > 1) {
        notes.add("工作区 ×${worktrees}")
    }
    match (Json.get(s, "mergeHint")) {
        case Some(mh) =>
            let kind = Json.strAt(mh, "kind", "")
            if (kind == "fast-forward" || kind == "merge") {
                notes.add(Json.strAt(mh, "description", ""))
            }
        case None => ()
    }
    if (notes.size > 0) {
        sb.append("- 脉搏：${joinStrings(notes, " · ")}\n")
    }
    // 提交构成
    let cts = Json.arrAt(s, "commitTypes")
    if (cts.size > 0) {
        let parts = ArrayList<String>()
        for (ct in cts) {
            parts.add("${Json.strAt(ct, "type", "")} ×${Json.intAt(ct, "count", 0)}")
        }
        sb.append("- 提交构成：${joinStrings(parts, " · ")}\n")
    }
    // 分支表
    let branches = Json.arrAt(s, "branches")
    if (branches.size > 0) {
        sb.append("\n| 分支 | 状态 | 待记录 | 最近提交 |\n|---|---|---|---|\n")
        for (b in branches) {
            let isCurrent = Json.boolAt(b, "isCurrent", false)
            let isDefault = Json.boolAt(b, "isDefault", false)
            let marker = if (isCurrent) { "▸" } else { if (isDefault) { "★" } else { "" } }
            sb.append("| ${marker}${Json.strAt(b, "name", "")} | ${Json.strAt(b, "statusLabel", "")} | ${Json.intAt(b, "pendingCommits", 0)} | ${Json.strAt(b, "headAgo", "")} ${Json.strAt(b, "headSubject", "")} |\n")
        }
    }
    return safeSlice(sb.toString(), budget)
}

/// 组装 agent 上下文包。
/// scope=group：总览 + 每项目速览；scope=project&name=X：单项目深上下文（含日志/里程碑）。
public func buildAgentContext(
    projects: ArrayList<ProjectEntry>, config: Config,
    scope: String, name: String, budget: Int64,
): String {
    let targets = ArrayList<ProjectEntry>()
    if (scope == "project") {
        match (projectByName(projects, name)) {
            case Some(p) => targets.add(p)
            case None => return "未找到项目：${name}"
        }
    } else {
        for (p in projects) {
            if (!p.disabled) {
                targets.add(p)
            }
        }
    }

    let statuses = allProjectStatuses(targets, config, false)
    let dash = buildDashboard(targets, config)
    let sb = StringBuilder()

    sb.append("# deepGit 项目群上下文\n\n")
    sb.append("> 生成于 ${formatDateTime(nowIso())} · 引擎为 AI 无关内核，以下为确定性事实\n\n")

    if (scope == "group") {
        let projs = Json.getOr(dash, "projects")
        let work = Json.getOr(dash, "work")
        sb.append("## 总览\n\n")
        sb.append("- 项目 ${Json.intAt(projs, "total", 0)} 个 · 近 7 天活跃 ${Json.intAt(projs, "active7d", 0)} · 有未提交改动 ${Json.intAt(projs, "dirty", 0)}\n")
        sb.append("- 分支 ${Json.intAt(work, "branches", 0)} · 待合入 ${Json.intAt(work, "mergeCandidates", 0)} · 未跟踪文件 ${Json.intAt(work, "untrackedFiles", 0)} · stash ${Json.intAt(work, "stashes", 0)}\n\n")
        sb.append("## 项目速览\n\n")
        let perBudget = if (statuses.size > 0) { budget / statuses.size } else { budget }
        for (s in statuses) {
            sb.append(projectContextSection(s, perBudget))
            sb.append("\n")
        }
    } else {
        let ms = buildMilestoneOverview(targets, config)
        let items = Json.arrAt(ms, "items")
        for (s in statuses) {
            let name2 = Json.strAt(s, "name", "")
            sb.append(projectContextSection(s, budget / 2))
            let journal = Json.arrAt(s, "journal")
            if (journal.size > 0) {
                sb.append("\n### ${name2} · 进度日志（最近 ${journal.size} 条）\n\n")
                for (e in journal) {
                    sb.append("- [${Json.strAt(e, "at", "")}] ${Json.strAt(e, "mode", "")} · ${Json.strAt(e, "branch", "")}：${Json.strAt(e, "summary", "")}\n")
                }
            }
            if (items.size > 0) {
                sb.append("\n### ${name2} · 里程碑\n\n")
                for (m in items) {
                    let mProj = Json.strAt(m, "projectName", "")
                    if (mProj == name2) {
                        let target = Json.strAt(m, "targetDate", "")
                        sb.append("- ${Json.strAt(m, "name", "")}：${Json.strAt(m, "status", "")}${if (target.isEmpty()) { "" } else { "（目标 ${target}）" }}\n")
                    }
                }
            }
        }
    }

    return safeSlice(sb.toString(), budget)
}

/// Agent 可执行的工具清单。上层 AI 把它放进 system prompt，
/// 通过对应 HTTP 端点执行；引擎只认请求，不感知 AI。
public func agentToolsManifest(): JsonValue {
    let arr = ArrayList<JsonValue>()
    func addTool(name: String, desc: String, method: String, path: String, params: String) {
        let t = Json.obj()
        Json.set(t, "name", Json.of(name))
        Json.set(t, "description", Json.of(desc))
        Json.set(t, "method", Json.of(method))
        Json.set(t, "path", Json.of(path))
        Json.set(t, "params", Json.of(params))
        arr.add(t)
    }

    addTool("get_group_context", "获取整个项目群的总览上下文（活跃度/改动/分支/待合入）", "GET", "/api/context?scope=group", "")
    addTool("get_project_context", "获取单个项目的深度上下文（分支进度/脉搏/日志/里程碑）。params: name", "GET", "/api/context?scope=project&name={name}", "name")
    addTool("get_project_docs", "读取项目内 README/AGENTS/CLAUDE 原文。params: name", "GET", "/api/docs?name={name}", "name")
    addTool("get_journal", "读取项目的进度日志。params: name", "GET", "/api/journal?name={name}", "name")
    addTool("get_milestones", "列出全部里程碑及其 git 感知进度", "GET", "/api/milestones", "")
    addTool("run_shallow_update", "对项目执行浅更新：记录各分支进度并刷新文档托管区域。params: name", "POST", "/api/update?name={name}", "name")
    addTool("run_deep_update", "对项目执行深度更新：重写 overview/architecture/commands/history。params: name", "POST", "/api/deep?name={name}", "name")
    addTool("git_commit", "提交项目的全部未提交改动。params: name, message", "POST", "/api/git", "name,message")
    addTool("git_pull_push", "对项目执行 git pull（--ff-only）或 push。params: name, op(pull|push)", "POST", "/api/git", "name,op")
    addTool("milestone_done", "把里程碑标记为达成。params: project, name", "POST", "/api/milestones/action", "project,name")

    let o = Json.obj()
    Json.set(o, "tools", JArr(arr))
    Json.set(o, "note", Json.of("引擎为 AI 无关内核；以上工具由上层 AI 通过 HTTP 调用执行"))
    return o
}

// ------------------------------ 测试 ------------------------------

@Test
func testAgentToolsManifest(): Unit {
    let m = agentToolsManifest()
    let tools = Json.arrAt(m, "tools")
    @Assert(tools.size >= 8)
    var hasContext = false
    var hasUpdate = false
    for (t in tools) {
        if (Json.strAt(t, "name", "") == "get_group_context") {
            hasContext = true
        }
        if (Json.strAt(t, "name", "") == "run_shallow_update") {
            hasUpdate = true
        }
    }
    @Assert(hasContext)
    @Assert(hasUpdate)
}

@Test
func testBuildAgentContextEmpty(): Unit {
    let config = Config.defaults()
    let reg = Registry()
    let ctx = buildAgentContext(reg.projects, config, "group", "", 8000)
    @Assert(ctx.contains("deepGit 项目群上下文"))
    let miss = buildAgentContext(reg.projects, config, "project", "ghost", 8000)
    @Assert(miss.contains("未找到项目"))
}

@Test
func testBuildAgentContextProject(): Unit {
    let base = "/tmp/deepgit-ctx-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/a.cj", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: 上下文测试"], true)

    let config = Config.defaults()
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_ctx", "ctx-demo", base, "git", "", nowIso(), ArrayList<String>(), false))
    // 先 track 一次：分支表的主题来自进度库，从未记录过的仓库只有脉搏没有主题
    let tr = runTrack(reg.projects[0], config, "test")
    @Assert(tr.ok)
    let ctx = buildAgentContext(reg.projects, config, "project", "ctx-demo", 20000)
    @Assert(ctx.contains("ctx-demo"))
    @Assert(ctx.contains("feat: 上下文测试"))
    removePathIfExists(base)
}
