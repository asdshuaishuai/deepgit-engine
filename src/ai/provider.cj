// AI provider：通过 curl 子进程访问 OpenAI 兼容 / Anthropic 接口。
//
// 设计取舍：用系统 curl 而非 std.net 手写 TLS —— curl 是 macOS/Linux 自带组件，
// 免去自研 TLS 的巨大复杂度，同时保持「零第三方库依赖」的定位。
package deepgit.ai

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.kernel.*
import deepgit.util.*

public class AiCallResult {
    public let text: String
    public let raw: String

    public init(text: String, raw: String) {
        this.text = text
        this.raw = raw
    }
}

/// 调用 AI（返回文本内容）。失败抛 DgError。
public func aiChat(ai: ResolvedAi, system: String, user: String, jsonMode: Bool): AiCallResult {
    match (ai.kind) {
        case "anthropic" => return callAnthropic(ai, system, user)
        case "openai" => return callOpenAi(ai, system, user, jsonMode)
        case _ => throw DgError("AI_NOT_CONFIGURED", "AI 未配置（kind=${ai.kind}）")
    }
}

func callOpenAi(ai: ResolvedAi, system: String, user: String, jsonMode: Bool): AiCallResult {
    let url = normalizeBase(ai.baseUrl) + "/chat/completions"
    let body = Json.obj()
    Json.set(body, "model", Json.of(ai.model))
    let messages = ArrayList<JsonValue>()
    let sysMsg = Json.obj()
    Json.set(sysMsg, "role", Json.of("system"))
    Json.set(sysMsg, "content", Json.of(system))
    messages.add(sysMsg)
    let userMsg = Json.obj()
    Json.set(userMsg, "role", Json.of("user"))
    Json.set(userMsg, "content", Json.of(user))
    messages.add(userMsg)
    Json.set(body, "messages", JArr(messages))
    Json.set(body, "temperature", Json.of(ai.temperature))
    Json.set(body, "max_tokens", Json.of(ai.maxOutputTokens))
    Json.set(body, "stream", Json.of(false))
    if (jsonMode) {
        let rf = Json.obj()
        Json.set(rf, "type", Json.of("json_object"))
        Json.set(body, "response_format", rf)
    }

    let headers = ["Authorization: Bearer ${ai.apiKey}"]
    let timeoutSec = ai.timeoutMs / 1000
    let (status, respBody, errText) = curlPostJson(url, Json.compact(body), headers, timeoutSec)
    if (status == 0) {
        throw DgError("AI_NETWORK", "无法连接 AI 服务（${url}）：${errText.trimAscii()}")
    }
    if (status == 401 || status == 403) {
        throw DgError("AI_AUTH", "AI 鉴权失败（HTTP ${status}）：请检查 API Key 与 baseUrl")
    }
    if (status >= 400) {
        throw DgError("AI_HTTP", "AI 服务返回 HTTP ${status}", 1, Some(truncateChars(respBody, 600)))
    }
    match (Json.parse(respBody)) {
        case Some(j) =>
            let choices = Json.arrAt(j, "choices")
            if (choices.size == 0) {
                throw DgError("AI_BAD_RESPONSE", "AI 返回格式异常（缺少 choices）", 1, Some(truncateChars(respBody, 400)))
            }
            let msg = Json.getOr(choices[0], "message")
            let content = Json.strAtOpt(msg, "content")
            match (content) {
                case Some(t) => return AiCallResult(t, respBody)
                case None => throw DgError("AI_BAD_RESPONSE", "AI 返回缺少 message.content", 1, Some(truncateChars(respBody, 400)))
            }
        case None =>
            throw DgError("AI_BAD_RESPONSE", "AI 响应不是合法 JSON", 1, Some(truncateChars(respBody, 400)))
    }
}

