// 浅更新（update）：记录各分支进度到 store + README/AGENT 托管区域。
package deepgit.flow

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.ai.*
import deepgit.kernel.*
import deepgit.util.*

public class UpdateOptions {
    public var mode: String = "shallow"
    public var docs: String = ""  // "" | readme | agent
    public var dryRun: Bool = false
    public var skipDocs: Bool = false
    public var source: String = "cli"
    public var noAi: Bool = false
    public var notes: ArrayList<String> = ArrayList<String>()

    public init() {}
}

public class UpdateResult {
    public let ok: Bool
    public let mode: String
    public let projectId: String
    public let projectName: String
    public let provider: String
    public let aiConfigured: Bool
    public let aiError: String
    public let branchCount: Int64
    public let commitCount: Int64
    public let docChanges: ArrayList<(String, Bool, Bool, String)>
    public let journalEntry: JsonValue
    public let facts: RepoFacts
    public let at: String

    public init(
        ok: Bool, mode: String, projectId: String, projectName: String, provider: String,
        aiConfigured: Bool, aiError: String, branchCount: Int64, commitCount: Int64,
        docChanges: ArrayList<(String, Bool, Bool, String)>, journalEntry: JsonValue, facts: RepoFacts, at: String,
    ) {
        this.ok = ok
        this.mode = mode
        this.projectId = projectId
        this.projectName = projectName
        this.provider = provider
        this.aiConfigured = aiConfigured
        this.aiError = aiError
        this.branchCount = branchCount
        this.commitCount = commitCount
        this.docChanges = docChanges
        this.journalEntry = journalEntry
        this.facts = facts
        this.at = at
    }
}

/// 候选分支集合：已追踪 ∪ 当前 ∪ 默认 ∪ 最近活跃
func collectCandidateBranches(facts: RepoFacts, progress: JsonValue, maxBranches: Int64): ArrayList<String> {
    let names = ArrayList<String>()
    func push(n: String) {
        if (n.isEmpty() || n == "HEAD") {
            return
        }
        for (x in names) {
            if (x == n) {
                return
            }
        }
        names.add(n)
    }
    for ((name, _) in progressBranches(progress)) {
        push(name)
    }
    push(facts.currentBranch)
    push(facts.defaultBranch)
    // 最近提交的分支优先
    let sorted = ArrayList<BranchInfo>()
    for (b in facts.branches) {
        sorted.add(b)
    }
    var i: Int64 = 1
    while (i < sorted.size) {
        let key = sorted[i]
        var j = i - 1
        while (j >= 0 && sorted[j].date < key.date) {
            sorted[j + 1] = sorted[j]
            j -= 1
        }
        sorted[j + 1] = key
        i += 1
    }
    var taken: Int64 = 0
    for (b in sorted) {
        if (taken >= maxBranches) {
            break
        }
        push(b.name)
        taken += 1
    }
    // 上限
    if (names.size > maxBranches * 2) {
        let trimmed = ArrayList<String>()
        var k: Int64 = 0
        for (n in names) {
            if (k >= maxBranches * 2) {
                break
            }
            trimmed.add(n)
            k += 1
        }
        return trimmed
    }
    return names
}

