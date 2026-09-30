// 规则引擎（无 AI 时的降级）：基于提交前缀与分支名的启发式摘要。
package deepgit.ai

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.kernel.*
import deepgit.util.*

let TYPE_PATTERNS: Array<(String, String)> = [
    ("feat", "新增"),
    ("feature", "新增"),
    ("add", "新增"),
    ("fix", "修复"),
    ("bugfix", "修复"),
    ("hotfix", "修复"),
    ("docs", "文档"),
    ("doc", "文档"),
    ("refactor", "重构"),
    ("chore", "构建/依赖"),
    ("build", "构建/依赖"),
    ("deps", "构建/依赖"),
    ("test", "测试"),
    ("perf", "性能"),
    ("style", "样式"),
    ("merge", "合并"),
    ("release", "发版"),
    ("ci", "CI"),
]

/// 中文动词 → 意图（中文项目普遍用描述式提交，需要更宽的匹配）
let CN_KEYWORDS: Array<(Array<String>, String)> = [
    (["收尾", "完成", "实现", "新增", "增加", "支持", "上线", "落地", "接入"], "新增"),
    (["修复", "修正", "解决", "bug", "报错", "崩溃", "crash"], "修复"),
    (["文档", "readme", "注释", "说明", "roadmap", "docs"], "文档"),
    (["重构", "整理", "清理", "抽", "拆分", "迁移"], "重构"),
    (["测试", "test", "断言", "用例", "验收"], "测试"),
    (["性能", "优化", "加速", "缓存"], "性能"),
    (["样式", "格式", "排版", "格式"], "样式"),
    (["构建", "依赖", "升级", "适配", "版本"], "构建/依赖"),
    (["发布", "发版", "release", "tag"], "发版"),
    (["合并", "merge", "同步"], "合并"),
    (["安全", "校验", "guard", "守卫"], "安全"),
    (["界面", "UI", "ui", "布局", "渲染"], "界面"),
]

/// 归类提交意图
public func classifyCommit(subject: String): String {
    let s = oneLine(subject).toAsciiLower()
    for ((prefix, label) in TYPE_PATTERNS) {
        if (s.startsWith(prefix)) {
            return label
        }
    }
    // 中文关键词（在整句任意位置匹配，而不是只看前缀）
    for ((keywords, label) in CN_KEYWORDS) {
        for (kw in keywords) {
            if (s.contains(kw)) {
                return label
            }
        }
    }
    // 无类型信息：用提交尺度判断（短句多为琐碎改动）
    if (oneLine(subject).size <= 6) {
        return "微调"
    }
    return "更新"
}

/// 去掉 conventional commit 前缀，保留可读描述
public func cleanSubject(subject: String): String {
    let s = oneLine(subject)
    // 形如 "feat(scope): message" 或 "fix: message"
    let colon = s.indexOf(":")
    match (colon) {
        case Some(ci) =>
            let head = s[..ci]
            let lower = head.toAsciiLower()
            // 仅当冒号前是 conventional commit 类型标记时才剥离：
            // 全小写、无空格、≤20 字符，且属于已知类型集合
            var isTypeToken = lower.size <= 20 && !lower.contains(" ")
            if (isTypeToken) {
                let base = if (lower.contains("(")) { lower[..indexOfOr(lower, "(")] } else { lower }
                var known = false
                for ((prefix, _) in TYPE_PATTERNS) {
                    if (base == prefix) {
                        known = true
                        break
                    }
                }
                if (!known) {
                    isTypeToken = false
                }
            }
            if (isTypeToken) {
                let rest = s[ci + 1..].trimAscii()
                if (rest.size > 0) {
                    return rest
                }
            }
            return s
        case None => return s
    }
}

func areasOf(stats: DiffStats, top: Int64): ArrayList<String> {
    let names = ArrayList<String>()
    let counts = ArrayList<Int64>()
    for (f in stats.fileList) {
        let seg = if (f.path.contains("/")) { f.path[..indexOfOr(f.path, "/")] } else { "(根目录)" }
        var found = false
        for (i in 0..names.size) {
            if (names[i] == seg) {
                counts[i] = counts[i] + 1
                found = true
                break
            }
        }
        if (!found) {
            names.add(seg)
            counts.add(1)
        }
    }
    // 排序
    let out = ArrayList<String>()
    let idx = ArrayList<Int64>()
    for (i in 0..names.size) {
        idx.add(i)
    }
    var a: Int64 = 1
    while (a < idx.size) {
        let key = idx[a]
        var b = a - 1
        while (b >= 0 && counts[idx[b]] < counts[key]) {
            idx[b + 1] = idx[b]
            b -= 1
        }
        idx[b + 1] = key
        a += 1
    }
    for (i in idx) {
        if (out.size >= top) {
            break
        }
        out.add("${names[i]}（${counts[i]} 文件）")
    }
    return out
}

func indexOfOr(s: String, needle: String): Int64 {
    match (s.indexOf(needle)) {
        case Some(i) => return i
        case None => return 0
    }
}

