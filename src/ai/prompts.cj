// 提示词构建：事实以 JSON 注入，要求严格 JSON 返回。
package deepgit.ai

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.kernel.*
import deepgit.util.*

public func langLine(lang: String): String {
    if (lang == "en") {
        return "English"
    }
    return "简体中文"
}

public let BRANCH_SCHEMA = """
{
  "branches": {
    "<分支名>": {
      "summary": "一句话说明该分支当前进度（≤60字）",
      "highlights": ["近期关键进展，3-5 条，每条 ≤40字"],
      "nextSteps": ["建议的下一步，1-3 条"],
      "status": "active|idle|stale|merged"
    }
  },
  "overall": { "notes": ["整个项目需要注意的 1-3 条，可为空数组"] }
}"""

public let DEEP_SCHEMA = """
{
  "readme": {
    "overview": "## 项目概览 章节的 Markdown 正文（不含标题行）",
    "history": "## 里程碑与历史 章节的 Markdown 正文（不含标题行）"
  },
  "agent": {
    "overview": "## 项目概览 章节的 Markdown 正文",
    "architecture": "## 架构与目录 章节的 Markdown 正文",
    "commands": "## 常用命令 章节的 Markdown 正文"
  },
  "highlights": ["本次深度更新提炼出的 3-6 条关键结论"]
}"""

func projectHeader(facts: RepoFacts): String {
    let sb = StringBuilder()
    sb.append("- 项目名：${facts.name}\n")
    sb.append("- 类型：${if (facts.kind == "git") { "git 仓库" } else { "普通目录（非 git，降级模式）" }}\n")
    sb.append("- 路径：${facts.path}\n")
    if (facts.remote.size > 0) {
        sb.append("- 远端：${facts.remote}\n")
    }
    if (facts.kind == "git") {
        sb.append("- 当前分支：${facts.currentBranch}（默认分支 ${facts.defaultBranch}）\n")
        sb.append("- 提交总数：${facts.commitCount}；最近提交：${formatDateTime(facts.lastCommitAt)}\n")
    }
    return sb.toString()
}

/// 分支增量事实 → JSON（供提示词）
public func branchDeltasToJson(deltas: ArrayList<BranchDelta>, facts: RepoFacts): JsonValue {
    let o = Json.obj()
    for (d in deltas) {
        let e = Json.obj()
        Json.set(e, "from", Json.of(if (d.from.size == 0) { "(首次记录，无基线)" } else { shortSha(d.from) }))
        Json.set(e, "head", Json.of(shortSha(d.head)))
        Json.set(e, "reset", Json.of(d.reset))
        Json.set(e, "commitCount", Json.of(d.count()))
        Json.set(e, "stats", d.stats.toJson())
        let commits = ArrayList<JsonValue>()
        var i: Int64 = 0
        for (c in d.commits) {
            if (i >= 20) {
                break
            }
            let co = Json.obj()
            Json.set(co, "short", Json.of(c.short))
            Json.set(co, "date", Json.of(formatDateOnly(c.date)))
            Json.set(co, "subject", Json.of(c.subject))
            commits.add(co)
            i += 1
        }
        Json.set(e, "commits", JArr(commits))
        let files = ArrayList<JsonValue>()
        var j: Int64 = 0
        for (f in d.stats.fileList) {
            if (j >= 15) {
                break
            }
            files.add(Json.of(f.path))
            j += 1
        }
        Json.set(e, "changedFiles", JArr(files))
        Json.set(e, "branchHint", Json.of(d.branch))
        Json.set(o, d.branch, e)
    }
    return o
}