/// 执行浅更新
public func runUpdate(project: ProjectEntry, config: Config, opts: UpdateOptions): UpdateResult {
    let store = ensureStore(project.id)
    let lockFile = "${store.locks}/${if (opts.mode == "track") { "track" } else { "update" }}.lock"
    let startedAt = nowIso()

    return withLock(lockFile, 600000, { =>
        Log.step("采集仓库事实：${project.name}")
        let facts = collectFacts(project.path, project.kind, config, 30, false)
        var progress = readProgress(project.id)
        Json.set(progress, "projectId", Json.of(project.id))
        Json.set(progress, "name", Json.of(project.name))

        let maxBranches = config.maxShallowBranches
        let candidates = collectCandidateBranches(facts, progress, maxBranches)

        // 计算各分支增量
        let deltas = ArrayList<BranchDelta>()
        for (branch in candidates) {
            var tracked = ""
            match (progressBranch(progress, branch)) {
                case Some(rec) => tracked = Json.strAt(rec, "head", "")
                case None => ()
            }
            match (branchDelta(project.path, branch, tracked, 200, 200)) {
                case Some(d) => deltas.add(d)
                case None => ()
            }
        }

        // AI 叙述（失败降级规则引擎）
        let ai = resolveAi(config)
        var narratives = HashMap<String, BranchNarrative>()
        var provider = "rules"
        var aiError = ""
        var hasFresh = false
        for (d in deltas) {
            if (d.count() > 0) {
                hasFresh = true
            }
        }
        let trackedCount = progressBranches(progress).size
        let useAi = !opts.noAi && ai.configured && (hasFresh || trackedCount == 0)

        if (useAi) {
            Log.step("调用 AI 生成进度摘要（${ai.model}）")
            let deltasJson = branchDeltasToJson(deltas, facts)
            let previousDocs = readPreviousDocs(project.path, facts, 1500)
            let (system, user) = buildNarrativePrompt(facts, deltasJson, config.language, previousDocs)
            match (aiChatJson(ai, system, user, "")) {
                case Some(j) =>
                    let branchesPart = Json.getOr(j, "branches")
                    narratives = branchNarrativesFromJson(branchesPart)
                    provider = ai.label()
                case None =>
                    aiError = "AI 返回无法解析为 JSON"
                    Log.warn("AI 摘要失败，回退规则引擎：${aiError}")
            }
        } else if (!opts.noAi && !ai.configured) {
            Log.debug(ai.reason)
        } else if (opts.noAi) {
            Log.debug("已指定 --no-ai，使用规则引擎")
        }

        // 规则引擎补齐未覆盖的分支
        for (d in deltas) {
            var haveAi = false
            match (narratives.get(d.branch)) {
                case Some(n) =>
                    if (n.summary.size > 0) {
                        haveAi = true
                    }
                case None => ()
            }
            if (!haveAi) {
                let rn = rulesBranchNarrative(d, facts, config.language)
                narratives[d.branch] = rn
            }
        }

        // 合并到进度存储
        var branchCount: Int64 = 0
        var totalCommits: Int64 = 0
        for (d in deltas) {
            let headDate = if (d.commits.size > 0) { d.commits[0].date } else { facts.lastCommitAt }
            var detail: BranchInfo = BranchInfo(d.branch, d.head, "", "", "", 0, 0, false)
            for (b in facts.branches) {
                if (b.name == d.branch) {
                    detail = b
                }
            }
            let merged = detail.ahead == 0 && d.branch != facts.defaultBranch && isMergedBranch(project.path, facts.defaultBranch, d.branch)
            let status = computeBranchStatus(headDate, merged)
            let patch = Json.obj()
            Json.set(patch, "head", Json.of(d.head))
            Json.set(patch, "headDate", Json.of(headDate))
            Json.set(patch, "headSubject", Json.of(if (d.commits.size > 0) { d.commits[0].subject } else { "" }))
            Json.set(patch, "status", Json.of(status))
            Json.set(patch, "provider", Json.of(provider))
            Json.set(patch, "aheadOfDefault", Json.of(detail.ahead))
            Json.set(patch, "merged", Json.of(merged))
            Json.set(patch, "pendingCommits", Json.of(0))
            Json.set(patch, "lastRecordedCount", Json.of(d.count()))
            match (narratives.get(d.branch)) {
                case Some(n) =>
                    Json.set(patch, "summary", Json.of(n.summary))
                    let hl = ArrayList<JsonValue>()
                    for (h in n.highlights) {
                        hl.add(Json.of(h))
                    }
                    Json.set(patch, "highlights", JArr(hl))
                    let ns = ArrayList<JsonValue>()
                    for (h in n.nextSteps) {
                        ns.add(Json.of(h))
                    }
                    Json.set(patch, "nextSteps", JArr(ns))
                case None => ()
            }
            setProgressBranch(progress, d.branch, patch)
            branchCount += 1
            totalCommits += d.count()
        }

        // 已追踪但本轮无变化的分支：更新待记录计数
        for ((name, rec) in progressBranches(progress)) {
            var inDeltas = false
            for (d in deltas) {
                if (d.branch == name) {
                    inDeltas = true
                }
            }
            if (!inDeltas) {
                let head = Json.strAt(rec, "head", "")
                let pending = if (head.isEmpty()) { 0 } else { commitCount(project.path, "${head}..HEAD") }
                Json.set(rec, "pendingCommits", Json.of(if (pending > 500) { 0 } else { pending }))
            }
        }

        // 项目级备注
        let notesArr = ArrayList<String>()
        match (narratives.get("__overall__")) {
            case Some(n) =>
                for (h in n.highlights) {
                    notesArr.add(h)
                }
            case None => ()
        }
        for (n in rulesOverallNotes(facts, config.language)) {
            notesArr.add(n)
        }
        let overall = Json.obj()
        let summaryParts = ArrayList<String>()
        var sc: Int64 = 0
        for (d in deltas) {
            match (narratives.get(d.branch)) {
                case Some(n) =>
                    if (n.summary.size > 0 && sc < 3) {
                        summaryParts.add(n.summary)
                        sc += 1
                    }
                case None => ()
            }
        }
        Json.set(overall, "summary", Json.of(joinStrings(summaryParts, "；")))
        let notesJson = ArrayList<JsonValue>()
        var nc: Int64 = 0
        for (n in notesArr) {
            if (nc >= 6) {
                break
            }
            notesJson.add(Json.of(n))
            nc += 1
        }
        Json.set(overall, "notes", JArr(notesJson))
        Json.set(progress, "overall", overall)

        // 日志条目
        let entry = Json.obj()
        Json.set(entry, "id", Json.of(randomId("j")))
        Json.set(entry, "at", Json.of(startedAt))
        Json.set(entry, "project", Json.of(project.name))
        Json.set(entry, "projectId", Json.of(project.id))
        Json.set(entry, "branch", Json.of(if (facts.currentBranch.size > 0) { facts.currentBranch } else { facts.defaultBranch }))
        Json.set(entry, "mode", Json.of(opts.mode))
        Json.set(entry, "source", Json.of(opts.source))
        Json.set(entry, "provider", Json.of(provider))
        Json.set(entry, "commitCount", Json.of(totalCommits))
        Json.set(entry, "summary", Json.of(Json.strAt(overall, "summary", "")))
        let hlJson = ArrayList<JsonValue>()
        var hc: Int64 = 0
        for (d in deltas) {
            match (narratives.get(d.branch)) {
                case Some(n) =>
                    for (h in n.highlights) {
                        if (hc >= 6) {
                            break
                        }
                        hlJson.add(Json.of(h))
                        hc += 1
                    }
                case None => ()
            }
        }
        Json.set(entry, "highlights", JArr(hlJson))
        let nsJson = ArrayList<JsonValue>()
        var nsc: Int64 = 0
        for (d in deltas) {
            match (narratives.get(d.branch)) {
                case Some(n) =>
                    for (h in n.nextSteps) {
                        if (nsc >= 5) {
                            break
                        }
                        nsJson.add(Json.of(h))
                        nsc += 1
                    }
                case None => ()
            }
        }
        Json.set(entry, "nextSteps", JArr(nsJson))
        let docsArr = ArrayList<JsonValue>()
        for (n in opts.notes) {
            docsArr.add(Json.of(n))
        }
        Json.set(entry, "notes", JArr(docsArr))

        let entries = Json.arrAt(progress, "entries")
        entries.add(entry)
        Json.set(progress, "entries", JArr(entries))

        // 文档写入
        let docChanges = ArrayList<(String, Bool, Bool, String)>()
        if (!opts.skipDocs) {
            let targets = newDocTargets(config, opts.docs, facts)
            let readmeContent = renderProgressReadme(
                facts, progress, narratives, config.language,
                opts.mode, startedAt, config.maxShallowBranches,
            )
            let agentContent = renderProgressAgent(facts, progress, narratives, config.language, opts.mode, startedAt)
            for ((file, isReadme) in targets) {
                let fullPath = "${project.path}/${file}"
                let content = if (isReadme) { readmeContent } else { agentContent }
                if (opts.dryRun) {
                    docChanges.add((file, true, false, content))
                    continue
                }
                let backupDir = "${store.backups}/${file.replace("/", "_")}"
                let regions = ArrayList<(String, String)>([("progress", content)])
                let template = if (isReadme) { "# ${facts.name}\n\n" } else { "" }
                let res = applyRegions(fullPath, regions, backupDir, template)
                docChanges.add((file, res.changed, res.created, ""))
                if (res.changed) {
                    Log.ok("已更新 ${file}${if (res.created) { "（新建）" } else { "" }}")
                } else {
                    Log.debug("${file} 无变化")
                }
            }
        }

        if (!opts.dryRun) {
            writeProgress(project.id, progress)
            appendJournal(project.id, entry, project.name)
            var state = readState(project.id)
            Json.set(state, "lastUpdateAt", Json.of(startedAt))
            if (opts.mode == "track") {
                Json.set(state, "lastTrackAt", Json.of(startedAt))
            }
            Json.set(state, "runCount", Json.of(Json.intAt(state, "runCount", 0) + 1))
            writeState(project.id, state)
            for ((file, _, _, _) in docChanges) {
                pruneBackups("${store.backups}/${file.replace("/", "_")}", config.backupKeep)
            }
        }

        return UpdateResult(
            true, opts.mode, project.id, project.name, provider, ai.configured, aiError,
            branchCount, totalCommits, docChanges, entry, facts, startedAt,
        )
    })
}

