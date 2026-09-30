// 状态聚合：CLI / Web / macOS 菜单栏三端共用的单一事实源。
package deepgit.flow

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.kernel.*
import deepgit.util.*

public func projectStatus(project: ProjectEntry, config: Config, journalLimit: Int64): JsonValue {
    let facts = collectFacts(project.path, project.kind, config, 15, false)
    let progress = readProgress(project.id)
    let state = readState(project.id)
    let journal = readJournal(project.id, journalLimit)

    let o = Json.obj()
    Json.set(o, "id", Json.of(project.id))
    Json.set(o, "name", Json.of(project.name))
    Json.set(o, "path", Json.of(project.path))
    Json.set(o, "kind", Json.of(project.kind))
    Json.set(o, "remote", Json.of(facts.remote))
    let tagsArr = ArrayList<JsonValue>()
    for (t in project.tags) {
        tagsArr.add(Json.of(t))
    }
    Json.set(o, "tags", JArr(tagsArr))
    Json.set(o, "headline", Json.of(computeHeadline(facts, progress, config.language)))
    Json.set(o, "currentBranch", Json.of(facts.currentBranch))
    Json.set(o, "defaultBranch", Json.of(facts.defaultBranch))
    Json.set(o, "dirty", facts.dirty.toJson())
    Json.set(o, "userDirtyCount", Json.of(userDirtyCount(facts)))
    Json.set(o, "stashCount", Json.of(facts.stashCount))
    Json.set(o, "commitCount", Json.of(facts.commitCount))
    Json.set(o, "lastCommitAt", Json.of(facts.lastCommitAt))
    Json.set(o, "lastCommitAgo", Json.of(if (facts.lastCommitAt.size > 0) { timeAgo(facts.lastCommitAt, config.language) } else { "" }))

    // 分支视图（含状态刷新）
    let branches = ArrayList<JsonValue>()
    for ((name, rec) in progressBranches(progress)) {
        let headDate = Json.strAt(rec, "headDate", "")
        let merged = Json.boolAt(rec, "merged", false)
        let isDefault = name == facts.defaultBranch
        let status = if (merged && !isDefault) { "merged" } else { computeBranchStatus(headDate, false) }
        let b = Json.obj()
        Json.set(b, "name", Json.of(name))
        Json.set(b, "status", Json.of(status))
        Json.set(b, "statusLabel", Json.of(statusLabel(status, config.language)))
        Json.set(b, "head", Json.of(Json.strAt(rec, "head", "")))
        Json.set(b, "headShort", Json.of(shortSha(Json.strAt(rec, "head", ""))))
        Json.set(b, "headDate", Json.of(headDate))
        Json.set(b, "headAgo", Json.of(if (headDate.size > 0) { timeAgo(headDate, config.language) } else { "" }))
        Json.set(b, "headSubject", Json.of(Json.strAt(rec, "headSubject", "")))
        Json.set(b, "summary", Json.of(Json.strAt(rec, "summary", "")))
        let hl = ArrayList<JsonValue>()
        for (h in Json.strArrAt(rec, "highlights")) {
            hl.add(Json.of(h))
        }
        Json.set(b, "highlights", JArr(hl))
        let ns = ArrayList<JsonValue>()
        for (h in Json.strArrAt(rec, "nextSteps")) {
            ns.add(Json.of(h))
        }
        Json.set(b, "nextSteps", JArr(ns))
        Json.set(b, "aheadOfDefault", Json.of(Json.intAt(rec, "aheadOfDefault", 0)))
        Json.set(b, "merged", Json.of(merged))
        Json.set(b, "pendingCommits", Json.of(Json.intAt(rec, "pendingCommits", 0)))
        Json.set(b, "provider", Json.of(Json.strAt(rec, "provider", "rules")))
        Json.set(b, "isCurrent", Json.of(name == facts.currentBranch))
        Json.set(b, "isDefault", Json.of(isDefault))
        Json.set(b, "updatedAt", Json.of(Json.strAt(rec, "updatedAt", "")))
        Json.set(b, "staleDays", Json.of(if (headDate.size > 0) { Int64(daysSince(headDate)) } else { -1 }))
        branches.add(b)
    }

    // 排序：当前 > 默认 > 其他（未合并在前）
    let sorted = ArrayList<JsonValue>()
    let remaining = ArrayList<JsonValue>()
    for (b in branches) {
        remaining.add(b)
    }
    // 简单稳定排序
    var i: Int64 = 1
    while (i < remaining.size) {
        let key = remaining[i]
        var j = i - 1
        while (j >= 0 && branchScore(remaining[j]) > branchScore(key)) {
            remaining[j + 1] = remaining[j]
            j -= 1
        }
        remaining[j + 1] = key
        i += 1
    }
    for (b in remaining) {
        sorted.add(b)
    }
    Json.set(o, "branches", JArr(sorted))
    Json.set(o, "overall", Json.getOr(progress, "overall"))

    // 文档
    let docsArr = ArrayList<JsonValue>()
    for (file in facts.docsPresent) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(file))
        Json.set(d, "exists", Json.of(true))
        docsArr.add(d)
    }
    Json.set(o, "docs", JArr(docsArr))
    Json.set(o, "manifests", jsonStrArray(facts.manifests))

    // 浅更新增强：类型分布 / 未跟踪 / 多工作区 / 合入提示
    let ctArr = ArrayList<JsonValue>()
    for ((t, count) in facts.commitTypes) {
        let cto = Json.obj()
        Json.set(cto, "type", Json.of(t))
        Json.set(cto, "count", Json.of(count))
        ctArr.add(cto)
    }
    Json.set(o, "commitTypes", JArr(ctArr))
    Json.set(o, "untrackedCount", Json.of(facts.untrackedCount))
    Json.set(o, "worktreeCount", Json.of(facts.worktreeCount))
    match (facts.mergeHint) {
        case Some(m) => Json.set(o, "mergeHint", m.toJson())
        case None => ()
    }

    // 进度元信息
    let meta = Json.obj()
    Json.set(meta, "updatedAt", Json.of(Json.strAt(progress, "updatedAt", "")))
    Json.set(meta, "lastUpdateAt", Json.of(Json.strAt(state, "lastUpdateAt", "")))
    Json.set(meta, "lastTrackAt", Json.of(Json.strAt(state, "lastTrackAt", "")))
    Json.set(meta, "lastDeepAt", Json.of(Json.strAt(state, "lastDeepAt", "")))
    Json.set(meta, "entryCount", Json.of(Json.arrAt(progress, "entries").size))
    Json.set(meta, "runCount", Json.of(Json.intAt(state, "runCount", 0)))
    Json.set(o, "progress", meta)

    // 日志
    let jArr = ArrayList<JsonValue>()
    for (e in journal) {
        let je = Json.obj()
        Json.set(je, "id", Json.of(Json.strAt(e, "id", "")))
        Json.set(je, "at", Json.of(Json.strAt(e, "at", "")))
        Json.set(je, "mode", Json.of(Json.strAt(e, "mode", "")))
        Json.set(je, "branch", Json.of(Json.strAt(e, "branch", "")))
        Json.set(je, "summary", Json.of(Json.strAt(e, "summary", "")))
        Json.set(je, "provider", Json.of(Json.strAt(e, "provider", "")))
        Json.set(je, "providerLabel", Json.of(providerLabel(Json.strAt(e, "provider", ""))))
        Json.set(je, "commitCount", Json.of(Json.intAt(e, "commitCount", 0)))
        Json.set(je, "docs", jsonStrArray(Json.strArrAt(e, "docs")))
        jArr.add(je)
    }
    Json.set(o, "journal", JArr(jArr))

    if (facts.warnings.size > 0) {
        Json.set(o, "warnings", jsonStrArray(facts.warnings))
    }
    Json.set(o, "fetchedAt", Json.of(nowIso()))
    return o
}

