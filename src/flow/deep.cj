// 深度更新（deep）：手动触发的全量文档重写（overview/history/architecture/commands）。
package deepgit.flow

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.ai.*
import deepgit.kernel.*
import deepgit.util.*

public class DeepOptions {
    public var scope: String = "all"  // all | readme | agent
    public var dryRun: Bool = false
    public var source: String = "cli"
    public var notes: ArrayList<String> = ArrayList<String>()

    public init() {}
}

public class DeepResult {
    public let ok: Bool
    public let projectId: String
    public let projectName: String
    public let provider: String
    public let aiConfigured: Bool
    public let aiError: String
    public let highlights: ArrayList<String>
    public let docChanges: ArrayList<(String, Bool, Bool, String)>
    public let journalEntry: JsonValue
    public let facts: RepoFacts
    public let at: String

    public init(
        ok: Bool, projectId: String, projectName: String, provider: String, aiConfigured: Bool,
        aiError: String, highlights: ArrayList<String>, docChanges: ArrayList<(String, Bool, Bool, String)>,
        journalEntry: JsonValue, facts: RepoFacts, at: String,
    ) {
        this.ok = ok
        this.projectId = projectId
        this.projectName = projectName
        this.provider = provider
        this.aiConfigured = aiConfigured
        this.aiError = aiError
        this.highlights = highlights
        this.docChanges = docChanges
        this.journalEntry = journalEntry
        this.facts = facts
        this.at = at
    }
}

