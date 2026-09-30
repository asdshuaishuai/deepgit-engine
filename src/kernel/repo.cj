// 仓库事实采集：把 git 数据规整成 AI 可读的结构化事实。
package deepgit.kernel

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

public class RepoFacts {
    public let kind: String  // git | dir
    public let name: String
    public let path: String
    public let remote: String
    public let currentBranch: String
    public let defaultBranch: String
    public let headShort: String
    public let headSubject: String
    public let lastCommitAt: String
    public let firstCommitAt: String
    public let commitCount: Int64
    public let branches: ArrayList<BranchInfo>
    public let dirty: DirtyState
    public let stashCount: Int64
    public let tags: ArrayList<(String, String)>
    public let authors: ArrayList<(Int64, String)>
    public let trackedFiles: Int64
    public let langStats: ArrayList<(String, Int64)>
    public let structure: ArrayList<String>
    public let recentCommits: ArrayList<CommitInfo>
    public let oldestCommits: ArrayList<CommitInfo>
    public let commitActivity: ArrayList<(String, Int64)>
    public let manifests: ArrayList<String>
    public let docsPresent: ArrayList<String>
    public let activity: Option<ActivitySnapshot>
    public let warnings: ArrayList<String>
    public let commitTypes: ArrayList<(String, Int64)>
    public let untrackedCount: Int64
    public let worktreeCount: Int64
    public let mergeHint: Option<MergePlan>
    public let hotFiles: ArrayList<(String, Int64)>