/// 单个分支的规则化叙述
public func rulesBranchNarrative(delta: BranchDelta, facts: RepoFacts, lang: String): BranchNarrative {
    let zh = lang != "en"
    let commits = delta.commits
    if (commits.size == 0) {
        return BranchNarrative(
            if (zh) { "自上次记录以来 `${delta.branch}` 无新提交" } else { "No new commits on ${delta.branch}" },
            ArrayList<String>(),
            ArrayList<String>(),
            computeBranchStatus(facts.lastCommitAt, false),
        )
    }

    // 归类统计
    let typeNames = ArrayList<String>()
    let typeCounts = ArrayList<Int64>()
    for (c in commits) {
        let t = classifyCommit(c.subject)
        var found = false
        for (i in 0..typeNames.size) {
            if (typeNames[i] == t) {
                typeCounts[i] = typeCounts[i] + 1
                found = true
                break
            }
        }
        if (!found) {
            typeNames.add(t)
            typeCounts.add(1)
        }
    }
    // 排序取前 3
    let ti = ArrayList<Int64>()
    for (i in 0..typeNames.size) {
        ti.add(i)
    }
    var x: Int64 = 1
    while (x < ti.size) {
        let key = ti[x]
        var y = x - 1
        while (y >= 0 && typeCounts[ti[y]] < typeCounts[key]) {
            ti[y + 1] = ti[y]
            y -= 1
        }
        ti[y + 1] = key
        x += 1
    }
    let typeParts = ArrayList<String>()
    for (i in ti) {
        if (typeParts.size >= 3) {
            break
        }
        typeParts.add("${typeNames[i]}×${typeCounts[i]}")
    }
    let typeSummary = joinStrings(typeParts, "、")

    let areas = areasOf(delta.stats, 3)
    let summaryParts = ArrayList<String>()
    if (!delta.from.isEmpty()) {
        summaryParts.add(if (zh) { "新增 ${commits.size} 个提交（${typeSummary}）" } else { "${commits.size} new commits (${typeSummary})" })
    } else {
        summaryParts.add(if (zh) { "最近 ${commits.size} 个提交：${typeSummary}" } else { "latest ${commits.size} commits: ${typeSummary}" })
    }
    if (areas.size > 0) {
        summaryParts.add((if (zh) { "涉及 " } else { "touching " }) + joinStrings(areas, "、"))
    }
    let summary = joinStrings(summaryParts, "，")

    let highlights = ArrayList<String>()
    var i: Int64 = 0
    for (c in commits) {
        if (i >= 5) {
            break
        }
        let clean = cleanSubject(c.subject)
        let text = if (clean.isEmpty()) { c.subject } else { "：“${clean}”" }
        highlights.add(truncate("${classifyCommit(c.subject)}${text}", 60, "…"))
        i += 1
    }

    let nextSteps = ArrayList<String>()
    let st = computeBranchStatus(
        if (commits.size > 0) { commits[0].date } else { facts.lastCommitAt },
        false,
    )
    if (st == "stale") {
        nextSteps.add(if (zh) { "分支已多日无提交，确认是否合并或关闭" } else { "branch is stale — merge or close it" })
    }
    let bn = delta.branch.toAsciiLower()
    if ((bn.startsWith("feat/") || bn.startsWith("fix/") || bn.startsWith("refactor/")) ) {
        nextSteps.add(if (zh) { "推进该分支的收尾与验证，考虑合并回默认分支" } else { "finish and validate, then merge back" })
    }
    if (delta.stats.insertions > 1500) {
        nextSteps.add(if (zh) { "本次改动较大，建议补充测试与文档" } else { "large change — add tests and docs" })
    }

    return BranchNarrative(summary, highlights, nextSteps, st)
}

/// 项目级提醒
public func rulesOverallNotes(facts: RepoFacts, lang: String): ArrayList<String> {
    let zh = lang != "en"
    let notes = ArrayList<String>()
    if (!facts.dirty.clean) {
        // 排除 deepGit 自己维护的文档，避免自引用噪音
        var userDirty: Int64 = 0
        for (f in facts.dirty.files) {
            if (!isManagedDoc(f)) {
                userDirty += 1
            }
        }
        if (userDirty > 0) {
            notes.add(if (zh) {
                "工作区有 ${userDirty} 处未提交改动"
            } else {
                "${userDirty} uncommitted changes"
            })
        }
    }
    if (facts.stashCount > 0) {
        notes.add(if (zh) { "存在 ${facts.stashCount} 条 stash，注意清理" } else { "${facts.stashCount} stashes" })
    }
    for (w in facts.warnings) {
        notes.add(w)
    }
    return notes
}

/// 深度更新兜底章节
public func rulesDeepSections(facts: RepoFacts, progress: JsonValue, lang: String): (String, String, String, String) {
    // 返回 (readmeOverview, readmeHistory, agentArchitecture, agentCommands)
    let overview = renderOverviewFallback(facts, progress, lang)
    let history = renderHistoryFallback(facts, progress, lang)
    let architecture = renderArchitectureFallback(facts, lang)
    let commands = renderCommandsFallback(facts, lang)
    return (overview, history, architecture, commands)
}