/// 浅更新的叙述提示词
public func buildNarrativePrompt(facts: RepoFacts, branchDeltas: JsonValue, lang: String, previousDocs: ArrayList<(String, String)>): (String, String) {
    let system = """
你是 deepGit 的进度记录员，为个人开发者的本地项目群维护"项目进度现状"。
你的职责：
1. 只依据提供的 git 事实（提交历史、分支差异、工作区状态）与文档片段进行总结，不得编造功能、不夸大完成度。
2. 分支名本身往往表达了意图（如 feat/xxx、fix/xxx、docs/xxx），可据此推断该分支在做什么。
3. 对每个分支给出简短、具体、可核对的进度描述；若某分支没有新变化，如实说明"无新提交"。
4. 语言：${langLine(lang)}；术语保留原文（如 commit、branch、README）。
5. 输出严格 JSON，不要 Markdown 代码块，不要多余解释。"""

    let sb = StringBuilder()
    sb.append("## 项目\n")
    sb.append(projectHeader(facts))
    sb.append("\n## 分支事实（JSON）\n```json\n")
    sb.append(Json.pretty(branchDeltas))
    sb.append("\n```\n\n")
    sb.append("## 工作区\n")
    if (facts.dirty.clean) {
        sb.append("- 未提交改动：无\n")
    } else {
        let files = ArrayList<String>()
        var i: Int64 = 0
        for (f in facts.dirty.files) {
            if (i >= 10) {
                break
            }
            files.add(f)
            i += 1
        }
        sb.append("- 未提交改动：${facts.dirty.total} 处：${joinStrings(files, ", ")}\n")
    }
    sb.append("- stash 数量：${facts.stashCount}\n\n")
    sb.append("## 现有文档片段（供风格参考，不要照抄）\n")
    if (previousDocs.size == 0) {
        sb.append("（无）\n")
    } else {
        for ((file, content) in previousDocs) {
            sb.append("### ${file}\n")
            sb.append(truncateChars(content, 1200))
            sb.append("\n\n")
        }
    }
    sb.append("请按以下 JSON 结构输出进度摘要：\n")
    sb.append(BRANCH_SCHEMA)
    return (system, sb.toString())
}

/// 深度更新的提示词
public func buildDeepPrompt(facts: RepoFacts, progress: JsonValue, mode: String, lang: String, historyDigest: String): (String, String) {
    var targetDesc = "本次更新 README 与 AGENT 文档的全部章节。"
    if (mode == "readme") {
        targetDesc = "本次只更新 README.md 的以下章节：overview（项目概览）、history（里程碑与历史）。agent 字段返回空字符串。"
    } else if (mode == "agent") {
        targetDesc = "本次只更新 AGENTS/CLAUDE 文档的以下章节：overview（项目概览）、architecture（架构与目录）、commands（常用命令）。readme 字段返回空字符串。"
    }

    let system = """
你是 deepGit 的文档维护者，为一个已有代码库撰写精炼、诚实、可维护的 README / AGENTS 章节。
硬性要求：
1. 只能依据提供的仓库事实（目录结构、依赖清单、技术栈统计、提交历史、标签、分支进度）撰写；**严禁编造**不存在的功能、命令、性能数据。
2. 不夸大成熟度：没有测试证据就不要声称"生产可用"；不确定的能力写"当前实现情况"。
3. 章节正文使用 Markdown，但**不要重复章节标题**（标题由外层提供），不要使用一级标题 (#)。
4. 条目尽量可核对：命令来自 package.json / 构建清单，版本来自清单或标签。
5. 语言：${langLine(lang)}。
6. 输出严格 JSON（转义换行），不要代码块包裹。
${targetDesc}"""

    let sb = StringBuilder()
    sb.append("## 仓库事实（JSON）\n```json\n")
    sb.append(Json.pretty(facts.toJson()))
    sb.append("\n```\n\n")
    sb.append("## 已记录的分支进度\n```json\n")
    let branches = Json.getOr(progress, "branches")
    sb.append(Json.pretty(branches))
    sb.append("\n```\n\n")
    sb.append("## 提交历史摘要（采样）\n")
    if (historyDigest.size == 0) {
        sb.append("（见上方 recentCommits / oldestCommits）\n")
    } else {
        sb.append(historyDigest)
        sb.append("\n")
    }
    sb.append("\n请输出：\n")
    sb.append(DEEP_SCHEMA)
    return (system, sb.toString())
}

/// 提交历史的文本摘要（供提示词）
public func digestCommits(commits: ArrayList<CommitInfo>, max: Int64, maxChars: Int64): String {
    let sb = StringBuilder()
    var chars: Int64 = 0
    var i: Int64 = 0
    for (c in commits) {
        if (i >= max) {
            break
        }
        let line = "${formatDateOnly(c.date)} ${shortSha(c.sha)} ${oneLine(c.subject)}"
        if (chars + line.size > maxChars) {
            break
        }
        sb.append(line)
        sb.append("\n")
        chars += line.size + 1
        i += 1
    }
    return sb.toString()
}