    public init(
        kind: String, name: String, path: String, remote: String, currentBranch: String, defaultBranch: String,
        headShort: String, headSubject: String, lastCommitAt: String, firstCommitAt: String, commitCount: Int64,
        branches: ArrayList<BranchInfo>, dirty: DirtyState, stashCount: Int64, tags: ArrayList<(String, String)>,
        authors: ArrayList<(Int64, String)>, trackedFiles: Int64, langStats: ArrayList<(String, Int64)>,
        structure: ArrayList<String>, recentCommits: ArrayList<CommitInfo>, oldestCommits: ArrayList<CommitInfo>,
        commitActivity: ArrayList<(String, Int64)>, manifests: ArrayList<String>, docsPresent: ArrayList<String>,
        activity: Option<ActivitySnapshot>, warnings: ArrayList<String>,
        commitTypes: ArrayList<(String, Int64)>, untrackedCount: Int64, worktreeCount: Int64,
        mergeHint: Option<MergePlan>, hotFiles: ArrayList<(String, Int64)>,
    ) {
        this.kind = kind
        this.name = name
        this.path = path
        this.remote = remote
        this.currentBranch = currentBranch
        this.defaultBranch = defaultBranch
        this.headShort = headShort
        this.headSubject = headSubject
        this.lastCommitAt = lastCommitAt
        this.firstCommitAt = firstCommitAt
        this.commitCount = commitCount
        this.branches = branches
        this.dirty = dirty
        this.stashCount = stashCount
        this.tags = tags
        this.authors = authors
        this.trackedFiles = trackedFiles
        this.langStats = langStats
        this.structure = structure
        this.recentCommits = recentCommits
        this.oldestCommits = oldestCommits
        this.commitActivity = commitActivity
        this.manifests = manifests
        this.docsPresent = docsPresent
        this.activity = activity
        this.warnings = warnings
        this.commitTypes = commitTypes
        this.untrackedCount = untrackedCount
        this.worktreeCount = worktreeCount
        this.mergeHint = mergeHint
        this.hotFiles = hotFiles
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "kind", Json.of(this.kind))
        Json.set(o, "name", Json.of(this.name))
        Json.set(o, "path", Json.of(this.path))
        Json.set(o, "remote", Json.of(this.remote))
        Json.set(o, "currentBranch", Json.of(this.currentBranch))
        Json.set(o, "defaultBranch", Json.of(this.defaultBranch))
        Json.set(o, "head", Json.of(this.headShort))
        Json.set(o, "headSubject", Json.of(this.headSubject))
        Json.set(o, "lastCommitAt", Json.of(this.lastCommitAt))
        Json.set(o, "firstCommitAt", Json.of(this.firstCommitAt))
        Json.set(o, "commitCount", Json.of(this.commitCount))
        let brArr = ArrayList<JsonValue>()
        for (b in this.branches) {
            let bo = Json.obj()
            Json.set(bo, "name", Json.of(b.name))
            Json.set(bo, "head", Json.of(shortSha(b.head)))
            Json.set(bo, "date", Json.of(b.date))
            Json.set(bo, "subject", Json.of(b.subject))
            Json.set(bo, "upstream", Json.of(b.upstream))
            Json.set(bo, "ahead", Json.of(b.ahead))
            Json.set(bo, "behind", Json.of(b.behind))
            brArr.add(bo)
        }
        Json.set(o, "branches", JArr(brArr))
        Json.set(o, "dirty", this.dirty.toJson())
        Json.set(o, "stashCount", Json.of(this.stashCount))
        let tagArr = ArrayList<JsonValue>()
        for ((name, date) in this.tags) {
            let to = Json.obj()
            Json.set(to, "name", Json.of(name))
            Json.set(to, "date", Json.of(date))
            tagArr.add(to)
        }
        Json.set(o, "tags", JArr(tagArr))
        let authorArr = ArrayList<JsonValue>()
        for ((count, name) in this.authors) {
            let ao = Json.obj()
            Json.set(ao, "name", Json.of(name))
            Json.set(ao, "commits", Json.of(count))
            authorArr.add(ao)
        }
        Json.set(o, "authors", JArr(authorArr))
        let fs = Json.obj()
        Json.set(fs, "trackedFiles", Json.of(this.trackedFiles))
        let langArr = ArrayList<JsonValue>()
        for ((lang, count) in this.langStats) {
            let lo = Json.obj()
            Json.set(lo, "language", Json.of(lang))
            Json.set(lo, "count", Json.of(count))
            langArr.add(lo)
        }
        Json.set(fs, "byLanguage", JArr(langArr))
        Json.set(o, "fileStats", fs)
        let stArr = ArrayList<JsonValue>()
        for (s in this.structure) {
            stArr.add(Json.of(s))
        }
        Json.set(o, "structure", JArr(stArr))
        let rcArr = ArrayList<JsonValue>()
        for (c in this.recentCommits) {
            rcArr.add(c.toJson())
        }
        Json.set(o, "recentCommits", JArr(rcArr))
        let ocArr = ArrayList<JsonValue>()
        for (c in this.oldestCommits) {
            ocArr.add(c.toJson())
        }
        Json.set(o, "oldestCommits", JArr(ocArr))
        let caArr = ArrayList<JsonValue>()
        for ((month, count) in this.commitActivity) {
            let ao = Json.obj()
            Json.set(ao, "month", Json.of(month))
            Json.set(ao, "count", Json.of(count))
            caArr.add(ao)
        }
        Json.set(o, "commitActivity", JArr(caArr))
        let mArr = ArrayList<JsonValue>()
        for (m in this.manifests) {
            mArr.add(Json.of(m))
        }
        Json.set(o, "manifests", JArr(mArr))
        let dArr = ArrayList<JsonValue>()
        for (d in this.docsPresent) {
            dArr.add(Json.of(d))
        }
        Json.set(o, "docsPresent", JArr(dArr))
        match (this.activity) {
            case Some(a) => Json.set(o, "activity", a.toJson())
            case None => ()
        }
        let wArr = ArrayList<JsonValue>()
        for (w in this.warnings) {
            wArr.add(Json.of(w))
        }
        Json.set(o, "warnings", JArr(wArr))
        let ctArr = ArrayList<JsonValue>()
        for ((t, count) in this.commitTypes) {
            let cto = Json.obj()
            Json.set(cto, "type", Json.of(t))
            Json.set(cto, "count", Json.of(count))
            ctArr.add(cto)
        }
        Json.set(o, "commitTypes", JArr(ctArr))
        Json.set(o, "untrackedCount", Json.of(this.untrackedCount))
        Json.set(o, "worktreeCount", Json.of(this.worktreeCount))
        match (this.mergeHint) {
            case Some(m) => Json.set(o, "mergeHint", m.toJson())
            case None => ()
        }
        let hfArr = ArrayList<JsonValue>()
        for ((f, count) in this.hotFiles) {
            let hfo = Json.obj()
            Json.set(hfo, "file", Json.of(f))
            Json.set(hfo, "count", Json.of(count))
            hfArr.add(hfo)
        }
        Json.set(o, "hotFiles", JArr(hfArr))
        return o
    }
}

