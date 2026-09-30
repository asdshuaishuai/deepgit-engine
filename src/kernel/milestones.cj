// 里程碑：项目群级别的目标管理。
//
// 存储在全局 ~/.deepgit/milestones.json（单文件、跨项目聚合友好）。
// 完成判定支持两种来源：手工标记 done，或绑定 git tag 自动检测（tag 存在即达成）。
package deepgit.kernel

import std.collection.*
import std.convert.*
import std.env.*
import deepgit.util.*
import std.unittest.*
import std.unittest.testmacro.*

public class Milestone {
    public let id: String
    public let projectId: String
    public var name: String
    public var description: String
    public var targetDate: String    // YYYY-MM-DD，可为空
    public var tag: String           // 绑定的 git tag，可为空
    public var status: String        // open | done | dropped
    public var createdAt: String
    public var completedAt: String

    public init(id: String, projectId: String, name: String, description: String,
                targetDate: String, tag: String, status: String, createdAt: String, completedAt: String) {
        this.id = id
        this.projectId = projectId
        this.name = name
        this.description = description
        this.targetDate = targetDate
        this.tag = tag
        this.status = status
        this.createdAt = createdAt
        this.completedAt = completedAt
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "id", Json.of(this.id))
        Json.set(o, "projectId", Json.of(this.projectId))
        Json.set(o, "name", Json.of(this.name))
        Json.set(o, "description", Json.of(this.description))
        Json.set(o, "targetDate", Json.of(this.targetDate))
        Json.set(o, "tag", Json.of(this.tag))
        Json.set(o, "status", Json.of(this.status))
        Json.set(o, "createdAt", Json.of(this.createdAt))
        Json.set(o, "completedAt", Json.of(this.completedAt))
        return o
    }

    public static func fromJson(j: JsonValue): Milestone {
        return Milestone(
            Json.strAt(j, "id", ""),
            Json.strAt(j, "projectId", ""),
            Json.strAt(j, "name", ""),
            Json.strAt(j, "description", ""),
            Json.strAt(j, "targetDate", ""),
            Json.strAt(j, "tag", ""),
            Json.strAt(j, "status", "open"),
            Json.strAt(j, "createdAt", ""),
            Json.strAt(j, "completedAt", ""),
        )
    }
}

/// 里程碑的 git 感知进度（运行时计算，不落盘）
public class MilestoneProgress {
    public let milestone: Milestone
    public let tagName: String        // 实际生效的 tag 名（绑定或同名推导）
    public let tagReached: Bool       // tag 是否已存在于仓库
    public let commitsSince: Int64    // 自创建以来的提交数（当前分支）
    public let daysToTarget: Int64    // 距目标日期天数（正=剩余天数，负=已逾期 N 天；未设置=-1）
    public let overdue: Bool
    public let effectiveStatus: String  // 综合手工状态与 tag 检测后的状态

    public init(milestone: Milestone, tagName: String, tagReached: Bool, commitsSince: Int64,
                daysToTarget: Int64, overdue: Bool, effectiveStatus: String) {
        this.milestone = milestone
        this.tagName = tagName
        this.tagReached = tagReached
        this.commitsSince = commitsSince
        this.daysToTarget = daysToTarget
        this.overdue = overdue
        this.effectiveStatus = effectiveStatus
    }
}

func milestonesFilePath(): String {
    return deepgitPath(["milestones.json"])
}

public func loadMilestones(): ArrayList<Milestone> {
    let out = ArrayList<Milestone>()
    match (readFileText(milestonesFilePath())) {
        case Some(text) =>
            match (Json.parse(text)) {
                case Some(j) =>
                    for (m in Json.arrAt(j, "milestones")) {
                        out.add(Milestone.fromJson(m))
                    }
                case None => ()
            }
        case None => ()
    }
    return out
}

public func saveMilestones(list: ArrayList<Milestone>): Unit {
    let root = Json.obj()
    let arr = ArrayList<JsonValue>()
    for (m in list) {
        arr.add(m.toJson())
    }
    Json.set(root, "milestones", JArr(arr))
    Json.set(root, "updatedAt", Json.of(nowIso()))
    ensureDir(dirname(milestonesFilePath()))
    writeFileAtomic(milestonesFilePath(), Json.pretty(root))
}

/// 新增里程碑（同项目同名幂等：已存在则原样返回）
public func addMilestone(projectId: String, name: String, description: String,
                         targetDate: String, tag: String): (Milestone, Bool) {
    let list = loadMilestones()
    for (m in list) {
        if (m.projectId == projectId && m.name == name) {
            return (m, false)
        }
    }
    let id = "m_" + sha256HexOf(projectId + "/" + name + "/" + "${nowMillis()}")[..10]
    let m = Milestone(id, projectId, name, description, targetDate, tag, "open", nowIso(), "")
    list.add(m)
    saveMilestones(list)
    return (m, true)
}

