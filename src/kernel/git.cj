// git 封装：所有 git 访问都经此处，返回结构化数据。
package deepgit.kernel

import std.collection.*
import std.fs.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

/// 记录分隔符（与 util/exec 的 git 调用配合）
let UNIT = "\u{1f}"
let REC = "\u{1e}"

public class BranchInfo {
    public let name: String
    public let head: String
    public let date: String
    public let subject: String
    public let upstream: String
    public let ahead: Int64
    public let behind: Int64
    public let upstreamGone: Bool

    public init(name: String, head: String, date: String, subject: String, upstream: String, ahead: Int64, behind: Int64, upstreamGone: Bool) {
        this.name = name
        this.head = head
        this.date = date
        this.subject = subject
        this.upstream = upstream
        this.ahead = ahead
        this.behind = behind
        this.upstreamGone = upstreamGone
    }
}

public class CommitInfo {
    public let sha: String
    public let short: String
    public let author: String
    public let email: String
    public let date: String
    public let subject: String
    public let body: String

    public init(sha: String, short: String, author: String, email: String, date: String, subject: String, body: String) {
        this.sha = sha
        this.short = short
        this.author = author
        this.email = email
        this.date = date
        this.subject = subject
        this.body = body
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "sha", Json.of(this.sha))
        Json.set(o, "short", Json.of(this.short))
        Json.set(o, "author", Json.of(this.author))
        Json.set(o, "date", Json.of(this.date))
        Json.set(o, "subject", Json.of(this.subject))
        if (!this.body.isEmpty()) {
            Json.set(o, "body", Json.of(this.body))
        }
        return o
    }
}

public class FileStat {
    public let path: String
    public let status: String
    public let additions: Int64
    public let deletions: Int64

    public init(path: String, status: String, additions: Int64, deletions: Int64) {
        this.path = path
        this.status = status
        this.additions = additions
        this.deletions = deletions
    }
}

public class DiffStats {
    public let files: Int64
    public let insertions: Int64
    public let deletions: Int64
    public let fileList: ArrayList<FileStat>

    public init(files: Int64, insertions: Int64, deletions: Int64, fileList: ArrayList<FileStat>) {
        this.files = files
        this.insertions = insertions
        this.deletions = deletions
        this.fileList = fileList
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "files", Json.of(this.files))
        Json.set(o, "insertions", Json.of(this.insertions))
        Json.set(o, "deletions", Json.of(this.deletions))
        return o
    }
}

public class DirtyState {
    public let clean: Bool
    public let staged: Int64
    public let modified: Int64
    public let untracked: Int64
    public let conflicts: Int64
    public let total: Int64
    public let files: ArrayList<String>

    public init(clean: Bool, staged: Int64, modified: Int64, untracked: Int64, conflicts: Int64, total: Int64, files: ArrayList<String>) {
        this.clean = clean
        this.staged = staged
        this.modified = modified
        this.untracked = untracked
        this.conflicts = conflicts
        this.total = total
        this.files = files
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "clean", Json.of(this.clean))
        Json.set(o, "staged", Json.of(this.staged))
        Json.set(o, "modified", Json.of(this.modified))
        Json.set(o, "untracked", Json.of(this.untracked))
        Json.set(o, "conflicts", Json.of(this.conflicts))
        Json.set(o, "total", Json.of(this.total))
        let arr = ArrayList<JsonValue>()
        var i: Int64 = 0
        for (f in this.files) {
            if (i >= 30) {
                break
            }
            arr.add(Json.of(f))
            i += 1
        }
        Json.set(o, "files", JArr(arr))
        return o
    }
}

// ------------------------------ 基础查询 ------------------------------

public func isGitRepo(dir: String): Bool {
    let r = gitTry(dir, ["rev-parse", "--git-dir"])
    return r.ok()
}

public func repoRoot(dir: String): Option<String> {
    let r = gitTry(dir, ["rev-parse", "--show-toplevel"])
    if (r.ok() && !r.stdout.isBlank()) {
        return Some(r.stdout.trimAscii())
    }
    return None
}

public func revParse(dir: String, ref: String): Option<String> {
    let r = gitTry(dir, ["rev-parse", "--verify", "${ref}^{commit}"])
    if (r.ok()) {
        return Some(r.stdout.trimAscii())
    }
    return None
}

public func currentBranch(dir: String): String {
    let r = gitTry(dir, ["symbolic-ref", "--short", "-q", "HEAD"])
    if (r.ok() && !r.stdout.isBlank()) {
        return r.stdout.trimAscii()
    }
    return "HEAD"
}

public func defaultBranch(dir: String): String {
    let remoteHead = gitTry(dir, ["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"])
    if (remoteHead.ok() && !remoteHead.stdout.isBlank()) {
        let name = remoteHead.stdout.trimAscii()
        if (name.startsWith("origin/")) {
            return name[7..]
        }
        return name
    }
    let branches = ArrayList<String>()
    let r = gitTry(dir, ["branch", "--format=%(refname:short)"])
    if (r.ok()) {
        for (line in r.stdout.split("\n")) {
            let t = line.trimAscii()
            if (!t.isEmpty()) {
                branches.add(t)
            }
        }
    }
    for (cand in ["main", "master", "develop", "dev"]) {
        for (b in branches) {
            if (b == cand) {
                return cand
            }
        }
    }
    if (!branches.isEmpty()) {
        return branches[0]
    }
    // 空仓库：用 HEAD 指向的分支名（init 后即存在），否则如实回报空
    let sym = gitTry(dir, ["symbolic-ref", "--short", "-q", "HEAD"])
    if (sym.ok() && !sym.stdout.isBlank()) {
        return sym.stdout.trimAscii()
    }
    return ""
}