// ------------------------------ 语言识别 ------------------------------

public func languageOf(file: String): String {
    let f = file.toAsciiLower()
    if (f.endsWith(".mbt.md")) {
        return "MoonBit"
    }
    if (f.endsWith(".mbt")) {
        return "MoonBit"
    }
    if (f.endsWith(".ts") || f.endsWith(".tsx") || f.endsWith(".mts") || f.endsWith(".cts")) {
        return "TypeScript"
    }
    if (f.endsWith(".js") || f.endsWith(".jsx") || f.endsWith(".mjs") || f.endsWith(".cjs")) {
        return "JavaScript"
    }
    if (f.endsWith(".swift")) {
        return "Swift"
    }
    if (f.endsWith(".rs")) {
        return "Rust"
    }
    if (f.endsWith(".cj")) {
        return "Cangjie"
    }
    if (f.endsWith(".go")) {
        return "Go"
    }
    if (f.endsWith(".py")) {
        return "Python"
    }
    if (f.endsWith(".java") || f.endsWith(".kt") || f.endsWith(".kts")) {
        return "JVM"
    }
    if (f.endsWith(".c") || f.endsWith(".h") || f.endsWith(".cc") || f.endsWith(".cpp") || f.endsWith(".hpp")) {
        return "C/C++"
    }
    if (f.endsWith(".css") || f.endsWith(".scss") || f.endsWith(".less")) {
        return "CSS"
    }
    if (f.endsWith(".html") || f.endsWith(".htm")) {
        return "HTML"
    }
    if (f.endsWith(".json") || f.endsWith(".yaml") || f.endsWith(".yml") || f.endsWith(".toml")) {
        return "配置"
    }
    if (f.endsWith(".md") || f.endsWith(".mdx")) {
        return "Markdown"
    }
    if (f.endsWith(".sh") || f.endsWith(".bash") || f.endsWith(".zsh")) {
        return "Shell"
    }
    return "其他"
}

public func langStats(files: ArrayList<String>, top: Int64): ArrayList<(String, Int64)> {
    let langs = ArrayList<String>()
    let counts = ArrayList<Int64>()
    for (f in files) {
        let lang = languageOf(f)
        var found = false
        for (i in 0..langs.size) {
            if (langs[i] == lang) {
                counts[i] = counts[i] + 1
                found = true
                break
            }
        }
        if (!found) {
            langs.add(lang)
            counts.add(1)
        }
    }
    // 按计数排序（插入排序，数据量小）
    let idx = ArrayList<Int64>()
    for (i in 0..langs.size) {
        idx.add(i)
    }
    for (i in 1..idx.size) {
        let key = idx[i]
        var j = i - 1
        while (j >= 0 && counts[idx[j]] < counts[key]) {
            idx[j + 1] = idx[j]
            j -= 1
        }
        idx[j + 1] = key
    }
    let out = ArrayList<(String, Int64)>()
    for (i in idx) {
        if (out.size >= top) {
            break
        }
        out.add((langs[i], counts[i]))
    }
    return out
}

