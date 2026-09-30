// 进度模型：分支状态判定、delta 计算、状态标签。
package deepgit.kernel

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

/// 分支状态：
/// - merged：已合入默认分支
/// - active：3 天内有提交
/// - idle：14 天内
/// - stale：超过 14 天
public func computeBranchStatus(lastCommitAt: String, merged: Bool): String {
    if (merged) {
        return "merged"
    }
    let d = daysSince(lastCommitAt)
    if (d == Float64.Inf) {
        return "unknown"
    }
    if (d < 3.0) {
        return "active"
    }
    if (d < 14.0) {
        return "idle"
    }
    return "stale"
}

public func statusLabel(status: String, lang: String): String {
    let zh = lang != "en"
    match (status) {
        case "active" => return if (zh) { "活跃" } else { "active" }
        case "idle" => return if (zh) { "闲置" } else { "idle" }
        case "stale" => return if (zh) { "停滞" } else { "stale" }
        case "merged" => return if (zh) { "已合并" } else { "merged" }
        case "empty" => return if (zh) { "空仓库" } else { "empty" }
        case _ => return if (zh) { "未知" } else { "unknown" }
    }
}

/// 单个分支自上次记录以来的增量
public class BranchDelta {
    public let branch: String
    public let head: String
    public let from: String  // 空串表示无追踪基线
    public let reset: Bool
    public let commits: ArrayList<CommitInfo>
    public let stats: DiffStats

    public init(branch: String, head: String, from: String, reset: Bool, commits: ArrayList<CommitInfo>, stats: DiffStats) {
        this.branch = branch
        this.head = head
        this.from = from
        this.reset = reset
        this.commits = commits
        this.stats = stats
    }

    public func count(): Int64 {
        return this.commits.size
    }
}

/// 计算分支增量。若基线与当前 head 无祖先关系（rebase/force-push），
/// 则回退到「最近提交」模式并标记 reset，保持诚实。
public func branchDelta(root: String, branch: String, tracked: String, maxCommits: Int64, maxFiles: Int64): Option<BranchDelta> {
    match (revParse(root, branch)) {
        case None => return None
        case Some(head) =>
            var from = tracked
            var reset = false
            if (!from.isEmpty()) {
                if (!isAncestor(root, from, head) || from == head) {
                    from = ""
                    reset = true
                }
            }
            var commits: ArrayList<CommitInfo>
            var stats: DiffStats
            if (from.isEmpty()) {
                let limit = if (maxCommits < 30) { maxCommits } else { 30 }
                commits = logCommits(root, limit, head, 0)
                stats = DiffStats(0, 0, 0, ArrayList<FileStat>())
            } else {
                commits = logRange(root, from, head, maxCommits)
                stats = diffStats(root, from, head, maxFiles)
            }
            return Some(BranchDelta(branch, head, from, reset, commits, stats))
    }
}

/// 项目一句话状态
public func computeHeadline(facts: RepoFacts, progress: JsonValue, lang: String): String {
    let zh = lang != "en"
    let parts = ArrayList<String>()
    if (facts.kind != "git") {
        match (facts.activity) {
            case Some(a) =>
                if (!a.newestMtime.isEmpty()) {
                    let d = Int64(daysSince(a.newestMtime))
                    if (d <= 0) {
                        parts.add(if (zh) { "今日有文件改动" } else { "changed today" })
                    } else {
                        parts.add(if (zh) { "${d} 天内有改动" } else { "changed ${d}d ago" })
                    }
                }
                parts.add(if (zh) { "非 git 项目 · ${a.fileCount} 个文件" } else { "non-git · ${a.fileCount} files" })
            case None => ()
        }
        return joinStrings(parts, " · ")
    }

    // 待记录提交数
    var pending: Int64 = 0
    for ((_, rec) in progressBranches(progress)) {
        pending += Json.intAt(rec, "pendingCommits", 0)
    }
    if (pending > 0) {
        parts.add(if (zh) { "${pending} 个待记录提交" } else { "${pending} pending commits" })
    }
    match (progressBranch(progress, facts.currentBranch)) {
        case Some(rec) =>
            let st = Json.strAt(rec, "status", "")
            if (!st.isEmpty()) {
                parts.add("${facts.currentBranch}: ${statusLabel(st, lang)}")
            }
        case None => ()
    }
    let dirtyCount = userDirtyCount(facts)
    if (dirtyCount > 0) {
        parts.add(if (zh) { "${dirtyCount} 处未提交" } else { "${dirtyCount} uncommitted" })
    }
    if (parts.size == 0) {
        parts.add(if (zh) { "暂无新变化" } else { "no changes" })
    }
    return joinStrings(parts, " · ")
}

// ------------------------------ 测试 ------------------------------

@Test
func testComputeBranchStatus(): Unit {
    @Assert(computeBranchStatus(nowIso(), false) == "active")
    @Assert(computeBranchStatus(nowIso(), true) == "merged")
    @Assert(computeBranchStatus("2020-01-01T00:00:00+08:00", false) == "stale")
    @Assert(computeBranchStatus("bad", false) == "unknown")
}

@Test
func testStatusLabel(): Unit {
    @Assert(statusLabel("active", "zh") == "活跃")
    @Assert(statusLabel("stale", "en") == "stale")
    @Assert(statusLabel("merged", "zh") == "已合并")
}

@Test
func testBranchDeltaOnRealRepo(): Unit {
    let base = "/tmp/deepgit-delta-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "first commit"], true)

    // 首次记录（无基线）：不是 reset，取最近提交
    let d0 = branchDelta(base, "main", "", 50, 50)
    @Assert(d0.isSome())
    @Assert(!d0.getOrThrow().reset)
    @Assert(d0.getOrThrow().from.isEmpty())
    @Assert(d0.getOrThrow().count() == 1)

    // 有基线：增量模式
    let head0 = d0.getOrThrow().head
    writeFileAtomic(base + "/a.txt", "2")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "second commit"], true)
    let d1 = branchDelta(base, "main", head0, 50, 50)
    @Assert(d1.isSome())
    @Assert(!d1.getOrThrow().reset)
    @Assert(d1.getOrThrow().count() == 1)
    @Assert(d1.getOrThrow().stats.files == 1)

    // 基线失效（模拟 force-push / rebase）：应标记 reset 并回退
    let staleBase = d1.getOrThrow().head
    gitRun(base, ["reset", "--hard", "HEAD~1"], true)
    writeFileAtomic(base + "/a.txt", "3")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "rewritten commit"], true)
    let d2 = branchDelta(base, "main", staleBase, 50, 50)
    @Assert(d2.isSome())
    @Assert(d2.getOrThrow().reset)
    @Assert(d2.getOrThrow().from.isEmpty())

    // 不存在的分支
    @Assert(branchDelta(base, "no-such-branch", "", 50, 50).isNone())
    removePathIfExists(base)
}

@Test
func testComputeHeadlineNonGit(): Unit {
    let tmp = "/tmp/deepgit-hl-${nowMillis()}"
    ensureDir(tmp)
    writeFileAtomic(tmp + "/x.txt", "x")
    let facts = collectFacts(tmp, "dir", Config.defaults(), 10, false)
    let headline = computeHeadline(facts, Json.obj(), "zh")
    @Assert(headline.contains("非 git"))
    removePathIfExists(tmp)
}

@Test
func testComputeHeadlineGitNoBranchesTracked(): Unit {
    let base = "/tmp/deepgit-hl2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    let facts = collectFacts(base, "git", Config.defaults(), 10, false)
    let headline = computeHeadline(facts, Json.obj(), "zh")
    @Assert(headline.size > 0)
    removePathIfExists(base)
}