// ------------------------------ 测试 ------------------------------

@Test
func testClassifyCommit(): Unit {
    @Assert(classifyCommit("feat: add user login") == "新增")
    @Assert(classifyCommit("fix(ui): correct layout") == "修复")
    @Assert(classifyCommit("docs: update README") == "文档")
    @Assert(classifyCommit("新增登录功能") == "新增")
    @Assert(classifyCommit("修复崩溃问题") == "修复")
    @Assert(classifyCommit("random message") == "更新")
}

@Test
func testClassifyChineseDescriptionCommits(): Unit {
    @Assert(classifyCommit("审查收尾：/W 按 1000/upem 换算") == "新增")
    @Assert(classifyCommit("PDF 规格收尾（P1–P7 完成）+ roadmap 状态同步") == "新增")
    @Assert(classifyCommit("修复 Windows 下路径分隔符问题") == "修复")
    @Assert(classifyCommit("更新 README 说明") == "文档")
    @Assert(classifyCommit("重构渲染管线，抽取图元") == "重构")
    @Assert(classifyCommit("补充验收测试断言") == "测试")
    @Assert(classifyCommit("fix") != "更新")
    @Assert(classifyCommit("wip") != "")
}

@Test
func testCleanSubject(): Unit {
    @Assert(cleanSubject("feat: add user login") == "add user login")
    @Assert(cleanSubject("fix(ui): correct layout") == "correct layout")
    @Assert(cleanSubject("no prefix here") == "no prefix here")
    @Assert(cleanSubject("A: with colon in sentence") == "A: with colon in sentence")
}

@Test
func testRulesBranchNarrativeWithCommits(): Unit {
    let commits = ArrayList<CommitInfo>()
    commits.add(CommitInfo("s1", "s1", "a", "e", nowIso(), "feat: add x", ""))
    commits.add(CommitInfo("s2", "s2", "a", "e", nowIso(), "fix: fix y", ""))
    let delta = BranchDelta("feat/demo", "head1", "base1", false, commits, DiffStats(3, 20, 5, ArrayList<FileStat>([FileStat("src/a.cj", "M", 20, 5)])))
    let facts = testFactsForRules()
    let n = rulesBranchNarrative(delta, facts, "zh")
    @Assert(n.summary.contains("新增"))
    @Assert(n.summary.contains("修复"))
    @Assert(n.highlights.size == 2)
    @Assert(n.status == "active")
}

@Test
func testRulesBranchNarrativeNoCommits(): Unit {
    let delta = BranchDelta("main", "head1", "base1", false, ArrayList<CommitInfo>(), DiffStats(0, 0, 0, ArrayList<FileStat>()))
    let n = rulesBranchNarrative(delta, testFactsForRules(), "zh")
    @Assert(n.summary.contains("无新提交"))
    @Assert(n.highlights.size == 0)
}

@Test
func testRulesOverallNotes(): Unit {
    // 干净仓库：无提醒
    let cleanFacts = testFactsForRules()
    @Assert(rulesOverallNotes(cleanFacts, "zh").size == 0)
    // 脏仓库（含用户文件）：有提醒
    let dirty = RepoFacts(
        "git", "t", "/tmp/t", "", "main", "main", "a", "s", nowIso(), "2026-01-01T00:00:00Z", 1,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 1, 1, 0, 2, ArrayList<String>(["src/a.cj", "README.md"])), 2,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        1, ArrayList<(String, Int64)>(), ArrayList<String>(),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(), ArrayList<String>(),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
    let notes = rulesOverallNotes(dirty, "zh")
    @Assert(notes.size == 2)  // 未提交 + stash
    // 只有托管文档时不算用户改动
    let onlyDocs = RepoFacts(
        "git", "t", "/tmp/t", "", "main", "main", "a", "s", nowIso(), "2026-01-01T00:00:00Z", 1,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 1, 0, 0, 1, ArrayList<String>(["README.md"])), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        1, ArrayList<(String, Int64)>(), ArrayList<String>(),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(), ArrayList<String>(),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
    @Assert(rulesOverallNotes(onlyDocs, "zh").size == 0)
}

@Test
func testRulesDeepSectionsNonEmpty(): Unit {
    let facts = testFactsForRules()
    let (ov, hist, arch, cmd) = rulesDeepSections(facts, Json.obj(), "zh")
    @Assert(ov.contains("项目概览"))
    @Assert(hist.contains("里程碑"))
    @Assert(arch.contains("架构"))
    @Assert(cmd.size > 0)
}

func testFactsForRules(): RepoFacts {
    return RepoFacts(
        "git", "testproj", "/tmp/testproj", "", "feat/demo", "main",
        "abc1234", "feat: x", nowIso(), "2026-01-01T00:00:00Z", 10,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 0, 0, 0, 0, ArrayList<String>()), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        5, ArrayList<(String, Int64)>([("Cangjie", 5)]), ArrayList<String>(["src/ (5)"]),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(["cjpm.toml"]), ArrayList<String>(["README.md"]),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
}