/// 目录树聚合（前 maxDepth 层）
public func buildStructure(files: ArrayList<String>, maxLines: Int64, maxDepth: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    let keys = ArrayList<String>()
    let counts = ArrayList<Int64>()
    var rootCount: Int64 = 0
    for (f in files) {
        if (!f.contains("/")) {
            rootCount += 1
            continue
        }
        let parts = f.split("/")
        var prefix = ""
        var depth: Int64 = 0
        for (i in 0..parts.size - 1) {
            if (depth >= maxDepth) {
                break
            }
            let seg = parts[i]
            let key = if (prefix.isEmpty()) { seg } else { "${prefix}/${seg}" }
            var found = false
            for (j in 0..keys.size) {
                if (keys[j] == key) {
                    counts[j] = counts[j] + 1
                    found = true
                    break
                }
            }
            if (!found) {
                keys.add(key)
                counts.add(1)
            }
            prefix = key
            depth += 1
        }
    }
    if (rootCount > 0) {
        out.add("(根目录 ${rootCount} 个文件)")
    }
    // 排序
    let idx = ArrayList<Int64>()
    for (i in 0..keys.size) {
        idx.add(i)
    }
    for (i in 1..idx.size) {
        let key = idx[i]
        var j = i - 1
        while (j >= 0 && keys[idx[j]] > keys[key]) {
            idx[j + 1] = idx[j]
            j -= 1
        }
        idx[j + 1] = key
    }
    for (i in idx) {
        if (out.size >= maxLines) {
            out.add("…（更多目录省略）")
            break
        }
        let key = keys[i]
        let depth = countChar(key, 0x2fu8)
        let sb = StringBuilder()
        for (_ in 0..depth) {
            sb.append("  ")
        }
        sb.append(basename(key))
        sb.append("/ (${counts[i]})")
        out.add(sb.toString())
    }
    return out
}

func countChar(s: String, ch: Byte): Int64 {
    var n: Int64 = 0
    for (b in s.toArray()) {
        if (b == ch) {
            n += 1
        }
    }
    return n
}

// ------------------------------ 事实采集 ------------------------------

let MANIFEST_FILES = ["package.json", "moon.mod.json", "Cargo.toml", "Package.swift", "pyproject.toml", "go.mod", "pubspec.yaml", "pom.xml", "cjpm.toml"]

// 缓存：TCC 场景每次 stat 都要吃满超时并泄漏一个 stat 子进程（SubProcess 无 kill API），
// 缓存让长驻服务（serve/mcp）的泄漏有界且大幅加速
let volumeCache = HashMap<String, (Bool, Int64)>()
let VOLUME_CACHE_TTL: Int64 = 60000

/// 卷可达性预检：区分「路径不存在」与「TCC 访问阻塞（超时）」。
/// 返回 (可达, 是否超时)；结果缓存 60s。
public func volumeAccessibleEx(path: String): (Bool, Bool) {
    let now = nowMillis()
    match (volumeCache.get(path)) {
        case Some((ok, at)) =>
            if (now - at < VOLUME_CACHE_TTL) {
                return (ok, false)
            }
        case None => ()
    }
    let r = execCapture("stat", [path], None, 1200)
    let ok = r.ok() && !r.timedOut
    volumeCache[path] = (ok, now)
    return (ok, r.timedOut)
}

public func volumeAccessible(path: String): Bool {
    let (ok, _) = volumeAccessibleEx(path)
    return ok
}