/// 删除里程碑（按项目+名字）
public func removeMilestone(projectId: String, name: String): Bool {
    let list = loadMilestones()
    let kept = ArrayList<Milestone>()
    var removed = false
    for (m in list) {
        if (m.projectId == projectId && m.name == name) {
            removed = true
        } else {
            kept.add(m)
        }
    }
    if (removed) {
        saveMilestones(kept)
    }
    return removed
}

/// 手工标记状态：done / open / dropped
public func setMilestoneStatus(projectId: String, name: String, status: String): Bool {
    let list = loadMilestones()
    var found = false
    for (m in list) {
        if (m.projectId == projectId && m.name == name) {
            m.status = status
            m.completedAt = if (status == "done") { nowIso() } else { "" }
            found = true
        }
    }
    if (found) {
        saveMilestones(list)
    }
    return found
}

public func milestonesFor(projectId: String): ArrayList<Milestone> {
    let out = ArrayList<Milestone>()
    for (m in loadMilestones()) {
        if (m.projectId == projectId) {
            out.add(m)
        }
    }
    return out
}

public func openMilestoneCount(): Int64 {
    var n: Int64 = 0
    for (m in loadMilestones()) {
        if (m.status == "open") {
            n += 1
        }
    }
    return n
}

/// 距离某 YYYY-MM-DD 的天数（目标日 - 今天；正数=还剩 N 天，负数=已过 N 天）
public func daysFromToday(dateStr: String): Int64 {
    if (dateStr.size < 10) {
        return -1
    }
    // 仅取本地今天日期（ISO 前 10 位）
    let today = nowIso()[..10]
    return epochDays(dateStr) - epochDays(today)
}

/// 简化历法换算：YYYY-MM-DD → 自 1970-01-01 的天数
func epochDays(dateStr: String): Int64 {
    let y = Int64.parse(dateStr[0..4])
    let m = Int64.parse(dateStr[5..7])
    let d = Int64.parse(dateStr[8..10])
    // 累计各月天数（非闰年），闰年由 isLeap 修正
    let cum = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    var days = (y - 1970) * 365 + (y - 1969) / 4 - (y - 1901) / 100 + (y - 1601) / 400
    days += cum[m - 1]
    if (m > 2 && isLeapYear(y)) {
        days += 1
    }
    return days + d - 1
}