func branchScore(b: JsonValue): Int64 {
    if (Json.boolAt(b, "isCurrent", false)) {
        return 0
    }
    if (Json.boolAt(b, "isDefault", false)) {
        return 1
    }
    if (Json.boolAt(b, "merged", false)) {
        return 4
    }
    return 2
}

public func jsonStrArray(items: ArrayList<String>): JsonValue {
    let arr = ArrayList<JsonValue>()
    for (s in items) {
        arr.add(Json.of(s))
    }
    return JArr(arr)
}

func errorStatusJson(p: ProjectEntry, message: String): JsonValue {
    let err = Json.obj()
    Json.set(err, "id", Json.of(p.id))
    Json.set(err, "name", Json.of(p.name))
    Json.set(err, "path", Json.of(p.path))
    Json.set(err, "kind", Json.of(p.kind))
    Json.set(err, "error", Json.of(message))
    Json.set(err, "headline", Json.of("状态获取失败"))
    Json.set(err, "branches", JArr(ArrayList<JsonValue>()))
    Json.set(err, "journal", JArr(ArrayList<JsonValue>()))
    return err
}

/// 全部项目状态（含单项目失败隔离）。
/// 每个项目用 std.sync.spawn 并发采集：互为独立的只读 git 子进程，无共享可变状态，
/// 单项目失败只影响自身条目。
public func allProjectStatuses(projects: ArrayList<ProjectEntry>, config: Config, light: Bool): ArrayList<JsonValue> {
    let limit = if (light) { 3 } else { 8 }
    let futures = ArrayList<(ProjectEntry, Future<JsonValue>)>()
    for (p in projects) {
        if (p.disabled) {
            continue
        }
        let target = p
        let cfg = config
        let jl = limit
        futures.add((target, spawn {
            try {
                return projectStatus(target, cfg, jl)
            } catch (e: Exception) {
                return errorStatusJson(target, e.message)
            }
        }))
    }
    let out = ArrayList<JsonValue>()
    for ((_, f) in futures) {
        out.add(f.get())
    }
    return out
}