public func collectFacts(root: String, kind: String, config: Config, commits: Int64, deep: Bool): RepoFacts {
    if (kind != "git") {
        return collectDirFacts(root, config)
    }
    let (accessible, timedOut) = volumeAccessibleEx(root)
    if (!accessible) {
        let hint = if (timedOut) {
            "无法访问 ${root} —— 访问被持续阻塞，很可能是 macOS 未授予「可移除宗卷」访问权限（系统设置 → 隐私与安全性 → 文件与文件夹 → deepGit）"
        } else {
            "路径不存在或卷未挂载：${root}"
        }
        throw DgError("VOLUME_BLOCKED", hint, 1, None)
    }

    let branches = listBranches(root)
    let dirty = statusSummary(root)
    let stash = stashCount(root)
    let remote = remoteUrl(root)
    let tagList = tags(root, 10)
    let authors = authorStats(root, 8)
    let firstAt = firstCommitDate(root)
    let recent = logCommits(root, commits, "HEAD", 0)
    let files = lsFiles(root, 20000)
    let defBranch = defaultBranch(root)
    let curBranch = currentBranch(root)

    var headShort = ""
    var headSubject = ""
    var lastAt = ""
    if (recent.size > 0) {
        headShort = recent[0].sha
        headSubject = recent[0].subject
        lastAt = recent[0].date
    }

    var oldest = ArrayList<CommitInfo>()
    let total = commitCount(root, "HEAD")
    var activity: ArrayList<(String, Int64)> = ArrayList<(String, Int64)>()
    var structure: ArrayList<String> = ArrayList<String>()
    var hot: ArrayList<(String, Int64)> = ArrayList<(String, Int64)>()
    if (deep) {
        // 项目起点用真正的 root commit，而不是"最早的若干条"
        oldest = genesisCommits(root, 5)
        activity = commitActivity(root, 400)
        structure = buildStructure(files, 100, 3)
        hot = fileHeatmap(root, "HEAD", 200, 8)
    } else {
        structure = buildStructure(files, 40, 2)
    }

    let manifests = detectManifests(root, config)
    let docsPresent = detectDocsPresent(root, config)

    // 浅更新增强数据：提交类型分布 / 未跟踪文件 / 多工作区 / 合入提示
    let types = commitTypeStats(root, "HEAD", commits)
    let uts = untrackedFiles(root, 50)
    let wts = listWorktrees(root)
    var mergeHint: Option<MergePlan> = Option<MergePlan>.None
    if (curBranch != defBranch && curBranch != "HEAD" && !curBranch.isEmpty()) {
        mergeHint = Some(planMerge(root, curBranch))
    }

    return RepoFacts(
        "git", basename(root), root, remote, curBranch, defBranch,
        headShort, headSubject, lastAt, optionOr(firstAt, ""), total,
        branches, dirty, stash, tagList, authors,
        files.size, langStats(files, 12), structure,
        recent, oldest, activity, manifests, docsPresent,
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        types, uts.size, wts.size, mergeHint, hot,
    )
}

func optionOr(o: Option<String>, fallback: String): String {
    match (o) {
        case Some(s) => return s
        case None => return fallback
    }
}

func detectManifests(root: String, config: Config): ArrayList<String> {
    let out = ArrayList<String>()
    for (m in MANIFEST_FILES) {
        if (fileExists("${root}/${m}")) {
            out.add(m)
        }
    }
    return out
}

public func detectDocsPresent(root: String, config: Config): ArrayList<String> {
    let out = ArrayList<String>()
    let candidates = ArrayList<String>()
    for (d in config.docs) {
        candidates.add(d)
    }
    for (d in config.agentDocCandidates) {
        var dup = false
        for (c in candidates) {
            if (c == d) {
                dup = true
                break
            }
        }
        if (!dup) {
            candidates.add(d)
        }
    }
    for (c in candidates) {
        if (fileExists("${root}/${c}")) {
            out.add(c)
        }
    }
    return out
}

// ------------------------------ 非 git 活动模式 ------------------------------

public class ActivitySnapshot {
    public let fileCount: Int64
    public let totalBytes: Int64
    public let newest: ArrayList<(String, String, Int64)>  // rel, mtime, size
    public let topDirs: ArrayList<(String, Int64)>
    public let newestMtime: String

    public init(fileCount: Int64, totalBytes: Int64, newest: ArrayList<(String, String, Int64)>, topDirs: ArrayList<(String, Int64)>, newestMtime: String) {
        this.fileCount = fileCount
        this.totalBytes = totalBytes
        this.newest = newest
        this.topDirs = topDirs
        this.newestMtime = newestMtime
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "fileCount", Json.of(this.fileCount))
        Json.set(o, "totalBytes", Json.of(this.totalBytes))
        let arr = ArrayList<JsonValue>()
        for ((rel, mtime, size) in this.newest) {
            let e = Json.obj()
            Json.set(e, "rel", Json.of(rel))
            Json.set(e, "mtime", Json.of(mtime))
            Json.set(e, "size", Json.of(size))
            arr.add(e)
        }
        Json.set(o, "newest", JArr(arr))
        let dirArr = ArrayList<JsonValue>()
        for ((name, count) in this.topDirs) {
            let e = Json.obj()
            Json.set(e, "name", Json.of(name))
            Json.set(e, "count", Json.of(count))
            dirArr.add(e)
        }
        Json.set(o, "topDirs", JArr(dirArr))
        Json.set(o, "newestMtime", Json.of(this.newestMtime))
        return o
    }
}

