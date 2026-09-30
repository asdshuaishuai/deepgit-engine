// 存储层：全局 store（~/.deepgit/store/<id>/）与单项目状态/进度读写。
//
// 设计取舍：进度状态存全局 store 而非项目内 —— 使状态天然跨分支安全，
// 不会污染任何工作区，也不产生「记录进度」的提交噪音。项目内只写生成文档。
package deepgit.kernel

import std.collection.*
import deepgit.util.*
import std.unittest.*
import std.unittest.testmacro.*

public class StorePaths {
    public let dir: String
    public let state: String
    public let progress: String
    public let journalJsonl: String
    public let journalMd: String
    public let runs: String
    public let backups: String
    public let locks: String
    public let hooks: String

    public init(projectId: String) {
        this.dir = deepgitPath(["store", projectId])
        this.state = this.dir + "/state.json"
        this.progress = this.dir + "/progress.json"
        this.journalJsonl = this.dir + "/journal.jsonl"
        this.journalMd = this.dir + "/journal.md"
        this.runs = this.dir + "/runs"
        this.backups = this.dir + "/backups"
        this.locks = this.dir + "/locks"
        this.hooks = this.dir + "/hooks"
    }
}

public func ensureStore(projectId: String): StorePaths {
    let p = StorePaths(projectId)
    ensureDir(p.dir)
    ensureDir(p.runs)
    ensureDir(p.backups)
    ensureDir(p.locks)
    ensureDir(p.hooks)
    return p
}

public func readState(projectId: String): JsonValue {
    let p = StorePaths(projectId)
    match (readFileText(p.state)) {
        case Some(text) =>
            match (Json.parse(text)) {
                case Some(j) => return j
                case None => return Json.obj()
            }
        case None => return Json.obj()
    }
}

public func writeState(projectId: String, state: JsonValue): Unit {
    let p = StorePaths(projectId)
    Json.set(state, "updatedAt", Json.of(nowIso()))
    writeFileAtomic(p.state, Json.pretty(state))
}

public func readProgress(projectId: String): JsonValue {
    let p = StorePaths(projectId)
    match (readFileText(p.progress)) {
        case Some(text) =>
            match (Json.parse(text)) {
                case Some(j) => return j
                case None => return Json.obj()
            }
        case None => return Json.obj()
    }
}

/// 进度 JSON 中的分支记录表（不可变视图副本）
public func progressBranches(progress: JsonValue): ArrayList<(String, JsonValue)> {
    let out = ArrayList<(String, JsonValue)>()
    let branches = Json.getOr(progress, "branches")
    match (Json.asObj(branches)) {
        case Some(m) =>
            for ((k, v) in m) {
                out.add((k, v))
            }
        case None => ()
    }
    return out
}

public func progressBranch(progress: JsonValue, branch: String): Option<JsonValue> {
    let branches = Json.getOr(progress, "branches")
    match (Json.get(branches, branch)) {
        case Some(v) => return Some(v)
        case None => return None
    }
}

/// 更新/创建分支记录，返回更新后的记录
public func setProgressBranch(progress: JsonValue, branch: String, patch: JsonValue): JsonValue {
    var branches = Json.getOr(progress, "branches")
    if (Json.asObj(branches).isNone()) {
        branches = Json.obj()
    }
    let existing = Json.getOr(branches, branch)
    let merged = Json.obj()
    // 保留旧字段
    match (Json.asObj(existing)) {
        case Some(m) =>
            for ((k, v) in m) {
                Json.set(merged, k, v)
            }
        case None => ()
    }
    match (Json.asObj(patch)) {
        case Some(m) =>
            for ((k, v) in m) {
                Json.set(merged, k, v)
            }
        case None => ()
    }
    // 首次记录时间
    if (!Json.has(merged, "firstTrackedAt")) {
        Json.set(merged, "firstTrackedAt", Json.of(nowIso()))
    }
    Json.set(merged, "updatedAt", Json.of(nowIso()))
    Json.set(branches, branch, merged)
    Json.set(progress, "branches", branches)
    return merged
}

public func writeProgress(projectId: String, progress: JsonValue): Unit {
    let p = StorePaths(projectId)
    Json.set(progress, "version", Json.of(1))
    Json.set(progress, "updatedAt", Json.of(nowIso()))
    // entries 截断，完整历史留在 journal.jsonl
    let entries = Json.arrAt(progress, "entries")
    if (entries.size > 200) {
        let kept = ArrayList<JsonValue>()
        for (i in (entries.size - 200)..entries.size) {
            kept.add(entries[i])
        }
        Json.set(progress, "entries", JArr(kept))
    }
    writeFileAtomic(p.progress, Json.pretty(progress))
}