/// 快速进度快照：只更新 store，不动文档，不用 AI
public func runTrack(project: ProjectEntry, config: Config, source: String): UpdateResult {
    let opts = UpdateOptions()
    opts.mode = "track"
    opts.skipDocs = true
    opts.noAi = true
    opts.source = source
    return runUpdate(project, config, opts)
}

func readPreviousDocs(root: String, facts: RepoFacts, maxChars: Int64): ArrayList<(String, String)> {
    let out = ArrayList<(String, String)>()
    for (file in facts.docsPresent) {
        match (readFileText("${root}/${file}")) {
            case Some(c) => out.add((file, truncateChars(c, maxChars)))
            case None => ()
        }
    }
    return out
}

func newDocTargets(config: Config, docs: String, facts: RepoFacts): ArrayList<(String, Bool)> {
    let out = ArrayList<(String, Bool)>()
    if (docs == "readme") {
        out.add(("README.md", true))
        return out
    }
    if (docs == "agent") {
        for (f in config.agentDocCandidates) {
            if (isDocPresent(facts, f)) {
                out.add((f, false))
            }
        }
        return out
    }
    // 默认：README 总是更新；agent 文档仅当已存在
    var hasReadme = false
    for (f in facts.docsPresent) {
        if (f.toAsciiLower() == "readme.md") {
            hasReadme = true
        }
    }
    if (hasReadme) {
        out.add(("README.md", true))
    } else {
        out.add(("README.md", true))
    }
    for (f in config.agentDocCandidates) {
        if (isDocPresent(facts, f)) {
            out.add((f, false))
        }
    }
    return out
}