/// 组装深度更新的历史摘要
public func buildHistoryDigest(facts: RepoFacts): String {
    let sb = StringBuilder()
    if (facts.recentCommits.size > 0) {
        sb.append("### 最近提交\n")
        sb.append(digestCommits(facts.recentCommits, 40, 8000))
    }
    if (facts.oldestCommits.size > 0) {
        sb.append("\n### 最初提交（项目起点）\n")
        sb.append(digestCommits(facts.oldestCommits, 8, 2000))
    }
    if (facts.commitActivity.size > 0) {
        sb.append("\n### 月度提交量\n")
        let parts = ArrayList<String>()
        for ((month, count) in facts.commitActivity) {
            parts.add("${month}: ${count}")
        }
        sb.append(joinStrings(parts, "  "))
        sb.append("\n")
    }
    if (facts.tags.size > 0) {
        sb.append("\n### 标签\n")
        let parts = ArrayList<String>()
        for ((name, date) in facts.tags) {
            parts.add("${name}（${formatDateOnly(date)}）")
        }
        sb.append(joinStrings(parts, ", "))
        sb.append("\n")
    }
    return sb.toString()
}

// ------------------------------ 测试 ------------------------------

@Test
func testBuildNarrativePromptContainsFacts(): Unit {
    let facts = testFacts()
    let deltas = Json.obj()
    let (system, user) = buildNarrativePrompt(facts, deltas, "zh", ArrayList<(String, String)>())
    @Assert(system.contains("进度记录员"))
    @Assert(system.contains("简体中文"))
    @Assert(user.contains("testproj"))
    @Assert(user.contains("分支事实"))
    @Assert(user.contains("branches"))
}

@Test
func testBuildDeepPromptScopeVariants(): Unit {
    let facts = testFacts()
    let progress = Json.obj()
    let (_, u1) = buildDeepPrompt(facts, progress, "readme", "zh", "")
    @Assert(u1.contains("overview"))
    @Assert(u1.contains("history"))
    let (_, u2) = buildDeepPrompt(facts, progress, "agent", "zh", "")
    @Assert(u2.contains("architecture"))
    let (_, u3) = buildDeepPrompt(facts, progress, "all", "en", "")
    @Assert(u3.contains("English") || u3.contains("项目概览"))
}

@Test
func testDigestCommitsRespectsBudget(): Unit {
    let commits = ArrayList<CommitInfo>()
    for (i in 0..100) {
        commits.add(CommitInfo("sha${i}", "s${i}", "a", "e", "2026-09-30T10:00:00+08:00", "subject ${i}", ""))
    }
    let d = digestCommits(commits, 10, 10000)
    let lines = d.trimAscii().split("\n")
    @Assert(lines.size == 10)
}

@Test
func testBranchDeltasToJsonShape(): Unit {
    let facts = testFacts()
    let deltas = ArrayList<BranchDelta>()
    deltas.add(BranchDelta("main", "abcdef1234", "1234567890", false,
        ArrayList<CommitInfo>([CommitInfo("abcdef1234", "abcdef1", "a", "e", "2026-09-30T10:00:00+08:00", "feat: x", "")]),
        DiffStats(2, 10, 3, ArrayList<FileStat>([FileStat("src/a.cj", "M", 10, 3)]))))
    let j = branchDeltasToJson(deltas, facts)
    let mainEntry = Json.getOr(j, "main")
    @Assert(Json.intAt(mainEntry, "commitCount", 0) == 1)
    @Assert(Json.arrAt(mainEntry, "commits").size == 1)
    @Assert(Json.strAt(mainEntry, "head", "") == "abcdef12")
}

@Test
func testLangLine(): Unit {
    @Assert(langLine("zh").contains("简体"))
    @Assert(langLine("en") == "English")
}

func testFacts(): RepoFacts {
    return RepoFacts(
        "git", "testproj", "/tmp/testproj", "git@x:y", "main", "main",
        "abc1234567890", "feat: test", nowIso(), "2026-01-01T00:00:00Z", 10,
        ArrayList<BranchInfo>(), DirtyState(true, 0, 0, 0, 0, 0, ArrayList<String>()), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        5, ArrayList<(String, Int64)>([("Swift", 5)]), ArrayList<String>(["src/ (5)"]),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(["cjpm.toml"]), ArrayList<String>(["README.md"]),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
}