func callAnthropic(ai: ResolvedAi, system: String, user: String): AiCallResult {
    let url = normalizeBase(ai.baseUrl) + "/v1/messages"
    let body = Json.obj()
    Json.set(body, "model", Json.of(ai.model))
    Json.set(body, "system", Json.of(system))
    let messages = ArrayList<JsonValue>()
    let userMsg = Json.obj()
    Json.set(userMsg, "role", Json.of("user"))
    Json.set(userMsg, "content", Json.of(user))
    messages.add(userMsg)
    Json.set(body, "messages", JArr(messages))
    Json.set(body, "temperature", Json.of(ai.temperature))
    Json.set(body, "max_tokens", Json.of(ai.maxOutputTokens))

    let headers = ["x-api-key: ${ai.apiKey}", "anthropic-version: 2023-06-01"]
    let timeoutSec = ai.timeoutMs / 1000
    let (status, respBody, errText) = curlPostJson(url, Json.compact(body), headers, timeoutSec)
    if (status == 0) {
        throw DgError("AI_NETWORK", "无法连接 AI 服务（${url}）：${errText.trimAscii()}")
    }
    if (status == 401 || status == 403) {
        throw DgError("AI_AUTH", "AI 鉴权失败（HTTP ${status}）：请检查 API Key 与 baseUrl")
    }
    if (status >= 400) {
        throw DgError("AI_HTTP", "AI 服务返回 HTTP ${status}", 1, Some(truncateChars(respBody, 600)))
    }
    match (Json.parse(respBody)) {
        case Some(j) =>
            let content = Json.arrAt(j, "content")
            let sb = StringBuilder()
            for (block in content) {
                if (Json.strAt(block, "type", "") == "text") {
                    sb.append(Json.strAt(block, "text", ""))
                }
            }
            let text = sb.toString()
            if (text.isEmpty()) {
                throw DgError("AI_BAD_RESPONSE", "Anthropic 返回缺少 text 内容", 1, Some(truncateChars(respBody, 400)))
            }
            return AiCallResult(text, respBody)
        case None =>
            throw DgError("AI_BAD_RESPONSE", "AI 响应不是合法 JSON", 1, Some(truncateChars(respBody, 400)))
    }
}

func normalizeBase(baseUrl: String): String {
    var s = baseUrl.trimAscii()
    while (s.endsWith("/")) {
        s = s[..s.size - 1]
    }
    return s
}

/// 调用 AI 并解析为 JSON（自动剥离代码块围栏）
public func aiChatJson(ai: ResolvedAi, system: String, user: String, schemaHint: String): Option<JsonValue> {
    let hint = if (schemaHint.isEmpty()) {
        "只输出 JSON，不要任何解释文字。"
    } else {
        "${schemaHint}\n\n只输出 JSON，不要任何解释文字，不要 Markdown 代码块。"
    }
    let fullUser = "${user}\n\n${hint}"
    let result = aiChat(ai, system, fullUser, true)
    // 先直接解析
    match (Json.parse(result.text.trimAscii())) {
        case Some(j) => return Some(j)
        case None => ()
    }
    // 再尝试剥离围栏
    match (extractJsonBlock(result.text)) {
        case Some(block) =>
            match (Json.parse(block)) {
                case Some(j) => return Some(j)
                case None => return None
            }
        case None => return None
    }
}

/// 估计提示词规模（粗略护栏）
public func estimatePromptChars(system: String, user: String): Int64 {
    return system.size + user.size
}