func isDocPresent(facts: RepoFacts, file: String): Bool {
    for (d in facts.docsPresent) {
        if (d == file) {
            return true
        }
    }
    return false
}

func isMergedBranch(root: String, defaultBranch: String, branch: String): Bool {
    if (defaultBranch.isEmpty() || defaultBranch == branch) {
        return false
    }
    match (revParse(root, branch)) {
        case Some(head) => return isAncestor(root, head, defaultBranch)
        case None => return false
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testRunUpdateOnRealRepoWithRulesEngine(): Unit {
    let base = "/tmp/deepgit-upd-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/README.md", "# my proj\n\n用户手写内容\n")
    writeFileAtomic(base + "/main.cj", "package x")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: initial commit"], true)

    // 直接用路径构造 entry（项目注册表在 CLI 层负责）
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)

    let config = Config.defaults()
    let opts = UpdateOptions()
    opts.mode = "shallow"
    opts.noAi = true
    let result = runUpdate(project, config, opts)

    @Assert(result.ok)
    @Assert(result.branchCount >= 1)
    @Assert(result.commitCount >= 1)
    // README 被写入托管区域，且用户内容保留
    let readme = readFileTextOr(base + "/README.md", "")
    @Assert(readme.contains("用户手写内容"))
    @Assert(readme.contains("deepgit:begin progress"))
    // 进度已落库
    let progress = readProgress(pid)
    @Assert(progressBranch(progress, "main").isSome())
    // 日志已写入
    let journal = readJournal(pid, 10)
    @Assert(journal.size >= 1)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testRunTrackSkipsDocs(): Unit {
    let base = "/tmp/deepgit-track-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/README.md", "# x\n")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], true)
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let before = readFileTextOr(base + "/README.md", "")
    let result = runTrack(project, Config.defaults(), "test")
    let after = readFileTextOr(base + "/README.md", "")
    @Assert(result.ok)
    @Assert(before == after)  // 文档未被触碰
    @Assert(progressBranch(readProgress(pid), "main").isSome())
    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testRunUpdateDryRunDoesNotWrite(): Unit {
    let base = "/tmp/deepgit-dry-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/README.md", "# x\n")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], true)
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let opts = UpdateOptions()
    opts.dryRun = true
    opts.noAi = true
    let result = runUpdate(project, Config.defaults(), opts)
    @Assert(result.ok)
    let after = readFileTextOr(base + "/README.md", "")
    @Assert(!after.contains("deepgit:begin"))  // 未写入
    @Assert(result.docChanges.size > 0)
    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
}
