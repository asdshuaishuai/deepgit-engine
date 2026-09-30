// 本地 HTTP 服务：macOS 客户端 / deepOrca 等宿主适配的统一接口（API-only，无静态页）。
//
// 设计取舍：自研极简 HTTP/1.1 服务端（std.net），只实现 deepGit 需要的部分：
// 固定路由 + 静态文件 + JSON 响应 + CORS（本地开发）。
package deepgit.cli

import std.collection.*
import std.convert.*
import std.net.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.flow.*
import deepgit.kernel.*
import deepgit.util.*

// Web 客户端已移除（macOS 面板是唯一原生客户端）；HTTP 服务只供给 /api/* 与健康检查
let WEB_ROOT_CANDIDATES: Array<String> = []

public func cmdServe(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let config = loadConfig()
    var host = config.serverHost
    var port = config.serverPort
    match (flagValue(rest, "--host")) {
        case Some(h) => host = h
        case None => ()
    }
    match (flagValue(rest, "--port")) {
        case Some(p) =>
            try {
                port = Int64.parse(p)
            } catch (e: Exception) {
                throw DgError.usage("--port 需要整数")
            }
        case None => ()
    }
    if (port < 1 || port > 65535) {
        throw DgError.usage("端口超出范围：${port}")
    }
    let openBrowser = hasFlag(rest, "--open")

    let server = TcpServerSocket(bindAt: UInt16(port))
    server.reuseAddress = true
    server.bind()
    let url = "http://${host}:${port}/"
    Log.ok("deepGit 服务已启动：${url}")
    Log.info("  API：${url}api/status")
    Log.info("  按 Ctrl+C 停止")
    if (openBrowser) {
        let r = execCapture("open", [url], None, 8000)
        if (!r.ok()) {
            Log.debug("自动打开浏览器失败，请手动访问 ${url}")
        }
    }

    let webRoot = findWebRoot()

    while (true) {
        var conn: Option<TcpSocket> = None
        try {
            let socket = server.accept()
            conn = Some(socket)
        } catch (e: Exception) {
            Log.error("accept 失败：${e.message}")
            continue
        }
        match (conn) {
            case Some(socket) =>
                // 串行处理，保证终端下行为可预测（本地单用户场景）
                try {
                    handleConnection(socket, webRoot, config)
                } catch (e: Exception) {
                    Log.debug("连接处理异常：${e.message}")
                }
                try {
                    socket.close()
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
    }
    return 0
}

func findWebRoot(): String {
    for (c in WEB_ROOT_CANDIDATES) {
        if (isDirectoryPath("${c}/assets")) {
            return c
        }
    }
    return ""
}

class HttpRequest {
    public let method: String
    public let path: String
    public let query: String
    public let headers: HashMap<String, String>
    public let body: String

    public init(method: String, path: String, query: String, headers: HashMap<String, String>, body: String) {
        this.method = method
        this.path = path
        this.query = query
        this.headers = headers
        this.body = body
    }

    public func param(name: String): String {
        if (this.query.size == 0) {
            return ""
        }
        for (pair in this.query.split("&")) {
            let eq = pair.indexOf("=")
            match (eq) {
                case Some(i) =>
                    let k = pair[..i]
                    if (k == name) {
                        return urlDecode(pair[i + 1..])
                    }
                case None => ()
            }
        }
        return ""
    }
}

func readRequest(socket: TcpSocket): Option<HttpRequest> {
    socket.readTimeout = Duration.second * 10
    let buf = Array<Byte>(8192, repeat: 0u8)
    var raw = ArrayList<UInt8>()
    var headerEnd: Int64 = -1
    // 读 header
    while (headerEnd < 0 && raw.size < 65536) {
        let n = socket.read(buf)
        if (n <= 0) {
            return None
        }
        for (i in 0..n) {
            raw.add(buf[i])
        }
        headerEnd = findHeaderEnd(raw)
    }
    if (headerEnd < 0) {
        return None
    }
    let headerText = fromUtf8Lossy(raw[..headerEnd].toArray())
    let lines = headerText.split("\r\n")
    if (lines.size == 0) {
        return None
    }
    let requestLine = lines[0]
    let parts = requestLine.split(" ")
    if (parts.size < 2) {
        return None
    }
    let method = parts[0]
    var fullPath = parts[1]
    var path = fullPath
    var query = ""
    let qIdx = fullPath.indexOf("?")
    match (qIdx) {
        case Some(i) =>
            path = fullPath[..i]
            query = fullPath[i + 1..]
        case None => ()
    }

    let headers = HashMap<String, String>()
    for (i in 1..lines.size) {
        let line = lines[i]
        if (line.size == 0) {
            continue
        }
        let colon = line.indexOf(":")
        match (colon) {
            case Some(ci) =>
                let k = line[..ci].trimAscii().toAsciiLower()
                let v = line[ci + 1..].trimAscii()
                headers[k] = v
            case None => ()
        }
    }

    // 读 body（Content-Length）
    var bodyText = ""
    let contentLength = match (headers.get("content-length")) {
        case Some(v) =>
            try {
                Int64.parse(v)
            } catch (e: Exception) {
                0
            }
        case None => 0
    }
    if (contentLength > 1048576) {
        // API 全部是小 JSON：超 1MB 直接拒绝（防 Content-Length OOM 杀进程）
        return None
    }
    if (contentLength > 0) {
        var bodyBytes = ArrayList<UInt8>()
        let already = raw.size - (headerEnd + 4)
        var have: Int64 = 0
        if (already > 0) {
            var i: Int64 = 0
            while (i < already && have < contentLength) {
                bodyBytes.add(raw[headerEnd + 4 + i])
                have += 1
                i += 1
            }
        }
        while (have < contentLength) {
            let n = socket.read(buf)
            if (n <= 0) {
                break
            }
            var i: Int64 = 0
            while (i < n && have < contentLength) {
                bodyBytes.add(buf[i])
                have += 1
                i += 1
            }
        }
        bodyText = fromUtf8Lossy(bodyBytes.toArray())
    }

    return Some(HttpRequest(method, path, query, headers, bodyText))
}

func findHeaderEnd(raw: ArrayList<UInt8>): Int64 {
    if (raw.size < 4) {
        return -1
    }
    var i: Int64 = 0
    while (i + 3 < raw.size) {
        if (raw[i] == 0x0du8 && raw[i + 1] == 0x0au8 && raw[i + 2] == 0x0du8 && raw[i + 3] == 0x0au8) {
            return i
        }
        i += 1
    }
    return -1
}

func handleConnection(socket: TcpSocket, webRoot: String, config: Config): Unit {
    match (readRequest(socket)) {
        case None =>
            writeResponse(socket, 400, "application/json", "{\"error\":\"bad request\"}", true, "")
        case Some(req) =>
            // 本地单用户服务：Host 主机名必须是回环（挡 LAN 直连、DNS rebinding、浏览器跨源）。
            // 端口宽松：serve 可用 --port 覆盖 config.serverPort，Host 端口必然是实际监听端口
            let hostOpt = req.headers.get("host")
            let hostFull = match (hostOpt) {
                case Some(h) => h.toAsciiLower()
                case None => ""
            }
            var host = hostFull
            if (host.startsWith("[")) {
                // IPv6 [::1]:port
                let closeIdx = host.indexOf("]")
                if (closeIdx.isSome()) {
                    host = host[..closeIdx.getOrThrow() + 1]
                }
            } else {
                let colon = host.indexOf(":")
                if (colon.isSome()) {
                    host = host[..colon.getOrThrow()]
                }
            }
            let allowed = host.isEmpty() || host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1"
            if (!allowed) {
                writeResponse(socket, 403, "application/json", "{\"error\":\"forbidden host\"}", false, "")
                return
            }
            // 浏览器驱动写操作防御：本机 CLI 子进程不发 Origin 头；
            // 网页跨源 fetch 必带 Origin（text/plain 简单请求可绕预检，必须在这里拦）
            if (req.method == "POST") {
                let originOpt = req.headers.get("origin")
                match (originOpt) {
                    case Some(o) =>
                        if (o != "") {
                            writeResponse(socket, 403, "application/json", "{\"error\":\"cross-origin blocked\"}", false, "")
                            return
                        }
                    case None => ()
                }
            }
            route(socket, req, webRoot, config)
    }
}

func route(socket: TcpSocket, req: HttpRequest, webRoot: String, config: Config): Unit {
    let path = req.path
    // API 路由
    if (path.startsWith("/api/")) {
        handleApi(socket, req, config)
        return
    }
    // 静态文件
    if (webRoot.size == 0) {
        writeResponse(socket, 200, "text/plain; charset=utf-8", "deepGit 服务运行中（API-only）。接口见 /api/status", true, "")
        return
    }
    var rel = if (path == "/" || path.size == 0) { "index.html" } else { trimLeftSlashes(path) }
    // 防目录穿越与绝对路径注入：含 .. 段或控制字符一律拒绝
    if (rel.contains("..") || rel.contains("\u{0}")) {
        writeResponse(socket, 403, "text/plain; charset=utf-8", "forbidden", true, "")
        return
    }
    for (seg in rel.split("/")) {
        if (seg == "..") {
            writeResponse(socket, 403, "text/plain; charset=utf-8", "forbidden", true, "")
            return
        }
    }
    let full = "${webRoot}/${rel}"
    if (!fileExists(full)) {
        // SPA 回退
        let indexPath = "${webRoot}/index.html"
        match (readFileText(indexPath)) {
            case Some(html) =>
                writeResponse(socket, 200, "text/html; charset=utf-8", html, true, "")
            case None =>
                writeResponse(socket, 404, "text/plain", "not found", true, "")
        }
        return
    }
    match (readFileText(full)) {
        case Some(content) =>
            writeResponse(socket, 200, contentTypeOf(full), content, true, "")
        case None =>
            writeResponse(socket, 500, "text/plain", "read error", true, "")
    }
}

/// 路径穿越判定：任一段为 ".." 即视为穿越（"a..b" 这类合法文件名不受影响）
public func containsTraversal(rel: String): Bool {
    for (seg in rel.split("/")) {
        if (seg == "..") {
            return true
        }
    }
    return rel.contains("\u{0}")
}

func trimLeftSlashes(s: String): String {
    var i: Int64 = 0
    while (i < s.size && s[i] == 0x2fu8) {
        i += 1
    }
    return s[i..]
}

func contentTypeOf(file: String): String {
    let f = file.toAsciiLower()
    if (f.endsWith(".html")) {
        return "text/html; charset=utf-8"
    }
    if (f.endsWith(".js")) {
        return "application/javascript; charset=utf-8"
    }
    if (f.endsWith(".css")) {
        return "text/css; charset=utf-8"
    }
    if (f.endsWith(".json")) {
        return "application/json; charset=utf-8"
    }
    if (f.endsWith(".svg")) {
        return "image/svg+xml"
    }
    return "text/plain; charset=utf-8"
}

func handleApi(socket: TcpSocket, req: HttpRequest, config: Config): Unit {
    let path = req.path
    let method = req.method

    // GET /api/health
    if (path == "/api/health") {
        let o = Json.obj()
        Json.set(o, "ok", Json.of(true))
        Json.set(o, "engine", Json.of("deepGit"))
        Json.set(o, "version", Json.of("0.1.0"))
        Json.set(o, "time", Json.of(nowIso()))
        sendJson(socket, 200, o)
        return
    }

    // GET /api/projects
    if (path == "/api/projects") {
        let reg = loadRegistry()
        let arr = ArrayList<JsonValue>()
        for (p in reg.projects) {
            arr.add(p.toJson())
        }
        let o = Json.obj()
        Json.set(o, "projects", JArr(arr))
        Json.set(o, "count", Json.of(arr.size))
        sendJson(socket, 200, o)
        return
    }

    // GET /api/status?name=&light=1
    if (path == "/api/status") {
        let name = req.param("name")
        let light = req.param("light") == "1"
        let reg = loadRegistry()
        var targets = ArrayList<ProjectEntry>()
        if (name.size > 0) {
            match (findProjectIn(reg, name)) {
                case Some(p) => targets.add(p)
                case None =>
                    sendJson(socket, 404, errJson("PROJECT_NOT_FOUND", "未找到项目：${name}"))
                    return
            }
        } else {
            for (p in reg.projects) {
                if (!p.disabled) {
                    targets.add(p)
                }
            }
        }
        let statuses = allProjectStatuses(targets, config, light)
        if (name.size > 0 && statuses.size == 1) {
            sendJson(socket, 200, statuses[0])
            return
        }
        let o = Json.obj()
        Json.set(o, "projects", JArr(statuses))
        Json.set(o, "summary", groupSummary(statuses, config))
        Json.set(o, "language", Json.of(config.language))
        sendJson(socket, 200, o)
        return
    }

    // GET /api/journal?name=&branch=&limit=
    if (path == "/api/journal") {
        let name = req.param("name")
        match (findProject(name)) {
            case Some(p) =>
                let limit = parseInt(req.param("limit"), 30)
                let entries = readJournal(p.id, limit)
                let branch = req.param("branch")
                let arr = ArrayList<JsonValue>()
                for (e in entries) {
                    if (branch.size == 0 || Json.strAt(e, "branch", "") == branch) {
                        arr.add(e)
                    }
                }
                let o = Json.obj()
                Json.set(o, "project", Json.of(p.name))
                Json.set(o, "entries", JArr(arr))
                sendJson(socket, 200, o)
            case None =>
                sendJson(socket, 404, errJson("PROJECT_NOT_FOUND", "未找到项目：${name}"))
        }
        return
    }

    // GET /api/config
    if (path == "/api/config") {
        sendJson(socket, 200, configToJson(config))
        return
    }

    // POST /api/update?name=&dryRun=1  （浅更新）
    if (path == "/api/update" && method == "POST") {
        handleMutating(socket, req, config, "shallow")
        return
    }

    // POST /api/deep?name=&scope=  （手动触发深度更新）
    if (path == "/api/deep" && method == "POST") {
        handleMutating(socket, req, config, "deep")
        return
    }

    // POST /api/track?name=
    if (path == "/api/track" && method == "POST") {
        handleMutating(socket, req, config, "track")
        return
    }

    // GET /api/dashboard — 跨项目聚合
    if (path == "/api/dashboard" && method == "GET") {
        let reg = loadRegistry()
        let dash = buildDashboard(reg.projects, config)
        sendJson(socket, 200, dash)
        return
    }

    // GET /api/milestones[?name=] — 里程碑列表（git 感知进度）
    if (path == "/api/milestones" && method == "GET") {
        let reg = loadRegistry()
        let name = req.param("name")
        let projects = ArrayList<ProjectEntry>()
        if (name.size > 0) {
            match (findProjectIn(reg, name)) {
                case Some(p) => projects.add(p)
                case None =>
                    sendJson(socket, 404, errJson("PROJECT_NOT_FOUND", "未找到项目：${name}"))
                    return
            }
        } else {
            for (p in reg.projects) {
                projects.add(p)
            }
        }
        let items = ArrayList<JsonValue>()
        for (p in projects) {
            for (m in milestonesFor(p.id)) {
                let prog = milestoneProgress(m, p.path, "")
                items.add(milestoneJson(p, prog))
            }
        }
        let o = Json.obj()
        Json.set(o, "milestones", JArr(items))
        sendJson(socket, 200, o)
        return
    }

    // POST /api/milestones — 新增 {"project":"...","name":"...","tag":"...","targetDate":"...","description":"..."}
    if (path == "/api/milestones" && method == "POST") {
        var name = ""
        var msName = ""
        var tag = ""
        var targetDate = ""
        var desc = ""
        match (Json.parse(req.body)) {
            case Some(j) =>
                name = Json.strAt(j, "project", "")
                msName = Json.strAt(j, "name", "")
                tag = Json.strAt(j, "tag", "")
                targetDate = Json.strAt(j, "targetDate", "")
                desc = Json.strAt(j, "description", "")
            case None => ()
        }
        if (name.isEmpty() || msName.isEmpty()) {
            sendJson(socket, 400, errJson("BAD_REQUEST", "需要 project 与 name 字段"))
            return
        }
        match (findProjectIn(loadRegistry(), name)) {
            case Some(p) =>
                let (m, created) = addMilestone(p.id, msName, desc, targetDate, tag)
                let o = Json.obj()
                Json.set(o, "created", Json.of(created))
                Json.set(o, "milestone", m.toJson())
                sendJson(socket, 200, o)
            case None =>
                sendJson(socket, 404, errJson("PROJECT_NOT_FOUND", "未找到项目：${name}"))
        }
        return
    }

    // GET /api/context — agent 上下文包（预算内 markdown）。scope=group|project&name=&budget=
    if (path == "/api/context" && method == "GET") {
        let scope = req.param("scope")
        let name = req.param("name")
        var budget = AGENT_DEFAULT_BUDGET
        let budgetStr = req.param("budget")
        if (!budgetStr.isEmpty()) {
            try {
                budget = Int64.parse(budgetStr)
            } catch (e: Exception) {
                budget = AGENT_DEFAULT_BUDGET
            }
            if (budget < 500) {
                budget = 500
            }
            if (budget > 200000) {
                budget = 200000
            }
        }
        let reg = loadRegistry()
        let ctxText = buildAgentContext(reg.projects, config, if (scope.isEmpty()) { "group" } else { scope }, name, budget)
        let o = Json.obj()
        Json.set(o, "scope", Json.of(if (scope.isEmpty()) { "group" } else { scope }))
        Json.set(o, "budget", Json.of(budget))
        Json.set(o, "context", Json.of(ctxText))
        sendJson(socket, 200, o)
        return
    }

    // POST /api/add?path=&name= — 注册单个项目
    if (path == "/api/add" && method == "POST") {
        let addPath = req.param("path")
        if (addPath.isEmpty()) {
            sendJson(socket, 400, errJson("BAD_REQUEST", "需要 path 参数"))
            return
        }
        let name = req.param("name")
        let (p, created) = addProject(addPath, name, ArrayList<String>(), "")
        let o = Json.obj()
        Json.set(o, "created", Json.of(created))
        Json.set(o, "id", Json.of(p.id))
        Json.set(o, "name", Json.of(p.name))
        sendJson(socket, 200, o)
        return
    }

    // POST /api/scan?root=&depth= — 批量扫描并注册
    if (path == "/api/scan" && method == "POST") {
        let root = req.param("root")
        if (root.isEmpty()) {
            sendJson(socket, 400, errJson("BAD_REQUEST", "需要 root 参数"))
            return
        }
        var depth: Int64 = 2
        let depthStr = req.param("depth")
        if (!depthStr.isEmpty()) {
            try {
                depth = Int64.parse(depthStr)
            } catch (e: Exception) {
                depth = 2
            }
        }
        let result = scanRoots(ArrayList<String>([root]), depth, true)
        let config = loadConfig()
        var added: Int64 = 0
        for (c in result.candidates) {
            let (p, created) = addProject(c.path, c.name, ArrayList<String>(), root)
            if (created) {
                added += 1
            }
        }
        let o = Json.obj()
        Json.set(o, "found", Json.of(result.candidates.size))
        Json.set(o, "added", Json.of(added))
        Json.set(o, "dirsVisited", Json.of(result.dirsVisited))
        sendJson(socket, 200, o)
        return
    }

    // GET /api/tools — agent 可执行工具清单
    if (path == "/api/tools" && method == "GET") {
        sendJson(socket, 200, agentToolsManifest())
        return
    }

    // GET /api/docs?name= — 项目文档内容（README / AGENTS / CLAUDE 平铺用）
    if (path == "/api/docs" && method == "GET") {
        let name = req.param("name")
        match (findProjectIn(loadRegistry(), name)) {
            case Some(p) =>
                let docs = readProjectDocs(p.path, config)
                let arr = ArrayList<JsonValue>()
                for (d in docs) {
                    arr.add(d.toJson())
                }
                let o = Json.obj()
                Json.set(o, "project", Json.of(p.name))
                Json.set(o, "docs", JArr(arr))
                sendJson(socket, 200, o)
            case None =>
                sendJson(socket, 404, errJson("PROJECT_NOT_FOUND", "未找到项目：${name}"))
        }
        return
    }

    // POST /api/git — {"project":"...","op":"pull|push|commit|stash|unstash|fetch","message":"..."}
    if (path == "/api/git" && method == "POST") {
        var name = ""
        var op = ""
        var message = ""
        match (Json.parse(req.body)) {
            case Some(j) =>
                name = Json.strAt(j, "project", "")
                op = Json.strAt(j, "op", "")
                message = Json.strAt(j, "message", "")
            case None => ()
        }
        if (name.isEmpty() || op.isEmpty()) {
            sendJson(socket, 400, errJson("BAD_REQUEST", "需要 project 与 op 字段"))
            return
        }
        match (findProjectIn(loadRegistry(), name)) {
            case Some(p) =>
                let r = runGitOp(p.path, op, message)
                let o = r.toJson()
                Json.set(o, "project", Json.of(p.name))
                sendJson(socket, 200, o)
            case None =>
                sendJson(socket, 404, errJson("PROJECT_NOT_FOUND", "未找到项目：${name}"))
        }
        return
    }

    // POST /api/milestones/action — {"project":"...","name":"...","action":"done|open|drop|remove"}
    if (path == "/api/milestones/action" && method == "POST") {
        var name = ""
        var msName = ""
        var action = ""
        match (Json.parse(req.body)) {
            case Some(j) =>
                name = Json.strAt(j, "project", "")
                msName = Json.strAt(j, "name", "")
                action = Json.strAt(j, "action", "")
            case None => ()
        }
        if (name.isEmpty() || msName.isEmpty() || action.isEmpty()) {
            sendJson(socket, 400, errJson("BAD_REQUEST", "需要 project / name / action 字段"))
            return
        }
        if (action != "done" && action != "open" && action != "drop" && action != "remove") {
            sendJson(socket, 400, errJson("BAD_REQUEST", "未知 action：${action}"))
            return
        }
        match (findProjectIn(loadRegistry(), name)) {
            case Some(p) =>
                var ok = false
                if (action == "remove") {
                    ok = removeMilestone(p.id, msName)
                } else {
                    var status = "open"
                    if (action == "done") {
                        status = "done"
                    } else if (action == "drop") {
                        status = "dropped"
                    }
                    ok = setMilestoneStatus(p.id, msName, status)
                }
                if (ok) {
                    let o = Json.obj()
                    Json.set(o, "ok", Json.of(true))
                    sendJson(socket, 200, o)
                } else {
                    sendJson(socket, 404, errJson("NOT_FOUND", "未找到里程碑：${msName}"))
                }
            case None =>
                sendJson(socket, 404, errJson("PROJECT_NOT_FOUND", "未找到项目：${name}"))
        }
        return
    }

    sendJson(socket, 404, errJson("NOT_FOUND", "未知接口：${path}"))
}

func handleMutating(socket: TcpSocket, req: HttpRequest, config: Config, kind: String): Unit {
    // 请求体可带 {"name": "..."}；否则用 query
    var name = req.param("name")
    if (name.size == 0 && req.body.size > 0) {
        match (Json.parse(req.body)) {
            case Some(j) => name = Json.strAt(j, "name", "")
            case None => ()
        }
    }
    let dryRun = req.param("dryRun") == "1"

    let reg = loadRegistry()
    var targets = ArrayList<ProjectEntry>()
    if (name.size > 0) {
        match (findProjectIn(reg, name)) {
            case Some(p) => targets.add(p)
            case None =>
                sendJson(socket, 404, errJson("PROJECT_NOT_FOUND", "未找到项目：${name}"))
                return
        }
    } else {
        for (p in reg.projects) {
            if (!p.disabled) {
                targets.add(p)
            }
        }
    }

    // 并发触发时要快进快出：这里同步执行（本地单用户），但只处理单选项目；
    // 多项目时逐个执行并汇总结果。
    let results = ArrayList<JsonValue>()
    for (p in targets) {
        try {
            match (kind) {
                case "track" =>
                    let r = runTrack(p, config, "api")
                    results.add(updateResultToJson(r))
                case "deep" =>
                    let opts = DeepOptions()
                    opts.scope = if (req.param("scope").size > 0) { req.param("scope") } else { "all" }
                    opts.dryRun = dryRun
                    opts.source = "api"
                    let r = runDeep(p, config, opts)
                    results.add(deepResultToJson(r))
                case _ =>
                    let opts = UpdateOptions()
                    opts.mode = "shallow"
                    opts.dryRun = dryRun
                    opts.source = "api"
                    let r = runUpdate(p, config, opts)
                    results.add(updateResultToJson(r))
            }
        } catch (e: Exception) {
            results.add(chainError("${p.name} 执行失败", e).toJson())
        }
    }
    if (results.size == 1) {
        sendJson(socket, 200, results[0])
    } else {
        let o = Json.obj()
        Json.set(o, "results", JArr(results))
        sendJson(socket, 200, o)
    }
}

func errJson(code: String, message: String): JsonValue {
    let o = Json.obj()
    Json.set(o, "error", Json.of(true))
    Json.set(o, "code", Json.of(code))
    Json.set(o, "message", Json.of(message))
    return o
}

func sendJson(socket: TcpSocket, status: Int64, body: JsonValue): Unit {
    writeResponse(socket, status, "application/json; charset=utf-8", Json.pretty(body), true, "")
}

func writeResponse(socket: TcpSocket, status: Int64, contentType: String, body: String, cors: Bool, extraHeaders: String): Unit {
    let bodyBytes = body.toArray()
    let reason = statusReason(status)
    let sb = StringBuilder()
    sb.append("HTTP/1.1 ${status} ${reason}\r\n")
    sb.append("Content-Type: ${contentType}\r\n")
    sb.append("Content-Length: ${bodyBytes.size}\r\n")
    sb.append("Connection: close\r\n")
    // 安全决策：本地原生客户端（CLI 子进程）不需要 CORS；
    // 开放 ACAO:* 等于让任意网页跨源读写（text/plain 简单请求可绕预检验证写操作）
    if (cors) {
        sb.append("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n")
        sb.append("Access-Control-Allow-Headers: Content-Type\r\n")
    }
    if (extraHeaders.size > 0) {
        sb.append(extraHeaders)
    }
    sb.append("\r\n")
    try {
        socket.write(sb.toString().toArray())
        if (bodyBytes.size > 0) {
            socket.write(bodyBytes)
        }
    } catch (e: Exception) {
        Log.debug("写响应失败：${e.message}")
    }
}

func statusReason(status: Int64): String {
    match (status) {
        case 200 => return "OK"
        case 400 => return "Bad Request"
        case 403 => return "Forbidden"
        case 404 => return "Not Found"
        case 500 => return "Internal Server Error"
        case _ => return "OK"
    }
}

func urlDecode(s: String): String {
    return reDecodeUtf8(s)
}

func reDecodeUtf8(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < bytes.size) {
        let c = bytes[i]
        if (c == 0x25u8 && i + 2 < bytes.size) {
            let hexStr = fromUtf8Lossy(bytes[i + 1..i + 3])
            match (hexToByte(hexStr)) {
                case Some(b) =>
                    out.add(b)
                    i += 3
                case None =>
                    out.add(c)
                    i += 1
            }
        } else if (c == 0x2bu8) {
            out.add(0x20u8)
            i += 1
        } else {
            out.add(c)
            i += 1
        }
    }
    return String.fromUtf8(out.toArray())
}

func hexToByte(hex: String): Option<UInt8> {
    if (hex.size != 2) {
        return None
    }
    let hi = hexVal(hex[0])
    let lo = hexVal(hex[1])
    match ((hi, lo)) {
        case (Some(h), Some(l)) => return Some(UInt8(h * 16 + l))
        case _ => return None
    }
}

func hexVal(c: Byte): Option<Int64> {
    if (c >= 0x30u8 && c <= 0x39u8) {
        return Some(Int64(c - 0x30u8))
    }
    if (c >= 0x61u8 && c <= 0x66u8) {
        return Some(Int64(c - 0x61u8) + 10)
    }
    if (c >= 0x41u8 && c <= 0x46u8) {
        return Some(Int64(c - 0x41u8) + 10)
    }
    return None
}

// ------------------------------ 测试 ------------------------------

@Test
func testUrlDecode(): Unit {
    @Assert(urlDecode("hello") == "hello")
    @Assert(urlDecode("a%20b") == "a b")
    @Assert(urlDecode("a+b") == "a b")
    @Assert(urlDecode("p_abc") == "p_abc")
}

@Test
func testTraversalDetection(): Unit {
    // 该判定被 route() 使用；此处验证判定逻辑本身
    @Assert(containsTraversal("../../../etc/passwd"))
    @Assert(containsTraversal("a/../b"))
    @Assert(!containsTraversal("assets/app.js"))
    @Assert(!containsTraversal("index.html"))
    @Assert(!containsTraversal("a..b/c"))
}

@Test
func testContentTypeOf(): Unit {
    @Assert(contentTypeOf("x.html").startsWith("text/html"))
    @Assert(contentTypeOf("x.js").startsWith("application/javascript"))
    @Assert(contentTypeOf("x.css").startsWith("text/css"))
}

@Test
func testStatusReason(): Unit {
    @Assert(statusReason(200) == "OK")
    @Assert(statusReason(404) == "Not Found")
}

@Test
func testFindHeaderEnd(): Unit {
    let raw = ArrayList<UInt8>()
    for (b in "GET / HTTP/1.1\r\nHost: x\r\n\r\nBODY".toArray()) {
        raw.add(b)
    }
    let idx = findHeaderEnd(raw)
    @Assert(idx == 23)  // "GET / HTTP/1.1\r\nHost: x" 共 23 字节，其后是 \r\n\r\n
}
