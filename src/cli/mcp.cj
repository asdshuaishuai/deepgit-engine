// MCP 服务器：把引擎暴露为 Model Context Protocol 工具服务器（stdio，JSON-RPC 2.0）。
//
// 设计：
// - 单行 JSON 进、单行 JSON 出（stdout 专用；日志恒走 stderr 不污染协议）
// - 工具直接调 flow/kernel 层函数（进程内），与 HTTP API 同源同权
// - 无状态：除显式写操作外全部只读；写操作走与 CLI 相同的锁与白名单
// - AI 无关：MCP 只暴露事实与动作，供任何 MCP 宿主（Claude/其它 agent）消费
package deepgit.cli

import std.collection.*
import std.console.*
import std.convert.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.flow.*
import deepgit.kernel.*
import deepgit.util.*

// ------------------------------ 工具清单 ------------------------------

func mcpSchemaObject(properties: Array<(String, String, String)>, required: Array<String>): JsonValue {
    // (name, type, description)
    let props = Json.obj()
    for ((n, t, d) in properties) {
        let p = Json.obj()
        Json.set(p, "type", Json.of(t))
        Json.set(p, "description", Json.of(d))
        Json.set(props, n, p)
    }
    let o = Json.obj()
    Json.set(o, "type", Json.of("object"))
    Json.set(o, "properties", props)
    let req = ArrayList<JsonValue>()
    for (r in required) {
        req.add(Json.of(r))
    }
    Json.set(o, "required", JArr(req))
    return o
}

func mcpTool(name: String, desc: String, schema: JsonValue): JsonValue {
    let t = Json.obj()
    Json.set(t, "name", Json.of(name))
    Json.set(t, "description", Json.of(desc))
    Json.set(t, "inputSchema", schema)
    return t
}

/// MCP 工具全集（与 /api/tools 同源能力，进程内直连）
public func mcpToolList(): JsonValue {
    let arr = ArrayList<JsonValue>()
    arr.add(mcpTool("list_projects", "列出全部已注册项目及一句话现状", mcpSchemaObject([], [])))
    arr.add(mcpTool("get_group_context", "整个项目群的 markdown 事实上下文（总览/脉搏/分支/待合入）。budget=字符预算", mcpSchemaObject([("budget", "integer", "上下文字符预算，默认 12000")], [])))
    arr.add(mcpTool("get_project_context", "单项目深度上下文（分支进度/脉搏/日志/里程碑）", mcpSchemaObject([("name", "string", "项目名或 ID"), ("budget", "integer", "字符预算")], ["name"])))
    arr.add(mcpTool("get_project_status", "单项目完整状态 JSON（分支/提交构成/合入建议）", mcpSchemaObject([("name", "string", "项目名或 ID")], ["name"])))
    arr.add(mcpTool("get_dashboard", "跨项目聚合仪表盘（活跃度/里程碑/语言分布）", mcpSchemaObject([], [])))
    arr.add(mcpTool("get_project_docs", "读取项目 README/AGENTS/CLAUDE 原文", mcpSchemaObject([("name", "string", "项目名或 ID")], ["name"])))
    arr.add(mcpTool("get_journal", "读取项目进度日志", mcpSchemaObject([("name", "string", "项目名或 ID"), ("limit", "integer", "条数，默认 8")], ["name"])))
    arr.add(mcpTool("run_shallow_update", "浅更新：记录各分支进度并刷新文档托管区域", mcpSchemaObject([("name", "string", "项目名或 ID，缺省=全部项目")], [])))
    arr.add(mcpTool("run_deep_update", "深度更新：重写 overview/architecture/commands/history", mcpSchemaObject([("name", "string", "项目名或 ID"), ("scope", "string", "all|readme|agent")], [])))
    arr.add(mcpTool("run_track", "进度快照：只写进度库不动文档", mcpSchemaObject([("name", "string", "项目名或 ID")], ["name"])))
    arr.add(mcpTool("git_op", "面板级 git 操作（白名单：pull/push/commit/stash/unstash/fetch）", mcpSchemaObject([("name", "string", "项目名或 ID"), ("op", "string", "pull|push|commit|stash|unstash|fetch"), ("message", "string", "commit 时的提交信息")], ["name", "op"])))
    arr.add(mcpTool("list_milestones", "列出全部里程碑及 git 感知进度", mcpSchemaObject([], [])))
    arr.add(mcpTool("milestone_add", "新增里程碑（tag 存在即自动达成）", mcpSchemaObject([("project", "string", "项目名或 ID"), ("name", "string", "里程碑名"), ("tag", "string", "绑定 tag"), ("target_date", "string", "YYYY-MM-DD"), ("description", "string", "描述")], ["project", "name"])))
    arr.add(mcpTool("milestone_action", "里程碑状态操作", mcpSchemaObject([("project", "string", "项目名或 ID"), ("name", "string", "里程碑名"), ("action", "string", "done|open|drop|remove")], ["project", "name", "action"])))
    arr.add(mcpTool("add_project", "注册一个项目目录", mcpSchemaObject([("path", "string", "项目绝对路径"), ("name", "string", "项目名（缺省取目录名）")], ["path"])))
    let o = Json.obj()
    Json.set(o, "tools", JArr(arr))
    return o
}