/// 分支列表（for-each-ref 用 %1f 作字段分隔）
public func listBranches(dir: String): ArrayList<BranchInfo> {
    let out = ArrayList<BranchInfo>()
    // 注意：for-each-ref 的 %1f 会被展开为 0x1f（实测 %x1f 在此版本不展开）
    let fmt = "%(refname:short)%1f%(objectname)%1f%(committerdate:iso-strict)%1f%(contents:subject)%1f%(upstream:short)%1f%(upstream:track)"
    let r = gitTry(dir, ["for-each-ref", "--format=${fmt}", "refs/heads"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    for (line in r.stdout.split("\n")) {
        if (line.isEmpty()) {
            continue
        }
        let parts = line.split(UNIT)
        if (parts.size < 6 || parts[0].isEmpty()) {
            continue
        }
        let name = parts[0]
        let head = parts[1]
        let date = parts[2]
        let subject = parts[3]
        let upstream = parts[4]
        let track = parts[5]
        var ahead: Int64 = 0
        var behind: Int64 = 0
        var gone = false
        if (!track.isEmpty()) {
            ahead = extractCount(track, "ahead ")
            behind = extractCount(track, "behind ")
            gone = track.contains("gone")
        }
        out.add(BranchInfo(name, head, date, subject, upstream, ahead, behind, gone))
    }
    return out
}

func extractCount(s: String, prefix: String): Int64 {
    let idx = s.indexOf(prefix)
    match (idx) {
        case Some(i) =>
            let rest = s[i + prefix.size..]
            let sb = StringBuilder()
            for (r in rest.runes()) {
                let c = r.toString()
                if (c >= "0" && c <= "9") {
                    sb.append(c)
                } else {
                    break
                }
            }
            let numStr = sb.toString()
            if (numStr.isEmpty()) {
                return 0
            }
            try {
                return Int64.parse(numStr)
            } catch (e: Exception) {
                return 0
            }
        case None => return 0
    }
}

public func statusSummary(dir: String): DirtyState {
    let r = gitTry(dir, ["status", "--porcelain"])
    if (!r.ok()) {
        return DirtyState(true, 0, 0, 0, 0, 0, ArrayList<String>())
    }
    var staged: Int64 = 0
    var modified: Int64 = 0
    var untracked: Int64 = 0
    var conflicts: Int64 = 0
    var total: Int64 = 0
    let files = ArrayList<String>()
    for (line in r.stdout.split("\n")) {
        if (line.isEmpty()) {
            continue
        }
        total += 1
        let xy = if (line.size >= 2) { line[..2] } else { line }
        let file = if (line.size > 3) { line[3..].trimAscii() } else { "" }
        if (!file.isEmpty()) {
            files.add(file)
        }
        if (xy == "??") {
            untracked += 1
        } else if (xy == "DD" || xy == "AU" || xy == "UD" || xy == "UA" || xy == "DU" || xy == "AA" || xy == "UU") {
            conflicts += 1
        } else {
            if (xy.size >= 1 && xy[0..1] != " " && xy[0..1] != "?") {
                staged += 1
            }
            if (xy.size >= 2 && xy[1..2] != " " && xy[1..2] != "?") {
                modified += 1
            }
        }
    }
    return DirtyState(total == 0, staged, modified, untracked, conflicts, total, files)
}

/// 提交日志（用 %x1f 分隔字段，字段用 REC 结尾）
public func logCommits(dir: String, limit: Int64, ref: String, skip: Int64): ArrayList<CommitInfo> {
    let out = ArrayList<CommitInfo>()
    let fmt = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%s%x1f%b%x1e"
    let args = ArrayList<String>()
    args.add("log")
    args.add("--format=${fmt}")
    args.add("-n")
    args.add("${limit}")
    if (skip > 0) {
        args.add("--skip=${skip}")
    }
    args.add(ref)
    let r = gitTry(dir, args.toArray())
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    for (chunk in r.stdout.split(REC)) {
        let t = chunk.trimAscii()
        if (t.isEmpty()) {
            continue
        }
        let parts = t.split(UNIT)
        if (parts.size < 6) {
            continue
        }
        let sha = parts[0]
        let short = parts[1]
        let author = parts[2]
        let email = parts[3]
        let date = parts[4]
        let subject = parts[5]
        var body = ""
        if (parts.size > 6) {
            let sb = StringBuilder()
            for (i in 6..parts.size) {
                if (i > 6) {
                    sb.append(UNIT)
                }
                sb.append(parts[i])
            }
            body = safeSlice(sb.toString().trimAscii(), 800)
        }
        if (!sha.isEmpty()) {
            out.add(CommitInfo(sha, short, author, email, date, subject.trimAscii(), body))
        }
    }
    return out
}

/// from..to 的提交（from 不含，to 含）
public func logRange(dir: String, from: String, to: String, limit: Int64): ArrayList<CommitInfo> {
    if (from.isEmpty()) {
        return logCommits(dir, limit, to, 0)
    }
    return logCommits(dir, limit, "${from}..${to}", 0)
}

public func commitCount(dir: String, range: String): Int64 {
    let r = gitTry(dir, ["rev-list", "--count", range])
    if (!r.ok()) {
        return 0
    }
    try {
        return Int64.parse(r.stdout.trimAscii())
    } catch (e: Exception) {
        return 0
    }
}

/// maybeAncestor 是否为 descendant 的祖先
public func isAncestor(dir: String, maybeAncestor: String, descendant: String): Bool {
    let r = gitTry(dir, ["merge-base", "--is-ancestor", maybeAncestor, descendant])
    return r.ok()
}

/// base...branch 的 (behind, ahead)
public func aheadBehind(dir: String, base: String, branch: String): (Int64, Int64) {
    let r = gitTry(dir, ["rev-list", "--left-right", "--count", "${base}...${branch}"])
    if (!r.ok()) {
        return (0, 0)
    }
    let parts = r.stdout.trimAscii().split("\t")
    if (parts.size < 2) {
        let sp = r.stdout.trimAscii().split(" ")
        if (sp.size >= 2) {
            return (parseIntOr(sp[0], 0), parseIntOr(sp[1], 0))
        }
        return (0, 0)
    }
    return (parseIntOr(parts[0], 0), parseIntOr(parts[1], 0))
}

func parseIntOr(s: String, fallback: Int64): Int64 {
    try {
        return Int64.parse(s.trimAscii())
    } catch (e: Exception) {
        return fallback
    }
}

/// diff 统计（-M 归一化改名）
public func diffStats(dir: String, from: String, to: String, maxFiles: Int64): DiffStats {
    if (from.isEmpty() || to.isEmpty() || from == to) {
        return DiffStats(0, 0, 0, ArrayList<FileStat>())
    }
    let numstat = gitTry(dir, ["diff", "--numstat", from, to])
    if (!numstat.ok()) {
        return DiffStats(0, 0, 0, ArrayList<FileStat>())
    }
    let nameStatus = gitTry(dir, ["diff", "--name-status", from, to])
    let statusMap = HashMap<String, String>()
    if (nameStatus.ok()) {
        for (line in nameStatus.stdout.split("\n")) {
            if (line.isEmpty()) {
                continue
            }
            let parts = line.split("\t")
            if (parts.size >= 2) {
                statusMap[parts[parts.size - 1]] = parts[0][..1]
            }
        }
    }
    var files: Int64 = 0
    var insertions: Int64 = 0
    var deletions: Int64 = 0
    let list = ArrayList<FileStat>()
    for (line in numstat.stdout.split("\n")) {
        if (line.isEmpty()) {
            continue
        }
        let parts = line.split("\t")
        if (parts.size < 3) {
            continue
        }
        let addStr = parts[0]
        let delStr = parts[1]
        let sb = StringBuilder()
        for (i in 2..parts.size) {
            if (i > 2) {
                sb.append("\t")
            }
            sb.append(parts[i])
        }
        let filePath = sb.toString()
        let adds = if (addStr == "-") { 0 } else { parseIntOr(addStr, 0) }
        let dels = if (delStr == "-") { 0 } else { parseIntOr(delStr, 0) }
        files += 1
        insertions += adds
        deletions += dels
        if (list.size < maxFiles) {
            let st = match (statusMap.get(filePath)) {
                case Some(v) => v
                case None => "M"
            }
            list.add(FileStat(filePath, st, adds, dels))
        }
    }
    return DiffStats(files, insertions, deletions, list)
}

public func lsFiles(dir: String, maxFiles: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    let r = gitTry(dir, ["ls-files", "-z"])
    if (!r.ok()) {
        return out
    }
    var i: Int64 = 0
    for (f in r.stdout.split("\u{0}")) {
        if (f.isEmpty()) {
            continue
        }
        if (i >= maxFiles) {
            break
        }
        out.add(f)
        i += 1
    }
    return out
}

public func tags(dir: String, limit: Int64): ArrayList<(String, String)> {
    let out = ArrayList<(String, String)>()
    let r = gitTry(dir, ["for-each-ref", "--sort=-creatordate", "--count=${limit}", "--format=%(refname:short)%1f%(creatordate:iso-strict)", "refs/tags"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    for (line in r.stdout.split("\n")) {
        if (line.isEmpty()) {
            continue
        }
        let parts = line.split(UNIT)
        if (parts.size >= 2 && !parts[0].isEmpty()) {
            out.add((parts[0], parts[1]))
        }
    }
    return out
}

public func firstCommitDate(dir: String): Option<String> {
    let r = gitTry(dir, ["log", "--max-parents=0", "--format=%aI", "HEAD"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return None
    }
    let dates = ArrayList<String>()
    for (line in r.stdout.split("\n")) {
        let t = line.trimAscii()
        if (!t.isEmpty()) {
            dates.add(t)
        }
    }
    if (dates.isEmpty()) {
        return None
    }
    dates.sort()
    return Some(dates[0])
}

/// 真正的项目起点提交（root commit，无父提交）
public func genesisCommits(dir: String, limit: Int64): ArrayList<CommitInfo> {
    let out = ArrayList<CommitInfo>()
    let r = gitTry(dir, ["log", "--max-parents=0", "--format=%H", "HEAD"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    let shas = ArrayList<String>()
    for (line in r.stdout.split("\n")) {
        let t = line.trimAscii()
        if (!t.isEmpty() && shas.size < limit) {
            shas.add(t)
        }
    }
    for (sha in shas) {
        match (lastCommit(dir, sha)) {
            case Some(c) => out.add(c)
            case None => ()
        }
    }
    return out
}

public func lastCommit(dir: String, ref: String): Option<CommitInfo> {
    let list = logCommits(dir, 1, ref, 0)
    if (list.isEmpty()) {
        return None
    }
    return Some(list[0])
}

public func authorStats(dir: String, limit: Int64): ArrayList<(Int64, String)> {
    let out = ArrayList<(Int64, String)>()
    let r = gitTry(dir, ["shortlog", "-sn", "--no-merges", "HEAD"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    for (line in r.stdout.split("\n")) {
        let t = line.trimAscii()
        if (t.isEmpty()) {
            continue
        }
        let tabIdx = t.indexOf("\t")
        match (tabIdx) {
            case Some(i) =>
                let countStr = t[..i].trimAscii()
                let name = t[i + 1..].trimAscii()
                let count = parseIntOr(countStr, 0)
                out.add((count, name))
                if (out.size >= limit) {
                    break
                }
            case None => ()
        }
    }
    return out
}

public func stashCount(dir: String): Int64 {
    let r = gitTry(dir, ["stash", "list"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return 0
    }
    var n: Int64 = 0
    for (line in r.stdout.split("\n")) {
        if (!line.isBlank()) {
            n += 1
        }
    }
    return n
}

public func remoteUrl(dir: String): String {
    let r = gitTry(dir, ["config", "--get", "remote.origin.url"])
    if (r.ok()) {
        return r.stdout.trimAscii()
    }
    return ""
}

/// 月度提交活跃度（最近 limit 个提交聚合）
public func commitActivity(dir: String, limit: Int64): ArrayList<(String, Int64)> {
    let r = gitTry(dir, ["log", "-n", "${limit}", "--format=%aI"])
    let out = ArrayList<(String, Int64)>()
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    let months = ArrayList<String>()
    let counts = ArrayList<Int64>()
    for (line in r.stdout.split("\n")) {
        let t = line.trimAscii()
        if (t.size < 7) {
            continue
        }
        let month = t[..7]
        var found = false
        for (i in 0..months.size) {
            if (months[i] == month) {
                counts[i] = counts[i] + 1
                found = true
                break
            }
        }
        if (!found) {
            months.add(month)
            counts.add(1)
        }
    }
    // 按月排序
    let idx = ArrayList<Int64>()
    for (i in 0..months.size) {
        idx.add(i)
    }
    // 简单插入排序（数据量小）
    for (i in 1..idx.size) {
        let key = idx[i]
        var j = i - 1
        while (j >= 0 && months[idx[j]] > months[key]) {
            idx[j + 1] = idx[j]
            j -= 1
        }
        idx[j + 1] = key
    }
    for (i in idx) {
        out.add((months[i], counts[i]))
    }
    return out
}

// ------------------------------ 提交类型统计（Conventional Commits） ------------------------------

let COMMIT_TYPE_ORDER: Array<String> = ["feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "style", "chore", "revert", "other"]

/// 从提交 subject 提取类型：feat(x): … → feat；无前缀 → other
public func commitTypeOf(subject: String): String {
    let s = subject.trimAscii().toAsciiLower()
    var head = s
    // 去掉可选的 scope：feat(api): → feat:
    let paren = s.indexOf("(")
    if (paren.isSome()) {
        let p = paren.getOrThrow()
        // scope 必须紧跟在 type 后面且 type 本身无空格
        if (p > 0 && !s[..p].contains(" ") && !s[..p].contains(":")) {
            let close = s.indexOf(")")
            if (close.isSome() && close.getOrThrow() > p) {
                head = s[..p] + s[close.getOrThrow() + 1..]
            }
        }
    }
    let colon = head.indexOf(":")
    if (colon.isSome()) {
        head = head[..colon.getOrThrow()].trimAscii()
    }
    for (t in COMMIT_TYPE_ORDER) {
        if (t == "other") {
            continue
        }
        if (head == t) {
            return t
        }
        // 常见别名归并
        if (t == "feat" && (head == "feature" || head == "add")) {
            return "feat"
        }
        if (t == "fix" && (head == "bugfix" || head == "hotfix" || head == "bug")) {
            return "fix"
        }
        if (t == "perf" && head == "performance") {
            return "perf"
        }
        if (t == "test" && (head == "tests" || head == "tst")) {
            return "test"
        }
    }
    return "other"
}

/// 统计 ref 最近 maxCommits 条提交的类型分布（按固定类别顺序输出，零值类别省略）
public func commitTypeStats(root: String, ref: String, maxCommits: Int64): ArrayList<(String, Int64)> {
    let out = ArrayList<(String, Int64)>()
    let r = gitTry(root, ["log", "--pretty=format:%s", "-n", "${maxCommits}", ref])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    let counts = ArrayList<(String, Int64)>()
    for (line in r.stdout.split("\n")) {
        if (line.isBlank()) {
            continue
        }
        let t = commitTypeOf(line)
        var found = false
        for (i in 0..counts.size) {
            if (counts[i][0] == t) {
                counts[i] = (t, counts[i][1] + 1)
                found = true
                break
            }
        }
        if (!found) {
            counts.add((t, 1))
        }
    }
    for (t in COMMIT_TYPE_ORDER) {
        for (c in counts) {
            if (c[0] == t) {
                out.add((t, c[1]))
            }
        }
    }
    return out
}

// ------------------------------ 测试 ------------------------------

@Test
func testExtractCount(): Unit {
    @Assert(extractCount("[ahead 3]", "ahead ") == 3)
    @Assert(extractCount("[behind 12, ahead 5]", "behind ") == 12)
    @Assert(extractCount("[gone]", "ahead ") == 0)
}

@Test
func testDefaultBranchOnEmptyRepo(): Unit {
    let base = "/tmp/deepgit-defbr-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    // 空仓库（无提交）应返回 HEAD 指向的分支名，而不是字面 "HEAD"
    @Assert(defaultBranch(base) == "main")
    removePathIfExists(base)
}

@Test
func testGenesisCommitsFindsRoot(): Unit {
    let base = "/tmp/deepgit-genesis-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "the very first"], true)
    writeFileAtomic(base + "/a.txt", "2")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "second"], true)
    let g = genesisCommits(base, 5)
    @Assert(g.size == 1)
    @Assert(g[0].subject == "the very first")
    removePathIfExists(base)
}

@Test
func testNonGitDirReturnsEmpty(): Unit {
    let tmp = "/tmp/deepgit-git-${nowMillis()}"
    ensureDir(tmp)
    @Assert(!isGitRepo(tmp))
    @Assert(listBranches(tmp).isEmpty())
    @Assert(statusSummary(tmp).clean)
    removePathIfExists(tmp)
}

@Test
func testSelfRepoIfAvailable(): Unit {
    // 在 deepGit 仓库自身运行时验证真实 git 读取
    let here = "/Volumes/data/dev/coding/deepcodeUI/deepGit"
    if (isGitRepo(here)) {
        let branch = currentBranch(here)
        @Assert(!branch.isEmpty())
        let s = statusSummary(here)
        @Assert(s.total >= 0)
    }
}

@Test
func testDirtyStateJson(): Unit {
    let d = DirtyState(false, 1, 2, 3, 0, 6, ArrayList<String>(["a", "b"]))
    let j = d.toJson()
    @Assert(Json.boolAt(j, "clean", true) == false)
    @Assert(Json.intAt(j, "untracked", 0) == 3)
    @Assert(Json.arrAt(j, "files").size == 2)
}

@Test
func testDiffStatsJson(): Unit {
    let ds = DiffStats(3, 10, 5, ArrayList<FileStat>())
    let j = ds.toJson()
    @Assert(Json.intAt(j, "files", 0) == 3)
    @Assert(Json.intAt(j, "insertions", 0) == 10)
}

// =============================== Worktree 增强 ===============================

public class WorktreeInfo {
    public let path: String
    public let headShort: String
    public let branch: String
    public let isBare: Bool
    public let isCurrent: Bool

    public init(path: String, headShort: String, branch: String, isBare: Bool, isCurrent: Bool) {
        this.path = path
        this.headShort = headShort
        this.branch = branch
        this.isBare = isBare
        this.isCurrent = isCurrent
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "path", Json.of(this.path))
        Json.set(o, "headShort", Json.of(this.headShort))
        Json.set(o, "branch", Json.of(this.branch))
        Json.set(o, "isBare", Json.of(this.isBare))
        Json.set(o, "isCurrent", Json.of(this.isCurrent))
        return o
    }
}

/// 列出所有 worktree（含主工作区）
public func listWorktrees(root: String): ArrayList<WorktreeInfo> {
    let out = ArrayList<WorktreeInfo>()
    let r = gitTry(root, ["worktree", "list", "--porcelain"])
    if (!r.ok() || r.stdout.isEmpty()) {
        // 兜底：至少包含主工作区
        match (revParse(root, "HEAD")) {
            case Some(h) =>
                let b = currentBranch(root)
                out.add(WorktreeInfo(root, shortSha(h), if (b == "HEAD") { "(detached)" } else { b }, false, true))
            case None => ()
        }
        return out
    }
    // porcelain 格式：worktree <path> / HEAD <sha> / branch refs/heads/<b> | bare | detached
    // 每条记录以 "worktree " 开头，先收集再统一映射，避免闭包捕获 var
    let recs = ArrayList<(String, String, String, Bool, Bool)>()
    var curPath = ""
    var curHead = ""
    var curBranch = ""
    var curBare = false
    var curDetached = false
    var have = false
    for (line in r.stdout.split("\n")) {
        if (line.startsWith("worktree ")) {
            if (have) {
                recs.add((curPath, curHead, curBranch, curBare, curDetached))
            }
            have = true
            curPath = line[9..]
            curHead = ""
            curBranch = ""
            curBare = false
            curDetached = false
        } else if (line.isEmpty()) {
            continue
        } else if (line.startsWith("HEAD ")) {
            curHead = line[5..]
        } else if (line.startsWith("branch ")) {
            curBranch = line[7..]
        } else if (line == "bare") {
            curBare = true
        } else if (line == "detached") {
            curDetached = true
        }
    }
    if (have) {
        recs.add((curPath, curHead, curBranch, curBare, curDetached))
    }
    for (rec in recs) {
        var branch = rec[2]
        if (branch.startsWith("refs/heads/")) {
            branch = branch[11..]
        }
        if (rec[4] && branch.isEmpty()) {
            branch = "(detached)"
        }
        if (rec[3] && branch.isEmpty()) {
            branch = "(bare)"
        }
        out.add(WorktreeInfo(rec[0], shortSha(rec[1]), branch, rec[3], sameDir(rec[0], root)))
    }
    return out
}

/// 目录等价判断：macOS 上 /tmp 是 /private/tmp 的符号链接，git 输出真实路径
func sameDir(a: String, b: String): Bool {
    return samePath(a, b)
}

/// 合并建议：当前分支相对默认分支的 ahead/behind + 是否可以 fast-forward
public class MergePlan {
    public let kind: String  // "fast-forward" | "merge" | "rebase" | "no-default" | "merged"
    public let ahead: Int64
    public let behind: Int64
    public let defaultBranch: String
    public let target: String
    public let description: String

    public init(kind: String, ahead: Int64, behind: Int64, defaultBranch: String, target: String, description: String) {
        this.kind = kind
        this.ahead = ahead
        this.behind = behind
        this.defaultBranch = defaultBranch
        this.target = target
        this.description = description
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "kind", Json.of(this.kind))
        Json.set(o, "ahead", Json.of(this.ahead))
        Json.set(o, "behind", Json.of(this.behind))
        Json.set(o, "defaultBranch", Json.of(this.defaultBranch))
        Json.set(o, "target", Json.of(this.target))
        Json.set(o, "description", Json.of(this.description))
        return o
    }
}

/// 计算合并策略：ahead/behind 是否 fast-forward、是否已合并
public func planMerge(root: String, branch: String): MergePlan {
    let defBranch = defaultBranch(root)
    if (defBranch == branch) {
        return MergePlan("no-default", 0, 0, defBranch, branch, "当前分支即默认分支")
    }
    let ab = aheadBehind(root, defBranch, branch)  // (behind, ahead)
    let behind = ab[0]
    let ahead = ab[1]
    // ahead = branch 领先默认分支的提交数（独有提交）；behind = 落后数
    if (ahead == 0) {
        // 分支无独有提交 = 已完全包含于默认分支
        return MergePlan("merged", 0, behind, defBranch, branch, "${branch} 已合入 ${defBranch}")
    }
    if (behind == 0) {
        // 默认分支无新提交，可直接快进到 branch
        return MergePlan("fast-forward", ahead, 0, defBranch, branch, "${defBranch} 可直接 fast-forward 到 ${branch}（${ahead} 个新提交）")
    }
    return MergePlan("merge", ahead, behind, defBranch, branch, "需三方合并（领先 ${ahead} / 落后 ${behind}）")
}

/// 列出 stash（含简短预览）
public class StashInfo {
    public let index: String
    public let branch: String
    public let message: String
    public let date: String

    public init(index: String, branch: String, message: String, date: String) {
        this.index = index
        this.branch = branch
        this.message = message
        this.date = date
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "index", Json.of(this.index))
        Json.set(o, "branch", Json.of(this.branch))
        Json.set(o, "message", Json.of(this.message))
        Json.set(o, "date", Json.of(this.date))
        return o
    }
}

public func listStashes(root: String): ArrayList<StashInfo> {
    let out = ArrayList<StashInfo>()
    let r = gitTry(root, ["stash", "list", "--pretty=format:%gd%x1f%s%x1f%as"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    for (line in r.stdout.split("\n")) {
        if (line.isEmpty()) {
            continue
        }
        let parts = line.split("\u{1f}")
        let idx = if (parts.size >= 1) { parts[0] } else { "" }
        let subject = if (parts.size >= 2) { parts[1] } else { "" }
        let date = if (parts.size >= 3) { parts[2] } else { "" }
        // subject 形如 "On main: xxx" / "WIP on main: sha xxx"，从中拆出分支
        var branchName = ""
        var msg = subject
        if (subject.startsWith("On ")) {
            let rest = subject[3..]
            let colon = rest.indexOf(": ")
            if (colon.isSome()) {
                let c = colon.getOrThrow()
                branchName = rest[..c]
                msg = rest[c + 2..]
            }
        } else if (subject.startsWith("WIP on ")) {
            let rest = subject[7..]
            let colon = rest.indexOf(": ")
            if (colon.isSome()) {
                let c = colon.getOrThrow()
                branchName = rest[..c]
                msg = rest[c + 2..]
            }
        }
        out.add(StashInfo(idx, branchName, msg, date))
    }
    return out
}

/// 非跟踪文件独立列表（含 mtime / 大小，便于浅更新增量跟踪）
public class UntrackedFile {
    public let path: String
    public let sizeBytes: Int64
    public let mtime: String

    public init(path: String, sizeBytes: Int64, mtime: String) {
        this.path = path
        this.sizeBytes = sizeBytes
        this.mtime = mtime
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "path", Json.of(this.path))
        Json.set(o, "size", Json.of(this.sizeBytes))
        Json.set(o, "mtime", Json.of(this.mtime))
        return o
    }
}

public func untrackedFiles(root: String, maxFiles: Int64): ArrayList<UntrackedFile> {
    let out = ArrayList<UntrackedFile>()
    let r = gitTry(root, ["ls-files", "--others", "--exclude-standard", "-z"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    for (path in r.stdout.split("\u{0}")) {
        if (path.isEmpty()) {
            continue
        }
        if (out.size >= maxFiles) {
            break
        }
        let absPath = "${root}/${path}"
        let info = FileInfo(Path(absPath))
        out.add(UntrackedFile(path, info.size, info.lastModificationTime.toString()))
    }
    return out
}

/// 文件热力（按文件聚合计修改次数）：用于发现真正活跃的工作面
public func fileHeatmap(dir: String, ref: String, maxCommits: Int64, top: Int64): ArrayList<(String, Int64)> {
    let names = ArrayList<String>()
    let counts = ArrayList<Int64>()
    let r = gitTry(dir, ["log", "--name-only", "--format=", "-n", "${maxCommits}", ref])
    if (!r.ok() || r.stdout.isEmpty()) {
        return ArrayList<(String, Int64)>()
    }
    for (path in r.stdout.split("\n")) {
        let p = path.trimAscii()
        if (p.isEmpty()) {
            continue
        }
        var found = false
        for (i in 0..names.size) {
            if (names[i] == p) {
                counts[i] = counts[i] + 1
                found = true
                break
            }
        }
        if (!found) {
            names.add(p)
            counts.add(1)
        }
    }
    // 简单排序
    let out = ArrayList<(String, Int64)>()
    for (i in 0..names.size) {
        out.add((names[i], counts[i]))
    }
    // 计数降序
    var a: Int64 = 1
    while (a < out.size) {
        let key = out[a]
        var b = a - 1
        while (b >= 0 && out[b][1] < key[1]) {
            out[b + 1] = out[b]
            b -= 1
        }
        out[b + 1] = key
        a += 1
    }
    if (out.size > top) {
        let trimmed = ArrayList<(String, Int64)>()
        for (i in 0..top) {
            trimmed.add(out[i])
        }
        return trimmed
    }
    return out
}

// ---------------- 测试 ----------------

@Test
func testListWorktreesOnMainRepo(): Unit {
    let base = "/tmp/deepgit-wt-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/x.txt", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "first"], true)
    let wts = listWorktrees(base)
    @Assert(wts.size >= 1)
    @Assert(wts[0].isCurrent)
    removePathIfExists(base)
}

@Test
func testListWorktreesWithWorktree(): Unit {
    let base = "/tmp/deepgit-wt2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/x.txt", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], true)
    let wtPath = "/tmp/deepgit-wt2-wt-${nowMillis()}"
    let r = gitTry(base, ["worktree", "add", "-b", "feat/exp", wtPath])
    @Assert(r.ok())
    let wts = listWorktrees(base)
    var seenExp = false
    var seenMain = false
    for (w in wts) {
        if (w.branch == "feat/exp") {
            seenExp = true
        }
        if (w.branch == "main") {
            seenMain = true
        }
    }
    @Assert(seenExp && seenMain)
    // 清理
    gitRun(base, ["worktree", "remove", wtPath], true)
    removePathIfExists(base)
    removePathIfExists(wtPath)
}

@Test
func testPlanMergeStrategies(): Unit {
    let base = "/tmp/deepgit-mp-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/x.txt", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main1"], true)
    gitRun(base, ["checkout", "-q", "-b", "feat/x"], true)
    writeFileAtomic(base + "/x.txt", "2")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat"], true)
    let p = planMerge(base, "feat/x")
    @Assert(p.kind == "fast-forward")  // feat/x 领先 main 1 提交、main 无新提交
    // 再让 main 推进一提交，让 feat/x 落后
    gitRun(base, ["checkout", "-q", "main"], true)
    writeFileAtomic(base + "/x.txt", "3")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main2"], true)
    let p2 = planMerge(base, "feat/x")
    @Assert(p2.behind == 1)
    @Assert(p2.kind == "merge")
    removePathIfExists(base)
}

@Test
func testListStashes(): Unit {
    let base = "/tmp/deepgit-st-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/x.txt", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], true)
    writeFileAtomic(base + "/x.txt", "WIP change")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["stash", "push", "-m", "wip: testing"], true)
    let stashes = listStashes(base)
    @Assert(stashes.size == 1)
    @Assert(stashes[0].message.contains("wip"))
    removePathIfExists(base)
}

@Test
func testUntrackedFiles(): Unit {
    let base = "/tmp/deepgit-ut-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/tracked.txt", "1")
    writeFileAtomic(base + "/untracked.txt", "x")
    gitRun(base, ["add", "tracked.txt"], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], true)
    let uts = untrackedFiles(base, 50)
    @Assert(uts.size >= 1)
    var seen = false
    for (u in uts) {
        if (u.path == "untracked.txt") {
            seen = true
        }
    }
    @Assert(seen)
    removePathIfExists(base)
}

