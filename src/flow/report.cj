// 报告导出：把项目群进度渲染成一份自包含的 Markdown 报告。
package deepgit.flow

import std.collection.*
import deepgit.kernel.*
import deepgit.util.*
import std.unittest.*
import std.unittest.testmacro.*

/// 生成 Markdown 报告。statuses 为 allProjectStatuses 结果，dash 为 buildDashboard 结果。
public func renderReportMarkdown(statuses: ArrayList<JsonValue>, dash: JsonValue, lang: String): String {
    let zh = lang != "en"
    let sb = StringBuilder()
    sb.append("# deepGit 进度报告\n\n")
    sb.append("> 生成于 ${formatDateTime(nowIso())} · ${Json.intAt(Json.getOr(dash, "projects"), "total", 0)} 个项目\n\n")

    // ---- 项目群总览 ----
    let projs = Json.getOr(dash, "projects")
    let work = Json.getOr(dash, "work")
    sb.append("## 项目群总览\n\n")
    sb.append("| 指标 | 数值 |\n|---|---|\n")
    sb.append("| 项目总数 | ${Json.intAt(projs, "total", 0)} |\n")
    sb.append("| 近 7 天活跃 | ${Json.intAt(projs, "active7d", 0)} |\n")
    sb.append("| 近 30 天活跃 | ${Json.intAt(projs, "active30d", 0)} |\n")
    sb.append("| 有未提交改动 | ${Json.intAt(projs, "dirty", 0)} |\n")
    sb.append("| 待合入分支 | ${Json.intAt(work, "mergeCandidates", 0)} |\n")
    sb.append("| 未跟踪文件 | ${Json.intAt(work, "untrackedFiles", 0)} |\n")
    sb.append("\n")

    // ---- 语言分布 ----
    let langs = Json.arrAt(dash, "languages")
    if (langs.size > 0) {
        sb.append("## 语言分布\n\n")
        let parts = ArrayList<String>()
        var n: Int64 = 0
        for (l in langs) {
            if (n >= 8) {
                break
            }
            parts.add("${Json.strAt(l, "language", "")} (${Json.intAt(l, "count", 0)})")
            n += 1
        }
        sb.append(joinStrings(parts, " · "))
        sb.append("\n\n")
    }

    // ---- 里程碑 ----
    let ms = Json.getOr(dash, "milestones")
    let msItems = Json.arrAt(ms, "items")
    if (msItems.size > 0) {
        sb.append("## 里程碑\n\n")
        sb.append("| 项目 | 里程碑 | 状态 | 目标 | 备注 |\n|---|---|---|---|---|\n")
        for (it in msItems) {
            let status = Json.strAt(it, "status", "")
            let label = match (status) {
                case "done" => "✓ 已达成"
                case "dropped" => "✗ 已放弃"
                case _ => if (Json.boolAt(it, "overdue", false)) { "⚠ 已逾期" } else { "进行中" }
            }
            let days = Json.intAt(it, "daysToTarget", -1)
            var note = ""
            if (Json.boolAt(it, "tagReached", false)) {
                note = "tag 已存在"
            } else if (days >= 0) {
                note = "还剩 ${days} 天"
            } else if (days != -1) {
                note = "逾期 ${-days} 天"
            }
            sb.append("| ${Json.strAt(it, "projectName", "")} | ${Json.strAt(it, "name", "")} | ${label} | ${Json.strAt(it, "targetDate", "")} | ${note} |\n")
        }
        sb.append("\n")
    }

    // ---- 各项目详情 ----
    sb.append("## 项目详情\n\n")
    for (s in statuses) {
        let name = Json.strAt(s, "name", "")
        if (Json.has(s, "error")) {
            sb.append("### ${name}（状态获取失败）\n\n")
            continue
        }
        sb.append("### ${name}\n\n")
        sb.append("- **现状**：${Json.strAt(s, "headline", "")}\n")
        let branch = Json.strAt(s, "currentBranch", "")
        if (!branch.isEmpty()) {
            sb.append("- **当前分支**：${branch} · 默认分支 ${Json.strAt(s, "defaultBranch", "")}\n")
        }
        let dirty = Json.intAt(s, "userDirtyCount", 0)
        let untracked = Json.intAt(s, "untrackedCount", 0)
        let stash = Json.intAt(s, "stashCount", 0)
        sb.append("- **工作区**：${dirty} 个未提交改动 · ${untracked} 个未跟踪文件 · ${stash} 条 stash\n")
        match (Json.get(s, "mergeHint")) {
            case Some(mh) =>
                sb.append("- **合入提示**：`${Json.strAt(mh, "target", "")}` ${Json.strAt(mh, "description", "")}\n")
            case None => ()
        }

        let branches = Json.arrAt(s, "branches")
        if (branches.size > 0) {
            sb.append("\n| 分支 | 状态 | 领先 | 最近提交 |\n|---|---|---|---|\n")
            for (b in branches) {
                let marker = if (Json.boolAt(b, "isCurrent", false)) { "▸ " } else { "" }
                sb.append("| ${marker}${Json.strAt(b, "name", "")} | ${Json.strAt(b, "statusLabel", "")} | ${Json.intAt(b, "pendingCommits", 0)} | ${Json.strAt(b, "headAgo", "")} ${Json.strAt(b, "headSubject", "")} |\n")
            }
        }

        // 提交构成
        let cts = Json.arrAt(s, "commitTypes")
        if (cts.size > 0) {
            let parts = ArrayList<String>()
            for (ct in cts) {
                parts.add("${Json.strAt(ct, "type", "")} ×${Json.intAt(ct, "count", 0)}")
            }
            sb.append("\n提交构成（近期）：${joinStrings(parts, " · ")}\n")
        }
        sb.append("\n")
    }

    sb.append("---\n\n")
    let sourceNote = if (zh) { "本地数据，未出网" } else { "local data only" }
    sb.append("_本报告由 deepGit 自动生成（" + sourceNote + "）_\n")
    return sb.toString()
}