// ------------------------------ 工具执行 ------------------------------

func mcpText(text: String, isError: Bool): JsonValue {
    let content = Json.obj()
    Json.set(content, "type", Json.of("text"))
    Json.set(content, "text", Json.of(text))
    let o = Json.obj()
    Json.set(o, "content", JArr(ArrayList<JsonValue>([content])))
    Json.set(o, "isError", Json.of(isError))
    return o
}

func mcpErr(message: String): JsonValue {
    return mcpText(message, true)
}

/// 解析「项目引用」→ ProjectEntry（空串 = 全部项目场景由调用方处理）
func mcpRequireProject(ref: String): ProjectEntry {
    return requireProject(ref)
}

/// 工具执行：与 HTTP/CLI 同源，进程内直连。
public func mcpCallTool(name: String, args: JsonValue): JsonValue {
    func getStr(key: String): String {
        match (Json.get(args, key)) {
            case Some(v) =>
                match (v) {
                    case JStr(t) => return t
                    case _ => return ""
                }
            case None => return ""
        }
    }
    func getInt(key: String, fallback: Int64): Int64 {
        return Json.intAt(args, key, fallback)
    }
    let config = loadConfig()
    let reg = loadRegistry()

    try {
        match (name) {
            case "list_projects" =>
                let statuses = allProjectStatuses(reg.projects, config, true)
                let lines = ArrayList<String>()
                for (st in statuses) {
                    if (Json.has(st, "error")) {
                        lines.add("${Json.strAt(st, "name", "")}：错误（${Json.strAt(st, "error", "")}）")
                    } else {
                        lines.add("${Json.strAt(st, "name", "")}：${Json.strAt(st, "headline", "")}")
                    }
                }
                return mcpText(joinStrings(lines, "\n"), false)
            case "get_group_context" =>
                return mcpText(buildAgentContext(reg.projects, config, "group", "", getInt("budget", AGENT_DEFAULT_BUDGET)), false)
            case "get_project_context" =>
                return mcpText(buildAgentContext(reg.projects, config, "project", getStr("name"), getInt("budget", AGENT_DEFAULT_BUDGET)), false)
            case "get_project_status" =>
                let p = mcpRequireProject(getStr("name"))
                let st = projectStatus(p, config, 8)
                return mcpText(Json.pretty(st), false)
            case "get_dashboard" =>
                return mcpText(Json.pretty(buildDashboard(reg.projects, config)), false)
            case "get_project_docs" =>
                let p = mcpRequireProject(getStr("name"))
                let docs = readProjectDocs(p.path, config)
                let parts = ArrayList<String>()
                for (d in docs) {
                    parts.add("## ${d.file}\n\n${d.content}")
                }
                return mcpText(if (parts.isEmpty()) { "（该项目没有可读文档）" } else { joinStrings(parts, "\n\n") }, false)
            case "get_journal" =>
                let p = mcpRequireProject(getStr("name"))
                let journal = readJournal(p.id, getInt("limit", 8))
                let lines = ArrayList<String>()
                for (e in journal) {
                    lines.add("[${Json.strAt(e, "at", "")}] ${Json.strAt(e, "mode", "")} · ${Json.strAt(e, "branch", "")}：${Json.strAt(e, "summary", "")}")
                }
                return mcpText(if (lines.isEmpty()) { "（暂无日志）" } else { joinStrings(lines, "\n") }, false)
            case "run_shallow_update" =>
                let refs = getStr("name")
                let targets = ArrayList<ProjectEntry>()
                if (refs.isEmpty()) {
                    for (p in reg.projects) {
                        if (!p.disabled) {
                            targets.add(p)
                        }
                    }
                } else {
                    targets.add(mcpRequireProject(refs))
                }
                let out = ArrayList<String>()
                for (p in targets) {
                    let opts = UpdateOptions()
                    opts.mode = "shallow"
                    opts.source = "mcp"
                    let r = runUpdate(p, config, opts)
                    out.add("${p.name}：${if (r.ok) { "ok，${r.commitCount} 提交" } else { "失败" }}")
                }
                return mcpText(joinStrings(out, "\n"), false)
            case "run_deep_update" =>
                let p = mcpRequireProject(getStr("name"))
                let opts = DeepOptions()
                opts.scope = getStr("scope")
                if (opts.scope.isEmpty()) {
                    opts.scope = "all"
                }
                opts.source = "mcp"
                let r = runDeep(p, config, opts)
                return mcpText("${p.name} 深度更新完成（${r.provider}）", r.ok)
            case "run_track" =>
                let p = mcpRequireProject(getStr("name"))
                let r = runTrack(p, config, "mcp")
                return mcpText("${p.name} 快照完成（${r.commitCount} 提交）", r.ok)
            case "git_op" =>
                let p = mcpRequireProject(getStr("name"))
                let r = runGitOp(p.path, getStr("op"), getStr("message"))
                return mcpText("[${r.op}] ${r.output}", r.ok)
            case "list_milestones" =>
                let ms = buildMilestoneOverview(reg.projects, config)
                return mcpText(Json.pretty(ms), false)
            case "milestone_add" =>
                let p = mcpRequireProject(getStr("project"))
                let (m, created) = addMilestone(p.id, getStr("name"), getStr("description"), getStr("target_date"), getStr("tag"))
                return mcpText(if (created) { "已创建：${m.name}" } else { "已存在：${m.name}" }, false)
            case "milestone_action" =>
                let p = mcpRequireProject(getStr("project"))
                let mn = getStr("name")
                let action = getStr("action")
                if (action == "remove") {
                    return mcpText(if (removeMilestone(p.id, mn)) { "已删除 ${mn}" } else { "未找到 ${mn}" }, false)
                }
                var status = "open"
                if (action == "done") {
                    status = "done"
                } else if (action == "drop") {
                    status = "dropped"
                }
                let ok = setMilestoneStatus(p.id, mn, status)
                return mcpText(if (ok) { "${mn} → ${status}" } else { "未找到 ${mn}" }, false)
            case "add_project" =>
                let path = getStr("path")
                let name = getStr("name")
                let (p, created) = addProject(path, if (name.isEmpty()) { basename(normalizePath(expandHome(path))) } else { name }, ArrayList<String>(), "")
                return mcpText(if (created) { "已注册：${p.name}（${p.path}）" } else { "已存在：${p.name}" }, false)
            case _ =>
                return mcpErr("未知工具：${name}")
        }
    } catch (e: Exception) {
        return mcpErr(e.message)
    }
}