@Test
func testFileHeatmap(): Unit {
    let base = "/tmp/deepgit-hm-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/hot.txt", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "1"], true)
    writeFileAtomic(base + "/hot.txt", "2")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "2"], true)
    writeFileAtomic(base + "/hot.txt", "3")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "3"], true)
    writeFileAtomic(base + "/cold.txt", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "4"], true)
    let hm = fileHeatmap(base, "HEAD", 50, 10)
    @Assert(hm.size >= 2)
    @Assert(hm[0][0] == "hot.txt")  // 最热文件排第一
    removePathIfExists(base)
}

@Test
func testCommitTypeOf(): Unit {
    @Assert(commitTypeOf("feat: add x") == "feat")
    @Assert(commitTypeOf("feat(api): add x") == "feat")
    @Assert(commitTypeOf("FIX: broken thing") == "fix")
    @Assert(commitTypeOf("hotfix: urgent") == "fix")
    @Assert(commitTypeOf("refactor(core): cleanup") == "refactor")
    @Assert(commitTypeOf("docs: update readme") == "docs")
    @Assert(commitTypeOf("perf: speed up") == "perf")
    @Assert(commitTypeOf("chore: bump deps") == "chore")
    @Assert(commitTypeOf("tests: more coverage") == "test")
    @Assert(commitTypeOf("just a plain message") == "other")
    @Assert(commitTypeOf("feature: big thing") == "feat")
}