let SKIP_DIRS = ["node_modules", ".git", ".svn", ".hg", ".build", ".swiftpm", "build", "dist", "target", "__pycache__", ".venv", "venv", ".next", ".cache", ".gradle", ".idea", "_build", "coverage", "DerivedData", "renders", "snapshots", ".playwright-mcp", ".zcode"]

func shouldSkipDir(name: String): Bool {
    for (s in SKIP_DIRS) {
        if (s == name) {
            return true
        }
    }
    return false
}

/// 扫描目录活动（基于 mtime，深度有界）
public func collectActivity(dir: String, maxFiles: Int64, maxDepth: Int64): ActivitySnapshot {
    let files = ArrayList<(String, String, Int64)>()  // rel, mtime, size
    let dirCounts = ArrayList<(String, Int64)>()
    var totalBytes: Int64 = 0
    let queue = ArrayList<(String, Int64)>()
    queue.add((dir, 0))
    var head = 0
    while (head < queue.size && files.size < maxFiles) {
        let (cur, depth) = queue[head]
        head += 1
        let entries = listDir(cur)
        for (info in entries) {
            let nm = info.name
            if (nm.startsWith(".")) {
                continue
            }
            if (info.isDirectory()) {
                if (shouldSkipDir(nm) || depth >= maxDepth) {
                    continue
                }
                queue.add((cur + "/" + nm, depth + 1))
                continue
            }
            if (!info.isRegular()) {
                continue
            }
            let rel = relativeTo(dir, cur + "/" + nm)
            let mtime = info.lastModificationTime.toString()
            files.add((rel, mtime, info.size))
            totalBytes += info.size
            let top = if (rel.contains("/")) { rel[..indexOfStr(rel, "/")] } else { "" }
            if (top.size > 0) {
                var found = false
                for (i in 0..dirCounts.size) {
                    let (n, c) = dirCounts[i]
                    if (n == top) {
                        dirCounts[i] = (n, c + 1)
                        found = true
                        break
                    }
                }
                if (!found) {
                    dirCounts.add((top, 1))
                }
            }
        }
    }

    // 按 mtime 倒序（插入排序）
    let sorted = ArrayList<(String, String, Int64)>()
    for (f in files) {
        sorted.add(f)
    }
    var i = 1
    while (i < sorted.size) {
        let key = sorted[i]
        var j = i - 1
        while (j >= 0 && sorted[j][1] < key[1]) {
            sorted[j + 1] = sorted[j]
            j -= 1
        }
        sorted[j + 1] = key
        i += 1
    }

    let newest = ArrayList<(String, String, Int64)>()
    for (k in 0..if (sorted.size > 20) { 20 } else { sorted.size }) {
        newest.add(sorted[k])
    }

    // topDirs 排序
    var topDirs = ArrayList<(String, Int64)>()
    for (d in dirCounts) {
        topDirs.add(d)
    }
    var a = 1
    while (a < topDirs.size) {
        let key = topDirs[a]
        var b = a - 1
        while (b >= 0 && topDirs[b][1] < key[1]) {
            topDirs[b + 1] = topDirs[b]
            b -= 1
        }
        topDirs[b + 1] = key
        a += 1
    }
    if (topDirs.size > 15) {
        let trimmed = ArrayList<(String, Int64)>()
        for (k in 0..15) {
            trimmed.add(topDirs[k])
        }
        topDirs = trimmed
    }

    let newestMtime = if (newest.isEmpty()) { "" } else { newest[0][1] }
    return ActivitySnapshot(files.size, totalBytes, newest, topDirs, newestMtime)
}

func relativeTo(base: String, abs: String): String {
    let b = if (base.endsWith("/")) { base } else { base + "/" }
    if (abs.startsWith(b)) {
        return abs[b.size..]
    }
    return abs
}

func indexOfStr(s: String, needle: String): Int64 {
    match (s.indexOf(needle)) {
        case Some(i) => return i
        case None => return 0
    }
}

