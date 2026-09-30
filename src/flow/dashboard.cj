// 跨项目聚合仪表盘：项目群健康度 + 里程碑总览 + 语言分布 + 合入候选。
package deepgit.flow

import std.collection.*
import std.convert.*
import deepgit.kernel.*
import deepgit.util.*
import std.unittest.*
import std.unittest.testmacro.*

public func buildDashboard(projects: ArrayList<ProjectEntry>, config: Config): JsonValue {
    let o = Json.obj()
    let statuses = allProjectStatuses(projects, config, true)

    var total: Int64 = 0
    var dirtyProjects: Int64 = 0
    var branchTotal: Int64 = 0
    var mergeCandidates: Int64 = 0
    var untrackedTotal: Int64 = 0
    var stashTotal: Int64 = 0
    var commits7d: Int64 = 0
    var commits30d: Int64 = 0

    let langCounts = ArrayList<(String, Int64)>()
    let hotProjects = ArrayList<JsonValue>()  // 近 7 天有提交的项目

    for (s in statuses) {
        if (Json.has(s, "error")) {
            continue
        }
        total += 1
        if (Json.intAt(s, "userDirtyCount", 0) > 0) {
            dirtyProjects += 1
        }
        untrackedTotal += Json.intAt(s, "untrackedCount", 0)
        stashTotal += Json.intAt(s, "stashCount", 0)
        let branches = Json.arrAt(s, "branches")
        branchTotal += branches.size
        for (b in branches) {
            let ahead = Json.intAt(b, "pendingCommits", 0)
            if (ahead > 0 && !Json.boolAt(b, "isDefault", false)) {
                mergeCandidates += 1
            }
        }

        // 语言分布：git 项目统计跟踪文件的语言构成
        match (projectById(projects, Json.strAt(s, "id", ""))) {
            case Some(p) =>
                if (p.kind == "git") {
                    let files = lsFiles(p.path, 20000)
                    for ((lang, count) in langStats(files, 12)) {
                        bumpCount(langCounts, lang, count)
                    }
                }
            case None => ()
        }

        // 近 7/30 天活跃：由 lastCommitAt 推算
        let lastAt = Json.strAt(s, "lastCommitAt", "")
        if (!lastAt.isEmpty()) {
            match (parseIsoMillis(lastAt)) {
                case Some(ms) =>
                    let nowMs = nowMillis()
                    let ageDays = (nowMs - ms) / 86400000
                    if (ageDays <= 7) {
                        commits7d += 1
                        hotProjects.add(s)
                    }
                    if (ageDays <= 30) {
                        commits30d += 1
                    }
                case None => ()
            }
        }
    }

    // 活跃项目统计
    let projs = Json.obj()
    Json.set(projs, "total", Json.of(total))
    Json.set(projs, "dirty", Json.of(dirtyProjects))
    Json.set(projs, "active7d", Json.of(commits7d))
    Json.set(projs, "active30d", Json.of(commits30d))
    Json.set(o, "projects", projs)

    let work = Json.obj()
    Json.set(work, "branches", Json.of(branchTotal))
    Json.set(work, "mergeCandidates", Json.of(mergeCandidates))
    Json.set(work, "untrackedFiles", Json.of(untrackedTotal))
    Json.set(work, "stashes", Json.of(stashTotal))
    Json.set(o, "work", work)

    // 语言分布（降序）
    let langs = ArrayList<(String, Int64)>(langCounts)
    var a: Int64 = 1
    while (a < langs.size) {
        let key = langs[a]
        var b = a - 1
        while (b >= 0 && langs[b][1] < key[1]) {
            langs[b + 1] = langs[b]
            b -= 1
        }
        langs[b + 1] = key
        a += 1
    }
    let langArr = ArrayList<JsonValue>()
    for ((lang, count) in langs) {
        if (lang == "Markdown") {
            continue  // 文档不计入语言分布
        }
        let lo = Json.obj()
        Json.set(lo, "language", Json.of(lang))
        Json.set(lo, "count", Json.of(count))
        langArr.add(lo)
    }
    Json.set(o, "languages", JArr(langArr))

    // 里程碑总览
    let ms = buildMilestoneOverview(projects, config)
    Json.set(o, "milestones", ms)

    let hot = ArrayList<JsonValue>()
    for (h in hotProjects) {
        let ho = Json.obj()
        Json.set(ho, "name", Json.of(Json.strAt(h, "name", "")))
        Json.set(ho, "lastCommitAgo", Json.of(Json.strAt(h, "lastCommitAgo", "")))
        Json.set(ho, "headline", Json.of(Json.strAt(h, "headline", "")))
        hot.add(ho)
    }
    Json.set(o, "activeProjects", JArr(hot))
    Json.set(o, "fetchedAt", Json.of(nowIso()))
    return o
}