func isLeapYear(y: Int64): Bool {
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

/// 计算里程碑的 git 感知进度。repoPath 为空或非 git 仓库时只做日期计算。
public func milestoneProgress(m: Milestone, repoPath: String, defaultBranch: String): MilestoneProgress {
    // tag 检测：显式绑定，或默认用里程碑名本身作为 tag 名
    var tagName = m.tag
    if (tagName.isEmpty()) {
        tagName = m.name
    }
    var tagReached = false
    var commitsSince: Int64 = 0
    if (!repoPath.isEmpty()) {
        match (revParse(repoPath, "refs/tags/" + tagName)) {
            case Some(_) => tagReached = true
            case None => ()
        }
        // 自创建以来的提交数（不限分支，看整个仓库的活跃量）
        if (!m.createdAt.isEmpty() && m.createdAt.size >= 10) {
            let since = m.createdAt[..10]
            let r = gitTry(repoPath, ["rev-list", "--count", "--since=" + since + "T00:00:00", "HEAD"])
            if (r.ok() && !r.stdout.isEmpty()) {
                try {
                    commitsSince = Int64.parse(r.stdout.trimAscii())
                } catch (e: Exception) {
                    commitsSince = 0
                }
            }
        }
    }

    var days = -1  // -1 表示未设置目标日期
    var overdue = false
    if (!m.targetDate.isEmpty()) {
        let d = daysFromToday(m.targetDate)
        days = d
        overdue = d < 0 && m.status == "open"
    }

    // 生效状态：手工 done/dropped 优先；open 时 tag 达成自动视为 done
    var effective = m.status
    if (m.status == "open" && tagReached) {
        effective = "done"
    }
    return MilestoneProgress(m, tagName, tagReached, commitsSince, days, overdue, effective)
}

// ------------------------------ 测试 ------------------------------

@Test
func testMilestoneCrud(): Unit {
    // 用临时 HOME 隔离
    let base = "/tmp/deepgit-ms-${nowMillis()}"
    ensureDir(base)
    setVariable("DEEPGIT_HOME", base)
    let (m, created) = addMilestone("p_test", "v1.0", "首个版本", "2026-12-01", "v1.0.0")
    @Assert(created)
    @Assert(m.name == "v1.0")
    // 幂等
    let (_, again) = addMilestone("p_test", "v1.0", "重复", "", "")
    @Assert(!again)
    // 列出
    @Assert(milestonesFor("p_test").size == 1)
    // 标记完成
    @Assert(setMilestoneStatus("p_test", "v1.0", "done"))
    let list = milestonesFor("p_test")
    @Assert(list[0].status == "done")
    @Assert(!list[0].completedAt.isEmpty())
    // 删除
    @Assert(removeMilestone("p_test", "v1.0"))
    @Assert(milestonesFor("p_test").size == 0)
    setVariable("DEEPGIT_HOME", "")
    removePathIfExists(base)
}

@Test
func testEpochDays(): Unit {
    // 已知锚点：2026-09-30 与 2026-10-01 相差 1 天
    let a = epochDays("2026-09-30")
    let b = epochDays("2026-10-01")
    @Assert(b - a == 1)
    // 闰年：2024-02-28 → 2024-03-01 相差 2 天
    @Assert(epochDays("2024-03-01") - epochDays("2024-02-28") == 2)
    // 平年：2025-02-28 → 2025-03-01 相差 1 天
    @Assert(epochDays("2025-03-01") - epochDays("2025-02-28") == 1)
    // 与 Unix 锚点对照：1970-01-01 = 0
    @Assert(epochDays("1970-01-01") == 0)
}

@Test
func testMilestoneProgressWithGit(): Unit {
    let base = "/tmp/deepgit-msg-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], true)
    setVariable("DEEPGIT_HOME", base + "/home")
    ensureDir(base + "/home")
    let (m, _) = addMilestone("p_git", "v0.1", "", "", "v0.1")
    // 未打 tag：open、tagReached=false
    let p1 = milestoneProgress(m, base, "main")
    @Assert(p1.effectiveStatus == "open")
    @Assert(!p1.tagReached)
    // 打 tag 后自动 done
    gitRun(base, ["tag", "v0.1"], true)
    let p2 = milestoneProgress(m, base, "main")
    @Assert(p2.tagReached)
    @Assert(p2.effectiveStatus == "done")
    setVariable("DEEPGIT_HOME", "")
    removePathIfExists(base)
}

@Test
func testMilestoneOverdue(): Unit {
    let base = "/tmp/deepgit-mso-${nowMillis()}"
    ensureDir(base)
    setVariable("DEEPGIT_HOME", base)
    // 过去日期 → 逾期
    let (past, _) = addMilestone("p_od", "old", "", "2026-01-01", "")
    let pp = milestoneProgress(past, "", "main")
    @Assert(pp.overdue)
    @Assert(pp.daysToTarget < 0)
    // 未来日期 → 未逾期
    let (future, _) = addMilestone("p_od", "new", "", "2027-01-01", "")
    let fp = milestoneProgress(future, "", "main")
    @Assert(!fp.overdue)
    @Assert(fp.daysToTarget > 0)
    setVariable("DEEPGIT_HOME", "")
    removePathIfExists(base)
}

@Test
func testMilestoneProgressWithoutRepo(): Unit {
    let base = "/tmp/deepgit-msnr-${nowMillis()}"
    ensureDir(base)
    setVariable("DEEPGIT_HOME", base)
    let (m, _) = addMilestone("p_nr", "v3.0", "仅日期", "2027-01-01", "")
    // repoPath 为空：不做 tag 检测与提交统计，但日期计算仍有效
    let prog = milestoneProgress(m, "", "")
    @Assert(!prog.tagReached)
    @Assert(prog.commitsSince == 0)
    @Assert(prog.daysToTarget > 0)
    @Assert(prog.effectiveStatus == "open")
    setVariable("DEEPGIT_HOME", "")
    removePathIfExists(base)
}

@Test
func testMilestoneStatusTransitions(): Unit {
    let base = "/tmp/deepgit-mst-${nowMillis()}"
    ensureDir(base)
    setVariable("DEEPGIT_HOME", base)
    addMilestone("p_tr", "m1", "", "", "")
    @Assert(setMilestoneStatus("p_tr", "m1", "dropped"))
    @Assert(milestonesFor("p_tr")[0].status == "dropped")
    @Assert(milestonesFor("p_tr")[0].completedAt.isEmpty())
    @Assert(setMilestoneStatus("p_tr", "m1", "open"))
    @Assert(milestonesFor("p_tr")[0].status == "open")
    // 不存在的里程碑
    @Assert(!setMilestoneStatus("p_tr", "nope", "done"))
    // drop 后再 remove
    @Assert(removeMilestone("p_tr", "m1"))
    @Assert(openMilestoneCount() == 0)
    setVariable("DEEPGIT_HOME", "")
    removePathIfExists(base)
}

@Test
func testEpochDaysMonthBoundaries(): Unit {
    // 月末边界：1月31 → 2月1
    @Assert(epochDays("2026-02-01") - epochDays("2026-01-31") == 1)
    // 年末边界
    @Assert(epochDays("2027-01-01") - epochDays("2026-12-31") == 1)
    // 世纪闰年：2000 年是闰年
    @Assert(epochDays("2000-03-01") - epochDays("2000-02-28") == 2)
    // 已知锚点：2024-01-01 与 Unix 元年相差 19723 天（(19723/365.25)≈54 年 ✓）
    @Assert(epochDays("2024-01-01") == 19723)
}