// ------------------------------ JSON-RPC 处理 ------------------------------

/// 处理单条 JSON-RPC 请求，返回响应（通知返回 None）。
public func mcpHandle(req: JsonValue): Option<JsonValue> {
    let method = Json.strAt(req, "method", "")
    let hasId = Json.has(req, "id")
    if (!hasId) {
        return Option<JsonValue>.None  // notification
    }
    let id = Json.getOr(req, "id")

    func respond(result: JsonValue): JsonValue {
        let o = Json.obj()
        Json.set(o, "jsonrpc", Json.of("2.0"))
        Json.set(o, "id", id)
        Json.set(o, "result", result)
        return o
    }
    func respondErr(code: Int64, message: String): JsonValue {
        let errObj = Json.obj()
        Json.set(errObj, "code", Json.of(code))
        Json.set(errObj, "message", Json.of(message))
        let o = Json.obj()
        Json.set(o, "jsonrpc", Json.of("2.0"))
        Json.set(o, "id", id)
        Json.set(o, "error", errObj)
        return o
    }

    match (method) {
        case "initialize" =>
            let server = Json.obj()
            Json.set(server, "name", Json.of("deepgit-engine"))
            Json.set(server, "version", Json.of("0.1.0"))
            let caps = Json.obj()
            let toolsCap = Json.obj()
            Json.set(toolsCap, "listChanged", Json.of(false))
            Json.set(caps, "tools", toolsCap)
            let resCap = Json.obj()
            Json.set(resCap, "subscribe", Json.of(false))
            Json.set(caps, "resources", resCap)
            let result = Json.obj()
            Json.set(result, "protocolVersion", Json.of("2024-11-05"))
            Json.set(result, "capabilities", caps)
            Json.set(result, "serverInfo", server)
            return Some(respond(result))
        case "ping" =>
            return Some(respond(Json.obj()))
        case "tools/list" =>
            return Some(respond(mcpToolList()))
        case "tools/call" =>
            let params = Json.getOr(req, "params")
            let name = Json.strAt(params, "name", "")
            let args = Json.getOr(params, "arguments")
            let result = mcpCallTool(name, args)
            return Some(respond(result))
        case "resources/list" =>
            let reg = loadRegistry()
            let arr = ArrayList<JsonValue>()
            for (p in reg.projects) {
                let r = Json.obj()
                Json.set(r, "uri", Json.of("deepgit://project/${p.id}"))
                Json.set(r, "name", Json.of(p.name))
                Json.set(r, "mimeType", Json.of("application/json"))
                arr.add(r)
            }
            let result = Json.obj()
            Json.set(result, "resources", JArr(arr))
            return Some(respond(result))
        case "resources/read" =>
            let params = Json.getOr(req, "params")
            let uri = Json.strAt(params, "uri", "")
            let prefix = "deepgit://project/"
            if (!uri.startsWith(prefix)) {
                return Some(respondErr(-32602, "未知资源：${uri}"))
            }
            let pid = uri[prefix.size..]
            match (findProjectIn(loadRegistry(), pid)) {
                case Some(p) =>
                    let config = loadConfig()
                    let st = projectStatus(p, config, 8)
                    let result = Json.obj()
                    let contents = Json.obj()
                    Json.set(contents, "uri", Json.of(uri))
                    Json.set(contents, "mimeType", Json.of("application/json"))
                    Json.set(contents, "text", Json.of(Json.pretty(st)))
                    Json.set(result, "contents", JArr(ArrayList<JsonValue>([contents])))
                    return Some(respond(result))
                case None =>
                    return Some(respondErr(-32602, "未找到项目：${pid}"))
            }
        case "prompts/list" =>
            let prompt = Json.obj()
            Json.set(prompt, "name", Json.of("project_brief"))
            Json.set(prompt, "description", Json.of("生成某个项目的现状说明（调用工具收集事实后输出 markdown）"))
            let args = Json.obj()
            let arg = Json.obj()
            Json.set(arg, "description", Json.of("项目名或 ID"))
            Json.set(args, "project", arg)
            Json.set(prompt, "arguments", args)
            let result = Json.obj()
            Json.set(result, "prompts", JArr(ArrayList<JsonValue>([prompt])))
            return Some(respond(result))
        case "prompts/get" =>
            let params = Json.getOr(req, "params")
            let pname = Json.strAt(params, "name", "")
            if (pname != "project_brief") {
                return Some(respondErr(-32602, "未知 prompt：${pname}"))
            }
            let pparams = Json.getOr(params, "arguments")
            let proj = Json.strAt(pparams, "project", "")
            let msg = Json.obj()
            Json.set(msg, "role", Json.of("user"))
            Json.set(msg, "content", Json.of("请生成项目 ${proj} 的现状说明：先用 get_project_context 收集事实，再输出一份 markdown 说明（现状/分支/风险/下一步）。"))
            let result = Json.obj()
            Json.set(result, "messages", JArr(ArrayList<JsonValue>([msg])))
            return Some(respond(result))
        case _ =>
            return Some(respondErr(-32601, "未知方法：${method}"))
    }
}