// ------------------------------ 测试 ------------------------------

@Test
func testRenderReportMarkdown(): Unit {
    let config = Config.defaults()
    let reg = Registry()
    let dash = buildDashboard(reg.projects, config)
    let statuses = allProjectStatuses(reg.projects, config, true)
    let md = renderReportMarkdown(statuses, dash, "zh")
    @Assert(md.contains("# deepGit 进度报告"))
    @Assert(md.contains("## 项目群总览"))
    @Assert(md.contains("项目总数"))
    @Assert(md.contains("## 项目详情"))
}

@Test
func testRenderReportWithRealRepo(): Unit {
    let base = "/tmp/deepgit-rep-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/a.cj", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: first"], true)
    gitRun(base, ["checkout", "-q", "-b", "feat/pending"], true)
    writeFileAtomic(base + "/a.cj", "2")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fix: pending work"], true)
    gitRun(base, ["checkout", "-q", "main"], true)

    let config = Config.defaults()
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_rep", "rep-demo", base, "git", "", nowIso(), ArrayList<String>(), false))
    let statuses = allProjectStatuses(reg.projects, config, false)
    let dash = buildDashboard(reg.projects, config)
    let md = renderReportMarkdown(statuses, dash, "zh")
    @Assert(md.contains("## 项目详情"))
    @Assert(md.contains("### rep-demo"))
    @Assert(md.contains("**现状**"))
    @Assert(md.contains("**当前分支**：main"))
    @Assert(md.contains("提交构成"))
    @Assert(md.contains("feat ×1"))
    removePathIfExists(base)
}

@Test
func testRenderReportSkipsErrorProjects(): Unit {
    let p = ProjectEntry("p_bad", "bad", "/tmp/definitely-not-a-repo-xx", "git", "", nowIso(), ArrayList<String>(), false)
    let reg = Registry()
    reg.projects.add(p)
    let config = Config.defaults()
    let statuses = allProjectStatuses(reg.projects, config, true)
    let dash = buildDashboard(reg.projects, config)
    let md = renderReportMarkdown(statuses, dash, "zh")
    // 失败项目要么被错误隔离标注，要么根本不出现在详情里，但不能让报告崩掉
    @Assert(md.contains("# deepGit 进度报告"))
}

@Test
func testUpdateWritesPulseIntoReadme(): Unit {
    let base = "/tmp/deepgit-pulse-e2e-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: 初始功能"], true)

    let config = Config.defaults()
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_pulse", "pulse-demo", base, "git", "", nowIso(), ArrayList<String>(), false))
    let p = reg.projects[0]
    let opts = UpdateOptions()
    opts.mode = "shallow"
    opts.source = "test"
    let r = runUpdate(p, config, opts)
    @Assert(r.ok)

    let readme = readFileText(base + "/README.md").getOrThrow()
    @Assert(readme.contains("deepgit:begin progress"))
    @Assert(readme.contains("工程脉搏"))
    @Assert(readme.contains("提交构成"))
    @Assert(readme.contains("`feat` ×1"))
    removePathIfExists(base)
}