@Test
func testCommitTypeStats(): Unit {
    let base = "/tmp/deepgit-ct-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    let subjects = ["feat: a", "feat: b", "fix: c", "docs: d", "plain work"]
    for (s in subjects) {
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-q", "-m", "${s}"], true)
    }
    let stats = commitTypeStats(base, "HEAD", 20)
    // 顺序固定：feat 在前
    @Assert(stats[0][0] == "feat")
    @Assert(stats[0][1] == 2)
    var total = 0
    for ((t, c) in stats) {
        total += c
    }
    @Assert(total == 5)
    removePathIfExists(base)
}

@Test
func testToJsonValueClasses(): Unit {
    let wf = WorktreeInfo("/tmp/wt", "abc1234", "feat/x", false, true)
    let wj = wf.toJson()
    @Assert(Json.strAt(wj, "path", "") == "/tmp/wt")
    @Assert(Json.boolAt(wj, "isCurrent", false))

    let mp = MergePlan("fast-forward", 0, 3, "main", "feat/x", "可直接 fast-forward")
    let mj = mp.toJson()
    @Assert(Json.strAt(mj, "kind", "") == "fast-forward")
    @Assert(Json.intAt(mj, "behind", 0) == 3)

    let sf = StashInfo("stash@{0}", "main", "wip stuff", "2026-09-30")
    let sj = sf.toJson()
    @Assert(Json.strAt(sj, "message", "") == "wip stuff")

    let uf = UntrackedFile("a/b.txt", 1024, "2026-09-30")
    let uj = uf.toJson()
    @Assert(Json.intAt(uj, "size", 0) == 1024)
}