/// MCP 主循环（stdio：单行 JSON 进 / 单行 JSON 出）
public func mcpRun(): Int64 {
    Log.setQuiet(true)
    while (true) {
        let lineOpt = Console.stdIn.readln()
        match (lineOpt) {
            case Some(raw) =>
                let line = raw.trimAscii()
                if (line.isEmpty()) {
                    continue
                }
                let reqOpt = Json.parse(line)
                match (reqOpt) {
                    case Some(req) =>
                        match (mcpHandle(req)) {
                            case Some(resp) => printOut(Json.compact(resp))
                            case None => ()
                        }
                    case None =>
                        let errObj = Json.obj()
                        Json.set(errObj, "code", Json.of(-32700))
                        Json.set(errObj, "message", Json.of("解析错误"))
                        let o = Json.obj()
                        Json.set(o, "jsonrpc", Json.of("2.0"))
                        Json.set(o, "id", Json.null())
                        Json.set(o, "error", errObj)
                        printOut(Json.compact(o))
                }
            case None => break  // EOF
        }
    }
    return 0
}

// ------------------------------ 测试 ------------------------------

@Test
func testMcpInitializeAndTools(): Unit {
    let req = Json.obj()
    Json.set(req, "jsonrpc", Json.of("2.0"))
    Json.set(req, "id", Json.of(1))
    Json.set(req, "method", Json.of("initialize"))
    let resp = mcpHandle(req)
    @Assert(resp.isSome())
    let r = resp.getOrThrow()
    @Assert(Json.strAt(r, "jsonrpc", "") == "2.0")
    let result = Json.getOr(r, "result")
    @Assert(Json.strAt(result, "protocolVersion", "") == "2024-11-05")

    let req2 = Json.obj()
    Json.set(req2, "id", Json.of(2))
    Json.set(req2, "method", Json.of("tools/list"))
    let resp2 = mcpHandle(req2).getOrThrow()
    let tools = Json.arrAt(Json.getOr(resp2, "result"), "tools")
    @Assert(tools.size >= 14)
}