func collectDirFacts(root: String, config: Config): RepoFacts {
    let activity = collectActivity(root, 12000, 6)
    let manifests = detectManifests(root, config)
    let docsPresent = detectDocsPresent(root, config)
    let structure = ArrayList<String>()
    for ((name, count) in activity.topDirs) {
        structure.add("${name}/ (${count})")
    }
    let warnings = ArrayList<String>()
    warnings.add("非 git 仓库：进度基于文件活动时间，不含提交历史")
    return RepoFacts(
        "dir", basename(root), root, "", "", "",
        "", "", activity.newestMtime, "", 0,
        ArrayList<BranchInfo>(), DirtyState(true, 0, 0, 0, 0, 0, ArrayList<String>()), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        activity.fileCount, langStats(ArrayList<String>(), 12), structure,
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        manifests, docsPresent, Some(activity), warnings,
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
}

// ------------------------------ 测试 ------------------------------

@Test
func testLanguageOf(): Unit {
    @Assert(languageOf("src/main.swift") == "Swift")
    @Assert(languageOf("engine/src/main.cj") == "Cangjie")
    @Assert(languageOf("a/b.mbt.md") == "MoonBit")
    @Assert(languageOf("x.tsx") == "TypeScript")
    @Assert(languageOf("README.md") == "Markdown")
    @Assert(languageOf("unknown.xyz") == "其他")
}

@Test
func testLangStatsOrdering(): Unit {
    let files = ArrayList<String>(["a.swift", "b.swift", "c.rs", "d.md"])
    let stats = langStats(files, 12)
    @Assert(stats[0][0] == "Swift")
    @Assert(stats[0][1] == 2)
}

@Test
func testBuildStructure(): Unit {
    let files = ArrayList<String>(["src/a.cj", "src/util/b.cj", "README.md", "src/util/c.cj"])
    let s = buildStructure(files, 20, 3)
    let joined = joinStrings(s, "\n")
    @Assert(joined.contains("src/"))
    @Assert(joined.contains("util/"))
    @Assert(joined.contains("根目录 1 个文件"))
}

@Test
func testCollectDirFactsNonGit(): Unit {
    let tmp = "/tmp/deepgit-facts-${nowMillis()}"
    ensureDir(tmp + "/src")
    writeFileAtomic(tmp + "/README.md", "# test")
    writeFileAtomic(tmp + "/src/a.cj", "package a")
    let facts = collectFacts(tmp, "dir", Config.defaults(), 10, false)
    @Assert(facts.kind == "dir")
    @Assert(facts.activity.isSome())
    @Assert(facts.warnings.size > 0)
    @Assert(facts.docsPresent.size > 0)
    removePathIfExists(tmp)
}

@Test
func testRepoFactsJsonShape(): Unit {
    let tmp = "/tmp/deepgit-fj-${nowMillis()}"
    ensureDir(tmp)
    let facts = collectFacts(tmp, "dir", Config.defaults(), 10, false)
    let j = facts.toJson()
    @Assert(Json.strAt(j, "kind", "") == "dir")
    @Assert(Json.get(j, "activity").isSome())
    removePathIfExists(tmp)
}

@Test
func testShortSha(): Unit {
    @Assert(shortSha("0123456789abcdef") == "01234567")
    @Assert(shortSha("abc") == "abc")
}

@Test
func testCommitTypesAndHotFilesInFacts(): Unit {
    let base = "/tmp/deepgit-facts2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/hot.cj", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], true)
    writeFileAtomic(base + "/hot.cj", "2")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fix: two"], true)
    writeFileAtomic(base + "/loose.txt", "x")  // 未跟踪

    let facts = collectFacts(base, "git", Config.defaults(), 10, true)
    @Assert(facts.commitTypes.size >= 2)
    @Assert(facts.commitTypes[0][0] == "feat")
    @Assert(facts.untrackedCount >= 1)
    @Assert(facts.hotFiles.size >= 1)
    @Assert(facts.hotFiles[0][0] == "hot.cj")
    @Assert(facts.hotFiles[0][1] == 2)
    // toJson 一致性
    let j = facts.toJson()
    @Assert(Json.arrAt(j, "commitTypes").size >= 2)
    @Assert(Json.intAt(j, "untrackedCount", 0) >= 1)
    @Assert(Json.arrAt(j, "hotFiles").size >= 1)
    removePathIfExists(base)
}