/// 事实裁剪：按重要性丢弃，控制提示词规模
public func fitFactsJson(factsJson: JsonValue, maxChars: Int64, deep: Bool): (JsonValue, ArrayList<String>) {
    let notes = ArrayList<String>()
    let size = Json.compact(factsJson).size
    if (size <= maxChars) {
        return (factsJson, notes)
    }
    // 逐项裁剪
    let commitsKeep = if (deep) { 60 } else { 25 }
    let rc = Json.arrAt(factsJson, "recentCommits")
    if (rc.size > commitsKeep) {
        let kept = ArrayList<JsonValue>()
        var i: Int64 = 0
        for (c in rc) {
            if (i >= commitsKeep) {
                break
            }
            kept.add(c)
            i += 1
        }
        Json.set(factsJson, "recentCommits", JArr(kept))
        notes.add("recentCommits 截断为 ${commitsKeep} 条")
    }
    let oc = Json.arrAt(factsJson, "oldestCommits")
    if (oc.size > 5) {
        let kept = ArrayList<JsonValue>()
        var i: Int64 = 0
        for (c in oc) {
            if (i >= 5) {
                break
            }
            kept.add(c)
            i += 1
        }
        Json.set(factsJson, "oldestCommits", JArr(kept))
    }
    let structure = Json.strArrAt(factsJson, "structure")
    if (structure.size > 40) {
        let kept = ArrayList<String>()
        var i: Int64 = 0
        for (s in structure) {
            if (i >= 40) {
                break
            }
            kept.add(s)
            i += 1
        }
        Json.set(factsJson, "structure", Json.strArray(kept.toArray()))
        notes.add("structure 截断为 40 行")
    }
    let branches = Json.arrAt(factsJson, "branches")
    if (branches.size > 12) {
        let kept = ArrayList<JsonValue>()
        var i: Int64 = 0
        for (b in branches) {
            if (i >= 12) {
                break
            }
            kept.add(b)
            i += 1
        }
        Json.set(factsJson, "branches", JArr(kept))
    }
    let activity = Json.arrAt(factsJson, "commitActivity")
    if (activity.size > 18) {
        let kept = ArrayList<JsonValue>()
        let start = activity.size - 18
        var i: Int64 = 0
        for (a in activity) {
            if (i >= start) {
                kept.add(a)
            }
            i += 1
        }
        Json.set(factsJson, "commitActivity", JArr(kept))
        notes.add("commitActivity 截断为最近 18 个月")
    }
    return (factsJson, notes)
}

// ------------------------------ 测试 ------------------------------

@Test
func testNormalizeBase(): Unit {
    @Assert(normalizeBase("https://api.x.com/") == "https://api.x.com")
    @Assert(normalizeBase("https://api.x.com") == "https://api.x.com")
    @Assert(normalizeBase("  https://api.x.com//  ") == "https://api.x.com")
}

@Test
func testEstimatePromptChars(): Unit {
    @Assert(estimatePromptChars("abc", "def") == 6)
}

@Test
func testFitFactsTruncatesWhenTooLarge(): Unit {
    let facts = Json.obj()
    let commits = ArrayList<JsonValue>()
    for (i in 0..100) {
        let c = Json.obj()
        Json.set(c, "subject", Json.of("commit number ${i} with a moderately long subject line"))
        commits.add(c)
    }
    Json.set(facts, "recentCommits", JArr(commits))
    let structures = ArrayList<String>()
    for (i in 0..200) {
        structures.add("dir${i}/ (10)")
    }
    Json.set(facts, "structure", Json.strArray(structures.toArray()))
    let (fitted, notes) = fitFactsJson(facts, 2000, false)
    @Assert(Json.arrAt(fitted, "recentCommits").size == 25)
    @Assert(Json.strArrAt(fitted, "structure").size == 40)
    @Assert(notes.size >= 2)
}

@Test
func testFitFactsNoOpWhenSmall(): Unit {
    let facts = Json.obj()
    Json.set(facts, "name", Json.of("x"))
    let (fitted, notes) = fitFactsJson(facts, 100000, false)
    @Assert(notes.size == 0)
    @Assert(Json.strAt(fitted, "name", "") == "x")
}

@Test
func testAiChatRejectsUnconfigured(): Unit {
    let ai = ResolvedAi("rules", false, "test", "custom", "none", "", "", "", None, 0.2, 100, 1000, 0, 1000, 100)
    try {
        aiChat(ai, "sys", "user", false)
        @Assert(false)  // 不应到达
    } catch (e: DgError) {
        @Assert(e.code == "AI_NOT_CONFIGURED")
    }
}