@Test
func testPlanMergeSameBranch(): Unit {
    let base = "/tmp/deepgit-pm-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], true)
    let p = planMerge(base, "main")
    @Assert(p.kind == "no-default")
    removePathIfExists(base)
}

@Test
func testListWorktreesAndStashesOnNonRepo(): Unit {
    let base = "/tmp/deepgit-nonrepo-${nowMillis()}"
    ensureDir(base)
    @Assert(listWorktrees(base).size == 0)
    @Assert(listStashes(base).size == 0)
    removePathIfExists(base)
}

@Test
func testCommitTypeStatsOnEmptyRepo(): Unit {
    let base = "/tmp/deepgit-empty-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    @Assert(commitTypeStats(base, "HEAD", 10).size == 0)
    removePathIfExists(base)
}

@Test
func testFileHeatmapTopLimit(): Unit {
    let base = "/tmp/deepgit-hm2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    for (i in 1..4) {
        writeFileAtomic(base + "/f${i}.txt", "1")
        gitRun(base, ["add", "."], true)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c${i}"], true)
    }
    let hm = fileHeatmap(base, "HEAD", 50, 2)
    @Assert(hm.size <= 2)
    removePathIfExists(base)
}

@Test
func testCommitTypeOfScopeWithoutColon(): Unit {
    // "feat(scope)" 后无冒号 → 畸形 conventional commit，归为 other
    @Assert(commitTypeOf("feat(scope) missing colon") == "other")
    @Assert(commitTypeOf("  feat: padded  ") == "feat")
    @Assert(commitTypeOf("REVERT: rollback") == "revert")
    @Assert(commitTypeOf("build(deps): bump") == "build")
}