/// 追加一行 JSONL（并重写人类可读 journal.md）
public func appendJournal(projectId: String, entry: JsonValue, projectName: String): Unit {
    let p = StorePaths(projectId)
    ensureDir(p.dir)
    appendLine(p.journalJsonl, Json.compact(entry))
    // 重建 markdown（保留最近 100 条）
    let tail = readJournal(projectId, 100)
    let sb = StringBuilder()
    sb.append("# deepGit 进度日志")
    if (!projectName.isEmpty()) {
        sb.append(" — ${projectName}")
    }
    sb.append("\n\n> 由 deepGit 自动维护，最新条目在最上方。\n\n")
    for (i in 0..tail.size) {
        if (i > 0) {
            sb.append("\n---\n\n")
        }
        sb.append(renderJournalEntry(tail[i]))
    }
    writeFileAtomic(p.journalMd, tidyMarkdown(sb.toString()))
}

/// 读取 JSONL（最新在前的顺序返回）
public func readJournal(projectId: String, limit: Int64): ArrayList<JsonValue> {
    let p = StorePaths(projectId)
    let out = ArrayList<JsonValue>()
    match (readFileText(p.journalJsonl)) {
        case Some(text) =>
            let lines = text.split("\n")
            let collected = ArrayList<JsonValue>()
            for (line in lines) {
                let t = line.trimAscii()
                if (t.isEmpty()) {
                    continue
                }
                match (Json.parse(t)) {
                    case Some(j) => collected.add(j)
                    case None => ()
                }
            }
            // 取最后 limit 条，反转成最新在前
            let start = if (collected.size > limit) { collected.size - limit } else { 0 }
            var i = collected.size - 1
            while (i >= start) {
                out.add(collected[i])
                i -= 1
            }
        case None => ()
    }
    return out
}

public func renderJournalEntry(e: JsonValue): String {
    let sb = StringBuilder()
    let at = Json.strAt(e, "at", "")
    let branch = Json.strAt(e, "branch", "-")
    let mode = modeLabel(Json.strAt(e, "mode", ""), "zh")
    sb.append("## ${formatDateTime(at)} · `${branch}` · ${mode}\n")
    let meta = ArrayList<String>()
    let from = Json.strAt(e, "from", "")
    let to = Json.strAt(e, "to", "")
    let commitCount = Json.intAt(e, "commitCount", 0)
    if (!from.isEmpty() && !to.isEmpty()) {
        meta.add("提交范围：`${shortSha(from)}` → `${shortSha(to)}`（${commitCount} 个提交）")
    } else if (commitCount > 0) {
        meta.add("最近 ${commitCount} 个提交")
    }
    let stats = Json.getOr(e, "stats")
    if (!Json.isNull(stats)) {
        meta.add("变更规模：${Json.intAt(stats, "files", 0)} 个文件，+${Json.intAt(stats, "insertions", 0)}/−${Json.intAt(stats, "deletions", 0)}")
    }
    let provider = Json.strAt(e, "provider", "")
    if (!provider.isEmpty()) {
        meta.add("摘要来源：${providerLabel(provider)}")
    }
    for (m in meta) {
        sb.append("- ${m}\n")
    }
    let summary = Json.strAt(e, "summary", "")
    if (!summary.isEmpty()) {
        sb.append("\n**摘要**：${oneLine(summary)}\n")
    }
    let highlights = Json.strArrAt(e, "highlights")
    if (!highlights.isEmpty()) {
        sb.append("\n**近期进展**\n")
        for (h in highlights) {
            sb.append("- ${oneLine(h)}\n")
        }
    }
    let nextSteps = Json.strArrAt(e, "nextSteps")
    if (!nextSteps.isEmpty()) {
        sb.append("\n**下一步**\n")
        for (h in nextSteps) {
            sb.append("- ${oneLine(h)}\n")
        }
    }
    let docs = Json.strArrAt(e, "docs")
    if (!docs.isEmpty()) {
        sb.append("\n**已更新文档**：${joinStrings(docs, "、")}\n")
    }
    return sb.toString().trimAsciiEnd()
}

