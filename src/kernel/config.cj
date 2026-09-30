// 配置：默认值 + 文件读写 + 环境变量覆盖 + AI provider 解析。
package deepgit.kernel

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

/// AI provider 预设

/// 生效的 AI 配置（解析后的）

/// 应用配置（带默认值）
public class Config {
    public var language: String = "zh"
    public var roots: ArrayList<String> = ArrayList<String>()
    public var docs: ArrayList<String> = ArrayList<String>(["README.md", "AGENTS.md", "CLAUDE.md"])
    public var agentDocCandidates: ArrayList<String> = ArrayList<String>(["AGENTS.md", "AGENT.md", "CLAUDE.md"])
    public var backupKeep: Int64 = 20
    public var maxShallowBranches: Int64 = 6
    public var hookMode: String = "track"
    public var serverHost: String = "127.0.0.1"
    public var serverPort: Int64 = 5177
    public var aiJsonMode: String = "auto"

    public static func defaults(): Config {
        return Config()
    }
}

public func configPath(): String {
    return deepgitPath(["config.json"])
}

public func registryPath(): String {
    return deepgitPath(["registry.json"])
}

/// 从 JSON 加载配置（缺失字段用默认值）
public func configFromJson(j: JsonValue, base: Config): Config {
    let cfg = Config()
    cfg.language = Json.strAt(j, "language", base.language)
    let roots = Json.strArrAt(j, "roots")
    cfg.roots = if (roots.isEmpty()) { base.roots } else { roots }
    let update = Json.getOr(j, "update")
    let docs = Json.strArrAt(update, "docs")
    cfg.docs = if (docs.isEmpty()) { base.docs } else { docs }
    let agentDocs = Json.strArrAt(update, "agentDocCandidates")
    cfg.agentDocCandidates = if (agentDocs.isEmpty()) { base.agentDocCandidates } else { agentDocs }
    cfg.backupKeep = Json.intAt(update, "backupKeep", base.backupKeep)
    cfg.maxShallowBranches = Json.intAt(update, "maxShallowBranches", base.maxShallowBranches)
    let hooks = Json.getOr(j, "hooks")
    cfg.hookMode = Json.strAt(hooks, "mode", base.hookMode)
    let server = Json.getOr(j, "server")
    cfg.serverHost = Json.strAt(server, "host", base.serverHost)
    cfg.serverPort = Json.intAt(server, "port", base.serverPort)
    return cfg
}

public func configToJson(cfg: Config): JsonValue {
    let o = Json.obj()
    Json.set(o, "version", Json.of(1))
    Json.set(o, "language", Json.of(cfg.language))
    let rootsArr = ArrayList<JsonValue>()
    for (r in cfg.roots) {
        rootsArr.add(Json.of(r))
    }
    Json.set(o, "roots", JArr(rootsArr))
    let ai = Json.obj()
    Json.set(o, "ai", ai)
    let update = Json.obj()
    let docsArr = ArrayList<JsonValue>()
    for (d in cfg.docs) {
        docsArr.add(Json.of(d))
    }
    Json.set(update, "docs", JArr(docsArr))
    let agentArr = ArrayList<JsonValue>()
    for (d in cfg.agentDocCandidates) {
        agentArr.add(Json.of(d))
    }
    Json.set(update, "agentDocCandidates", JArr(agentArr))
    Json.set(update, "backupKeep", Json.of(cfg.backupKeep))
    Json.set(update, "maxShallowBranches", Json.of(cfg.maxShallowBranches))
    Json.set(o, "update", update)
    let hooks = Json.obj()
    Json.set(hooks, "mode", Json.of(cfg.hookMode))
    Json.set(o, "hooks", hooks)
    let server = Json.obj()
    Json.set(server, "host", Json.of(cfg.serverHost))
    Json.set(server, "port", Json.of(cfg.serverPort))
    Json.set(o, "server", server)
    return o
}

public func loadConfig(): Config {
    let base = Config.defaults()
    match (readFileText(configPath())) {
        case Some(text) =>
            match (Json.parse(text)) {
                case Some(j) =>
                    var cfg = configFromJson(j, base)
                    return applyEnvOverrides(cfg)
                case None =>
                    Log.warn("config.json 解析失败，使用默认配置")
                    return applyEnvOverrides(base)
            }
        case None => return applyEnvOverrides(base)
    }
}

public func saveConfig(cfg: Config): Unit {
    writeFileAtomic(configPath(), Json.pretty(configToJson(cfg)))
}

public func applyEnvOverrides(cfg: Config): Config {
    match (getVariable("DEEPGIT_LANG")) {
        case Some(v) =>
            if (!v.isBlank()) {
                cfg.language = v.trimAscii()
            }
        case None => ()
    }
    return cfg
}

// ------------------------------ 测试 ------------------------------

@Test
func testConfigDefaults(): Unit {
    let cfg = Config.defaults()
    @Assert(cfg.language == "zh")
    @Assert(cfg.docs.size == 3)
    @Assert(cfg.serverPort == 5177)
    @Assert(cfg.maxShallowBranches == 6)
}

@Test
func testConfigRoundTrip(): Unit {
    let cfg = Config.defaults()
    cfg.language = "en"
    cfg.serverPort = 8080
    cfg.roots = ArrayList<String>(["/a", "/b"])
    let j = configToJson(cfg)
    let back = configFromJson(j, Config.defaults())
    @Assert(back.language == "en")
    @Assert(back.serverPort == 8080)
    @Assert(back.roots.size == 2)
}

@Test
func testConfigJsonShape(): Unit {
    let j = configToJson(Config.defaults())
    @Assert(Json.get(j, "ai").isSome())
    @Assert(Json.get(j, "update").isSome())
    @Assert(Json.get(j, "server").isSome())
    @Assert(Json.get(j, "hooks").isSome())
}