/// 项目群总览统计
public func groupSummary(statuses: ArrayList<JsonValue>, config: Config): JsonValue {
    let o = Json.obj()
    var total: Int64 = 0
    var active: Int64 = 0
    var stale: Int64 = 0
    var dirtyProjects: Int64 = 0
    var branchTotal: Int64 = 0
    for (s in statuses) {
        if (Json.has(s, "error")) {
            continue
        }
        total += 1
        let branches = Json.arrAt(s, "branches")
        branchTotal += branches.size
        if (Json.intAt(s, "userDirtyCount", 0) > 0) {
            dirtyProjects += 1
        }
        var hasStale = false
        var hasActive = false
        for (b in branches) {
            let st = Json.strAt(b, "status", "")
            if (st == "stale") {
                hasStale = true
            }
            if (st == "active") {
                hasActive = true
            }
        }
        if (hasStale) {
            stale += 1
        }
        if (hasActive) {
            active += 1
        }
    }
    Json.set(o, "projectCount", Json.of(total))
    Json.set(o, "activeProjects", Json.of(active))
    Json.set(o, "staleProjects", Json.of(stale))
    Json.set(o, "dirtyProjects", Json.of(dirtyProjects))
    Json.set(o, "branchCount", Json.of(branchTotal))
    Json.set(o, "generatedAt", Json.of(nowIso()))
    return o
}

// ------------------------------ 测试 ------------------------------

@Test
func testProjectStatusOnRealRepo(): Unit {
    let base = "/tmp/deepgit-status-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/README.md", "# x\n")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: x"], true)
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let status = projectStatus(project, Config.defaults(), 5)
    @Assert(Json.strAt(status, "name", "") == basename(base))
    @Assert(Json.strAt(status, "kind", "") == "git")
    @Assert(Json.intAt(status, "commitCount", 0) == 1)
    @Assert(Json.strAt(status, "headline", "").size > 0)
    // README 是托管文档，即使被 deepGit 改过也不算用户脏
    @Assert(Json.intAt(status, "userDirtyCount", -1) == 0)
    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testGroupSummaryShape(): Unit {
    let statuses = ArrayList<JsonValue>()
    let s = Json.obj()
    Json.set(s, "name", Json.of("a"))
    let branches = ArrayList<JsonValue>()
    let b = Json.obj()
    Json.set(b, "status", Json.of("stale"))
    branches.add(b)
    Json.set(s, "branches", JArr(branches))
    Json.set(s, "userDirtyCount", Json.of(0))
    statuses.add(s)
    let summary = groupSummary(statuses, Config.defaults())
    @Assert(Json.intAt(summary, "projectCount", 0) == 1)
    @Assert(Json.intAt(summary, "staleProjects", 0) == 1)
}

@Test
func testAllProjectStatusesIsolatesFailures(): Unit {
    // 不存在的路径 → 降级为 dir 模式并如实报告（不抛异常、不中断整批）
    let projects = ArrayList<ProjectEntry>()
    projects.add(ProjectEntry("p_bad", "bad", "/nonexistent/path/xyz", "dir", "", nowIso(), ArrayList<String>(), false))
    projects.add(ProjectEntry("p_disabled", "disabled", "/tmp", "dir", "", nowIso(), ArrayList<String>(), true))
    let out = allProjectStatuses(projects, Config.defaults(), true)
    @Assert(out.size == 1)  // disabled 项目被跳过
    @Assert(Json.strAt(out[0], "name", "") == "bad")
    @Assert(Json.arrAt(out[0], "branches").size == 0)
}

@Test
func testErrorStatusJsonShape(): Unit {
    let p = ProjectEntry("p_err", "boom", "/tmp/boom", "git", "", nowIso(), ArrayList<String>(), false)
    let j = errorStatusJson(p, "git 坏了")
    @Assert(Json.strAt(j, "error", "") == "git 坏了")
    @Assert(Json.strAt(j, "headline", "") == "状态获取失败")
    @Assert(Json.arrAt(j, "branches").size == 0)
    @Assert(Json.arrAt(j, "journal").size == 0)
}

@Test
func testJsonStrArrayAndBranchScore(): Unit {
    let j = jsonStrArray(ArrayList<String>(["a", "b"]))
    match (Json.asArr(j)) {
        case Some(items) => @Assert(items.size == 2)
        case None => @Assert(false)
    }

    // branchScore 排序权重：当前 > 默认 > 其他
    let cur = Json.obj()
    Json.set(cur, "isCurrent", Json.of(true))
    Json.set(cur, "isDefault", Json.of(false))
    let def = Json.obj()
    Json.set(def, "isCurrent", Json.of(false))
    Json.set(def, "isDefault", Json.of(true))
    let other = Json.obj()
    Json.set(other, "isCurrent", Json.of(false))
    Json.set(other, "isDefault", Json.of(false))
    @Assert(branchScore(cur) < branchScore(def))
    @Assert(branchScore(def) < branchScore(other))
}