public func modeLabel(mode: String, lang: String): String {
    let zh = lang != "en"
    match (mode) {
        case "track" => return if (zh) { "进度快照" } else { "snapshot" }
        case "shallow" => return if (zh) { "浅更新" } else { "shallow update" }
        case "deep" => return if (zh) { "深度更新" } else { "deep update" }
        case "manual" => return if (zh) { "手动记录" } else { "manual" }
        case _ => return mode
    }
}

public func providerLabel(provider: String): String {
    if (provider.isEmpty()) {
        return "未知"
    }
    if (provider == "rules") {
        return "规则引擎"
    }
    if (provider.startsWith("openai:")) {
        return "AI（${provider[7..]}）"
    }
    if (provider.startsWith("anthropic:")) {
        return "AI（${provider[10..]}）"
    }
    if (provider.startsWith("rules(after")) {
        return "规则引擎（AI 失败后降级）"
    }
    return provider
}

public func shortSha(sha: String): String {
    if (sha.size <= 8) {
        return sha
    }
    return sha[..8]
}

// ------------------------------ 测试 ------------------------------

@Test
func testStoreRoundTrip(): Unit {
    let pid = "p_test_${nowMillis()}"
    let progress = Json.obj()
    Json.set(progress, "branches", Json.obj())
    let rec = setProgressBranch(progress, "main", jsonPatch([("head", Json.of("abc123")), ("status", Json.of("active"))]))
    @Assert(Json.strAt(rec, "head", "") == "abc123")
    @Assert(Json.has(rec, "firstTrackedAt"))
    writeProgress(pid, progress)
    let back = readProgress(pid)
    let backRec = progressBranch(back, "main")
    @Assert(backRec.isSome())
    @Assert(Json.strAt(backRec.getOrThrow(), "status", "") == "active")
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testJournalAppendAndRead(): Unit {
    let pid = "p_journal_${nowMillis()}"
    let e1 = Json.obj()
    Json.set(e1, "at", Json.of(nowIso()))
    Json.set(e1, "branch", Json.of("main"))
    Json.set(e1, "mode", Json.of("shallow"))
    Json.set(e1, "summary", Json.of("第一条"))
    appendJournal(pid, e1, "demo")
    let e2 = Json.obj()
    Json.set(e2, "at", Json.of(nowIso()))
    Json.set(e2, "branch", Json.of("feat/x"))
    Json.set(e2, "mode", Json.of("deep"))
    Json.set(e2, "summary", Json.of("第二条"))
    appendJournal(pid, e2, "demo")
    let list = readJournal(pid, 10)
    @Assert(list.size == 2)
    // 最新在前
    @Assert(Json.strAt(list[0], "summary", "") == "第二条")
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testSetProgressBranchMergesFields(): Unit {
    let progress = Json.obj()
    setProgressBranch(progress, "main", jsonPatch([("a", Json.of(1))]))
    let rec = setProgressBranch(progress, "main", jsonPatch([("b", Json.of(2))]))
    @Assert(Json.intAt(rec, "a", 0) == 1)
    @Assert(Json.intAt(rec, "b", 0) == 2)
}

@Test
func testProviderLabels(): Unit {
    @Assert(providerLabel("rules") == "规则引擎")
    @Assert(providerLabel("openai:gpt-4o").contains("gpt-4o"))
    @Assert(providerLabel("").contains("未知"))
}

@Test
func testModeLabels(): Unit {
    @Assert(modeLabel("shallow", "zh") == "浅更新")
    @Assert(modeLabel("deep", "en") == "deep update")
}

@Test
func testRenderJournalEntry(): Unit {
    let e = Json.obj()
    Json.set(e, "at", Json.of("2026-09-30T10:00:00+08:00"))
    Json.set(e, "branch", Json.of("main"))
    Json.set(e, "mode", Json.of("deep"))
    Json.set(e, "summary", Json.of("完成核心层"))
    Json.set(e, "highlights", Json.strArray(["a", "b"]))
    let md = renderJournalEntry(e)
    @Assert(md.contains("main"))
    @Assert(md.contains("完成核心层"))
    @Assert(md.contains("- a"))
}

/// 测试辅助：构造 JSON 对象
func jsonPatch(pairs: Array<(String, JsonValue)>): JsonValue {
    let o = Json.obj()
    for ((k, v) in pairs) {
        Json.set(o, k, v)
    }
    return o
}