public func runDeep(project: ProjectEntry, config: Config, opts: DeepOptions): DeepResult {
    let store = ensureStore(project.id)
    let lockFile = "${store.locks}/deep.lock"
    let startedAt = nowIso()

    return withLock(lockFile, 900000, { =>
        Log.step("深度采集仓库全量事实：${project.name}")
        let facts = collectFacts(project.path, project.kind, config, 60, true)
        var progress = readProgress(project.id)

        let ai = resolveAi(config)
        var provider = "rules"
        var aiError = ""
        var highlights = ArrayList<String>()

        // 章节内容（先填规则兜底）
        let (fbOverview, fbHistory, fbArch, fbCmds) = rulesDeepSections(facts, progress, config.language)
        var readmeOverview = fbOverview
        var readmeHistory = fbHistory
        var agentOverview = fbOverview
        var agentArch = fbArch
        var agentCmds = fbCmds

        if (ai.configured) {
            Log.step("调用 AI 生成深度文档（${ai.model}）")
            var factsJson = facts.toJson()
            let maxInput = if (config.aiMaxInputChars > 60000) { config.aiMaxInputChars - 15000 } else { config.aiMaxInputChars }
            let (fitted, fitNotes) = fitFactsJson(factsJson, maxInput, true)
            if (fitNotes.size > 0) {
                Log.debug("提示词裁剪：${joinStrings(fitNotes, "；")}")
            }
            let digest = buildHistoryDigest(facts)
            let (system, user) = buildDeepPrompt(facts, progress, opts.scope, config.language, digest)
            // 用裁剪后的事实替换提示词中的完整事实
            let userFitted = replaceFactsInPrompt(user, Json.pretty(fitted))
            match (aiChatJson(ai, system, userFitted, "")) {
                case Some(j) =>
                    provider = ai.label()
                    let readmePart = Json.getOr(j, "readme")
                    let agentPart = Json.getOr(j, "agent")
                    readmeOverview = pickSection(Json.strAt(readmePart, "overview", ""), fbOverview)
                    readmeHistory = pickSection(Json.strAt(readmePart, "history", ""), fbHistory)
                    agentOverview = pickSection(Json.strAt(agentPart, "overview", ""), fbOverview)
                    agentArch = pickSection(Json.strAt(agentPart, "architecture", ""), fbArch)
                    agentCmds = pickSection(Json.strAt(agentPart, "commands", ""), fbCmds)
                    let hl = Json.strArrAt(j, "highlights")
                    var i: Int64 = 0
                    for (h in hl) {
                        if (i >= 6) {
                            break
                        }
                        highlights.add(oneLine(h))
                        i += 1
                    }
                case None =>
                    aiError = "AI 返回无法解析为 JSON"
                    Log.warn("AI 深度生成失败，回退规则渲染：${aiError}")
            }
        } else {
            Log.info(ai.reason)
        }

        // 进度区域也刷新（deep 隐含 shallow）
        let progressReadme = renderProgressReadme(
            facts, progress, HashMap<String, BranchNarrative>(),
            config.language, "deep", startedAt, config.maxShallowBranches,
        )
        let progressAgent = renderProgressAgent(
            facts, progress, HashMap<String, BranchNarrative>(),
            config.language, "deep", startedAt,
        )

        // 组装目标文档
        let targets = ArrayList<(String, ArrayList<(String, String)>, String)>()
        var hasReadme = false
        for (f in facts.docsPresent) {
            if (f.toAsciiLower() == "readme.md") {
                hasReadme = true
            }
        }
        if (opts.scope != "agent" && hasReadme) {
            let regions = ArrayList<(String, String)>()
            regions.add(("overview", readmeOverview))
            regions.add(("progress", progressReadme))
            regions.add(("history", readmeHistory))
            targets.add(("README.md", regions, "# ${facts.name}\n\n"))
        }
        if (opts.scope != "readme") {
            for (f in config.agentDocCandidates) {
                var present = false
                for (d in facts.docsPresent) {
                    if (d == f) {
                        present = true
                    }
                }
                if (present) {
                    let regions = ArrayList<(String, String)>()
                    regions.add(("overview", agentOverview))
                    regions.add(("architecture", agentArch))
                    regions.add(("commands", agentCmds))
                    regions.add(("progress", progressAgent))
                    targets.add((f, regions, ""))
                }
            }
        }

        if (targets.size == 0) {
            Log.warn("没有找到可更新的文档（README.md / AGENTS.md / CLAUDE.md）")
        }

        // 写入
        let docChanges = ArrayList<(String, Bool, Bool, String)>()
        for ((file, regions, template) in targets) {
            let fullPath = "${project.path}/${file}"
            if (opts.dryRun) {
                let preview = renderPreview(regions)
                docChanges.add((file, true, false, preview))
                continue
            }
            let backupDir = "${store.backups}/${file.replace("/", "_")}"
            let res = applyRegions(fullPath, regions, backupDir, template)
            docChanges.add((file, res.changed, res.created, ""))
            if (res.changed) {
                Log.ok("已更新 ${file}${if (res.created) { "（新建）" } else { "" }}")
            } else {
                Log.info("${file} 无变化")
            }
        }

        // 日志
        let entry = Json.obj()
        Json.set(entry, "id", Json.of(randomId("j")))
        Json.set(entry, "at", Json.of(startedAt))
        Json.set(entry, "project", Json.of(project.name))
        Json.set(entry, "projectId", Json.of(project.id))
        Json.set(entry, "branch", Json.of(if (facts.currentBranch.size > 0) { facts.currentBranch } else { "" }))
        Json.set(entry, "mode", Json.of("deep"))
        Json.set(entry, "source", Json.of(opts.source))
        Json.set(entry, "provider", Json.of(provider))
        Json.set(entry, "commitCount", Json.of(facts.commitCount))
        let summary = if (highlights.size > 0) {
            highlights[0]
        } else {
            "深度更新 ${joinStrings(targetFiles(targets), "、")}（基于 ${facts.commitCount} 个提交）"
        }
        Json.set(entry, "summary", Json.of(summary))
        let hlJson = ArrayList<JsonValue>()
        for (h in highlights) {
            hlJson.add(Json.of(h))
        }
        Json.set(entry, "highlights", JArr(hlJson))
        let docsJson = ArrayList<JsonValue>()
        for (f in targetFiles(targets)) {
            docsJson.add(Json.of(f))
        }
        Json.set(entry, "docs", JArr(docsJson))

        if (!opts.dryRun) {
            Json.set(progress, "lastDeepAt", Json.of(startedAt))
            let entries = Json.arrAt(progress, "entries")
            entries.add(entry)
            Json.set(progress, "entries", JArr(entries))
            writeProgress(project.id, progress)
            appendJournal(project.id, entry, project.name)
            var state = readState(project.id)
            Json.set(state, "lastDeepAt", Json.of(startedAt))
            Json.set(state, "lastUpdateAt", Json.of(startedAt))
            Json.set(state, "runCount", Json.of(Json.intAt(state, "runCount", 0) + 1))
            writeState(project.id, state)
            for ((file, _, _, _) in docChanges) {
                pruneBackups("${store.backups}/${file.replace("/", "_")}", config.backupKeep)
            }
        }

        return DeepResult(
            true, project.id, project.name, provider, ai.configured, aiError,
            highlights, docChanges, entry, facts, startedAt,
        )
    })
}

func pickSection(primary: String, fallback: String): String {
    let trimmed = primary.trimAscii()
    if (trimmed.size > 40) {
        return tidyMarkdown(trimmed)
    }
    return fallback
}