@Test
func testUntrackedFilesOnCleanRepo(): Unit {
    let base = "/tmp/deepgit-ut2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    // 空仓库：无未跟踪
    @Assert(untrackedFiles(base, 50).size == 0)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], true)
    @Assert(untrackedFiles(base, 50).size == 0)
    removePathIfExists(base)
}

@Test
func testWorktreePorcelainParsesMain(): Unit {
    let base = "/tmp/deepgit-wt3-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], true)
    let wts = listWorktrees(base)
    @Assert(wts.size == 1)
    @Assert(wts[0].isCurrent)   // /tmp 与 /private/tmp 的符号链接差异被 samePath 容忍
    @Assert(wts[0].branch == "main")
    @Assert(!wts[0].isBare)
    removePathIfExists(base)
}

// ------------------------------ 通用 git 操作（客户端驱动） ------------------------------

public class GitOpResult {
    public let op: String
    public let ok: Bool
    public let output: String

    public init(op: String, ok: Bool, output: String) {
        this.op = op
        this.ok = ok
        this.output = output
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "op", Json.of(this.op))
        Json.set(o, "ok", Json.of(this.ok))
        Json.set(o, "output", Json.of(this.output))
        return o
    }
}

func gitOpExec(root: String, op: String, args: Array<String>): GitOpResult {
    let r = gitTry(root, args)
    var out = r.stdout
    if (!r.stderr.isEmpty()) {
        let sep = if (out.isEmpty()) { "" } else { "\n" }
        out = out + sep + r.stderr
    }
    return GitOpResult(op, r.ok() && !r.timedOut, out.trimAscii())
}