@Test
func testMcpNotificationReturnsNone(): Unit {
    let req = Json.obj()
    Json.set(req, "method", Json.of("notifications/initialized"))
    @Assert(mcpHandle(req).isNone())
}

@Test
func testMcpUnknownMethod(): Unit {
    let req = Json.obj()
    Json.set(req, "id", Json.of(9))
    Json.set(req, "method", Json.of("nope"))
    let resp = mcpHandle(req).getOrThrow()
    let err = Json.getOr(resp, "error")
    @Assert(Json.intAt(err, "code", 0) == -32601)
}

@Test
func testMcpToolsCallOnTempRepo(): Unit {
    let base = "/tmp/deepgit-mcp-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/a.cj", "1")
    gitRun(base, ["add", "."], true)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: mcp 测试"], true)

    let home = "${base}/home"
    ensureDir(home)
    setVariable("DEEPGIT_HOME", home)
    let (p, created) = addProject(base, "mcp-demo", ArrayList<String>(), "")
    @Assert(created)

    // get_project_status
    let req = Json.obj()
    Json.set(req, "id", Json.of(3))
    Json.set(req, "method", Json.of("tools/call"))
    let params = Json.obj()
    Json.set(params, "name", Json.of("get_project_status"))
    let args = Json.obj()
    Json.set(args, "name", Json.of("mcp-demo"))
    Json.set(params, "arguments", args)
    Json.set(req, "params", params)
    let resp = mcpHandle(req).getOrThrow()
    let result = Json.getOr(resp, "result")
    let contentArr = Json.arrAt(result, "content")
    @Assert(contentArr.size == 1)
    let text = Json.strAt(contentArr[0], "text", "")
    @Assert(text.contains("mcp-demo"))
    @Assert(Json.boolAt(result, "isError", true) == false)

    // milestone roundtrip
    let req2 = Json.obj()
    Json.set(req2, "id", Json.of(4))
    Json.set(req2, "method", Json.of("tools/call"))
    let params2 = Json.obj()
    Json.set(params2, "name", Json.of("milestone_add"))
    let args2 = Json.obj()
    Json.set(args2, "project", Json.of("mcp-demo"))
    Json.set(args2, "name", Json.of("v9.9"))
    Json.set(params2, "arguments", args2)
    Json.set(req2, "params", params2)
    let resp2 = mcpHandle(req2).getOrThrow()
    let text2 = Json.strAt(Json.arrAt(Json.getOr(resp2, "result"), "content")[0], "text", "")
    @Assert(text2.contains("已创建"))

    setVariable("DEEPGIT_HOME", "")
    removePathIfExists(base)
}