func targetFiles(targets: ArrayList<(String, ArrayList<(String, String)>, String)>): ArrayList<String> {
    let out = ArrayList<String>()
    for ((f, _, _) in targets) {
        out.add(f)
    }
    return out
}

func renderPreview(regions: ArrayList<(String, String)>): String {
    let sb = StringBuilder()
    for ((name, content) in regions) {
        sb.append("<!-- ${name} -->\n")
        sb.append(truncateChars(content, 400))
        sb.append("\n\n")
    }
    return sb.toString()
}

/// 把提示词中的完整事实 JSON 替换为裁剪版（避免重复序列化两遍）
func replaceFactsInPrompt(user: String, fittedJson: String): String {
    let open = "## 仓库事实（JSON）\n```json\n"
    let startIdx = user.indexOf(open)
    match (startIdx) {
        case None => return user
        case Some(si) =>
            let contentStart = si + open.size
            let closeIdx = user.indexOf("\n```", contentStart)
            match (closeIdx) {
                case None => return user
                case Some(ci) =>
                    return user[..contentStart] + fittedJson + user[ci..]
            }
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testRunDeepOnRealRepo(): Unit {
    let base = "/tmp/deepgit-deep-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/README.md", "# proj\n\n用户手写开头\n")
    writeFileAtomic(base + "/AGENTS.md", "# Agent 指南\n\n用户手写 agent 内容\n")
    writeFileAtomic(base + "/cjpm.toml", "[package]\nname=\"x\"\nversion=\"1.0.0\"")
    writeFileAtomic(base + "/main.cj", "package x")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: initial"], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "tag", "v1.0.0"], true)

    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let opts = DeepOptions()
    let result = runDeep(project, Config.defaults(), opts)

    @Assert(result.ok)
    @Assert(result.facts.kind == "git")

    // README 得到 overview/history/progress 三个区域，用户内容保留
    let readme = readFileTextOr(base + "/README.md", "")
    @Assert(readme.contains("用户手写开头"))
    @Assert(readme.contains("deepgit:begin overview"))
    @Assert(readme.contains("deepgit:begin history"))
    @Assert(readme.contains("deepgit:begin progress"))

    // AGENTS 得到 overview/architecture/commands/progress
    let agents = readFileTextOr(base + "/AGENTS.md", "")
    @Assert(agents.contains("用户手写 agent 内容"))
    @Assert(agents.contains("deepgit:begin architecture"))
    @Assert(agents.contains("deepgit:begin commands"))
    // 事实核对：版本标签应出现在 history
    @Assert(readme.contains("v1.0.0") || agents.contains("v1.0.0"))

    // 幂等：重复执行不产生变化
    let r2 = runDeep(project, Config.defaults(), opts)
    var anyChanged = false
    for ((_, changed, _, _) in r2.docChanges) {
        if (changed) {
            anyChanged = true
        }
    }
    @Assert(!anyChanged)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testRunDeepReadmeOnlyScope(): Unit {
    let base = "/tmp/deepgit-deep2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/README.md", "# x\n")
    writeFileAtomic(base + "/AGENTS.md", "# agents\n")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], true)
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let opts = DeepOptions()
    opts.scope = "readme"
    let result = runDeep(project, Config.defaults(), opts)
    @Assert(result.ok)
    let agents = readFileTextOr(base + "/AGENTS.md", "")
    @Assert(!agents.contains("deepgit:begin"))  // agent 文档未被触碰
    let readme = readFileTextOr(base + "/README.md", "")
    @Assert(readme.contains("deepgit:begin overview"))
    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testRunDeepDryRunWritesNothing(): Unit {
    let base = "/tmp/deepgit-deep3-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/README.md", "# x\n")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], true)
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let opts = DeepOptions()
    opts.dryRun = true
    let result = runDeep(project, Config.defaults(), opts)
    @Assert(result.ok)
    let readme = readFileTextOr(base + "/README.md", "")
    @Assert(!readme.contains("deepgit:begin"))
    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testReplaceFactsInPrompt(): Unit {
    let prompt = "before\n## 仓库事实（JSON）\n```json\n{\"big\":1}\n```\nafter"
    let out = replaceFactsInPrompt(prompt, "{\"small\":2}")
    @Assert(out.contains("{\"small\":2}"))
    @Assert(!out.contains("{\"big\":1}"))
    @Assert(out.contains("before"))
    @Assert(out.contains("after"))
}