/// 面板级 git 操作：pull / push / commit / stash / unstash / fetch。
/// 刻意不提供 reset/clean 等破坏性操作；commit 需要显式 message。
public func runGitOp(root: String, op: String, message: String): GitOpResult {
    let inside = gitTry(root, ["rev-parse", "--is-inside-work-tree"])
    if (!inside.ok()) {
        return GitOpResult(op, false, "不是 git 仓库：${root}")
    }
    match (op) {
        case "pull" => return gitOpExec(root, op, ["pull", "--ff-only"])
        case "fetch" => return gitOpExec(root, op, ["fetch", "--prune"])
        case "push" =>
            // 无 upstream 时自动补 -u origin <branch>
            let cur = currentBranch(root)
            let branches = listBranches(root)
            var upstream = ""
            for (b in branches) {
                if (b.name == cur) {
                    upstream = b.upstream
                }
            }
            if (upstream.isEmpty() && !cur.isEmpty() && cur != "HEAD") {
                return gitOpExec(root, op, ["push", "-u", "origin", cur])
            }
            return gitOpExec(root, op, ["push"])
        case "commit" =>
            if (message.isBlank()) {
                return GitOpResult(op, false, "需要提交信息（--message）")
            }
            let add = gitTry(root, ["add", "-A"])
            if (!add.ok()) {
                return GitOpResult(op, false, ("add 失败\n" + add.stderr).trimAscii())
            }
            let r = gitTry(root, ["-c", "user.name=${gitUserName()}", "-c", "user.email=${gitUserEmail()}", "commit", "-m", message])
            var out = r.stdout
            if (!r.stderr.isEmpty()) {
                let sep = if (out.isEmpty()) { "" } else { "\n" }
                out = out + sep + r.stderr
            }
            return GitOpResult(op, r.ok() && !r.timedOut, out.trimAscii())
        case "stash" =>
            let m = if (message.isBlank()) { "deepgit stash ${nowIso()}" } else { message }
            return gitOpExec(root, op, ["stash", "push", "-m", m])
        case "unstash" => return gitOpExec(root, op, ["stash", "pop"])
        case _ => return GitOpResult(op, false, "未知操作：${op}（支持 pull/push/commit/stash/unstash/fetch）")
    }
}