/// 里程碑总览：各项目 open/done/overdue 统计 + 即将到期列表
public func buildMilestoneOverview(projects: ArrayList<ProjectEntry>, config: Config): JsonValue {
    let o = Json.obj()
    var open: Int64 = 0
    var done: Int64 = 0
    var dropped: Int64 = 0
    let items = ArrayList<JsonValue>()

    for (p in projects) {
        for (m in milestonesFor(p.id)) {
            let prog = milestoneProgress(m, p.path, "")
            match (prog.effectiveStatus) {
                case "open" => open += 1
                case "done" => done += 1
                case "dropped" => dropped += 1
                case _ => ()
            }
            let it = Json.obj()
            Json.set(it, "projectId", Json.of(p.id))
            Json.set(it, "projectName", Json.of(p.name))
            Json.set(it, "name", Json.of(m.name))
            Json.set(it, "description", Json.of(m.description))
            Json.set(it, "status", Json.of(prog.effectiveStatus))
            Json.set(it, "targetDate", Json.of(m.targetDate))
            Json.set(it, "daysToTarget", Json.of(prog.daysToTarget))
            Json.set(it, "overdue", Json.of(prog.overdue))
            Json.set(it, "tag", Json.of(prog.tagName))
            Json.set(it, "tagReached", Json.of(prog.tagReached))
            Json.set(it, "commitsSince", Json.of(prog.commitsSince))
            items.add(it)
        }
    }

    // 排序：overdue 在前，然后按 targetDate 升序
    var i: Int64 = 1
    while (i < items.size) {
        let key = items[i]
        var j = i - 1
        while (j >= 0 && milestoneSortKey(items[j]) > milestoneSortKey(key)) {
            items[j + 1] = items[j]
            j -= 1
        }
        items[j + 1] = key
        i += 1
    }

    let counts = Json.obj()
    Json.set(counts, "open", Json.of(open))
    Json.set(counts, "done", Json.of(done))
    Json.set(counts, "dropped", Json.of(dropped))
    Json.set(o, "counts", counts)
    Json.set(o, "items", JArr(items))
    return o
}

func milestoneSortKey(item: JsonValue): Int64 {
    let overduePenalty = if (Json.boolAt(item, "overdue", false)) { 0 } else { 100000 }
    let days = Json.intAt(item, "daysToTarget", -1)
    // 未设置日期的排最后
    let d = if (days == -1) { 99999 } else { days }
    return overduePenalty + d
}

func projectById(projects: ArrayList<ProjectEntry>, id: String): Option<ProjectEntry> {
    for (p in projects) {
        if (p.id == id) {
            return Some(p)
        }
    }
    return None
}

func bumpCount(list: ArrayList<(String, Int64)>, key: String, amount: Int64): Unit {
    var found = false
    for (i in 0..list.size) {
        if (list[i][0] == key) {
            list[i] = (key, list[i][1] + amount)
            found = true
            break
        }
    }
    if (!found) {
        list.add((key, amount))
    }
}

@Test
func testBumpCountAndProjectById(): Unit {
    let list = ArrayList<(String, Int64)>([("Swift", 2)])
    bumpCount(list, "Swift", 3)
    bumpCount(list, "Cangjie", 5)
    @Assert(list.size == 2)
    @Assert(list[0] == ("Swift", 5))
    @Assert(list[1] == ("Cangjie", 5))

    let reg = Registry()
    let p = ProjectEntry("p_x", "demo", "/tmp/demo", "git", "", nowIso(), ArrayList<String>(), false)
    reg.projects.add(p)
    @Assert(projectById(reg.projects, "p_x").isSome())
    @Assert(projectById(reg.projects, "p_none").isNone())
}

@Test
func testMilestoneSortKeyOrdering(): Unit {
    // 构造：逾期(应最前)、未来 10 天、未来 3 天、无日期(最后)
    let overdue = Json.obj()
    Json.set(overdue, "overdue", Json.of(true))
    Json.set(overdue, "daysToTarget", Json.of(-5))
    let soon = Json.obj()
    Json.set(soon, "overdue", Json.of(false))
    Json.set(soon, "daysToTarget", Json.of(3))
    let later = Json.obj()
    Json.set(later, "overdue", Json.of(false))
    Json.set(later, "daysToTarget", Json.of(10))
    let noDate = Json.obj()
    Json.set(noDate, "overdue", Json.of(false))
    Json.set(noDate, "daysToTarget", Json.of(-1))
    @Assert(milestoneSortKey(overdue) < milestoneSortKey(soon))
    @Assert(milestoneSortKey(soon) < milestoneSortKey(later))
    @Assert(milestoneSortKey(later) < milestoneSortKey(noDate))
}

@Test
func testBuildDashboardOnEmptyRegistry(): Unit {
    let config = Config.defaults()
    let reg = Registry()
    let d = buildDashboard(reg.projects, config)
    @Assert(Json.intAt(Json.getOr(d, "projects"), "total", -1) == 0)
    @Assert(Json.arrAt(d, "languages").size == 0)
    @Assert(Json.arrAt(d, "activeProjects").size == 0)
    let ms = Json.getOr(d, "milestones")
    @Assert(Json.intAt(Json.getOr(ms, "counts"), "open", -1) == 0)
    @Assert(Json.arrAt(ms, "items").size == 0)
}