/// commit 时的身份兜底：优先全局配置，没有则用占位身份，避免 commit 直接失败
func gitUserName(): String {
    let r = gitTry(".", ["config", "--global", "user.name"])
    let v = r.stdout.trimAscii()
    return if (v.isEmpty()) { "deepgit" } else { v }
}

func gitUserEmail(): String {
    let r = gitTry(".", ["config", "--global", "user.email"])
    let v = r.stdout.trimAscii()
    return if (v.isEmpty()) { "deepgit@local" } else { v }
}

@Test
func testRunGitOpCommitAndStash(): Unit {
    let base = "/tmp/deepgit-op-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], true)
    // commit：无 message → 失败
    let bad = runGitOp(base, "commit", "")
    @Assert(!bad.ok)
    // commit：干净仓库 → 无可提交
    let nothing = runGitOp(base, "commit", "空提交")
    @Assert(!nothing.ok)
    // commit：有改动 → 成功且工作区变干净
    writeFileAtomic(base + "/a.txt", "1")
    let c = runGitOp(base, "commit", "feat: op commit")
    @Assert(c.ok)
    @Assert(c.output.contains("op commit"))
    // stash → unstash 往返
    writeFileAtomic(base + "/a.txt", "2")
    let s = runGitOp(base, "stash", "wip via op")
    @Assert(s.ok)
    @Assert(listStashes(base).size == 1)
    let u = runGitOp(base, "unstash", "")
    @Assert(u.ok)
    @Assert(listStashes(base).size == 0)
    removePathIfExists(base)
}

@Test
func testRunGitOpUnknownAndPull(): Unit {
    let base = "/tmp/deepgit-op2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    // 未知操作
    @Assert(!runGitOp(base, "rebase-hard", "").ok)
    // 无远端的 pull：失败但要有可读输出
    let p = runGitOp(base, "pull", "")
    @Assert(!p.ok)
    @Assert(!p.output.isEmpty())
    removePathIfExists(base)
}
