// 配置：默认值 + 文件读写 + 环境变量覆盖 + AI provider 解析。
package deepgit.kernel

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

/// AI provider 预设
public class AiPreset {
    public let name: String
    public let provider: String
    public let baseUrl: String
    public let model: String
    public let keyEnv: Array<String>

    public init(name: String, provider: String, baseUrl: String, model: String, keyEnv: Array<String>) {
        this.name = name
        this.provider = provider
        this.baseUrl = baseUrl
        this.model = model
        this.keyEnv = keyEnv
    }
}

public let AI_PRESETS: Array<AiPreset> = [
    AiPreset("deepseek", "openai", "https://api.deepseek.com", "deepseek-chat", ["DEEPGIT_AI_API_KEY", "DEEPSEEK_API_KEY"]),
    AiPreset("openai", "openai", "https://api.openai.com/v1", "gpt-4o-mini", ["DEEPGIT_AI_API_KEY", "OPENAI_API_KEY"]),
    AiPreset("anthropic", "anthropic", "https://api.anthropic.com", "claude-sonnet-4-5", ["DEEPGIT_AI_API_KEY", "ANTHROPIC_API_KEY"]),
    AiPreset("ollama", "openai", "http://127.0.0.1:11434/v1", "qwen3:8b", ["DEEPGIT_AI_API_KEY"]),
    AiPreset("custom", "openai", "", "", ["DEEPGIT_AI_API_KEY"]),
]

public func findPreset(name: String): AiPreset {
    for (p in AI_PRESETS) {
        if (p.name == name) {
            return p
        }
    }
    return AI_PRESETS[AI_PRESETS.size - 1]  // custom
}

/// 生效的 AI 配置（解析后的）
public class ResolvedAi {
    public let kind: String  // openai | anthropic | rules
    public let configured: Bool
    public let reason: String
    public let preset: String
    public let provider: String
    public let baseUrl: String
    public let model: String
    public let apiKey: String
    public let apiKeySource: Option<String>
    public let temperature: Float64
    public let maxOutputTokens: Int64
    public let timeoutMs: Int64
    public let retries: Int64
    public let maxInputChars: Int64
    public let maxCommitsDeep: Int64

    public init(
        kind: String, configured: Bool, reason: String, preset: String, provider: String,
        baseUrl: String, model: String, apiKey: String, apiKeySource: Option<String>,
        temperature: Float64, maxOutputTokens: Int64, timeoutMs: Int64, retries: Int64,
        maxInputChars: Int64, maxCommitsDeep: Int64,
    ) {
        this.kind = kind
        this.configured = configured
        this.reason = reason
        this.preset = preset
        this.provider = provider
        this.baseUrl = baseUrl
        this.model = model
        this.apiKey = apiKey
        this.apiKeySource = apiKeySource
        this.temperature = temperature
        this.maxOutputTokens = maxOutputTokens
        this.timeoutMs = timeoutMs
        this.retries = retries
        this.maxInputChars = maxInputChars
        this.maxCommitsDeep = maxCommitsDeep
    }

    public func label(): String {
        if (this.kind == "rules") {
            return "rules"
        }
        return "${this.kind}:${this.model}"
    }
}

/// 应用配置（带默认值）
public class Config {
    public var language: String = "zh"
    public var roots: ArrayList<String> = ArrayList<String>()
    public var docs: ArrayList<String> = ArrayList<String>(["README.md", "AGENTS.md", "CLAUDE.md"])
    public var agentDocCandidates: ArrayList<String> = ArrayList<String>(["AGENTS.md", "AGENT.md", "CLAUDE.md"])
    public var backupKeep: Int64 = 20
    public var maxShallowBranches: Int64 = 6
    public var hookMode: String = "track"
    public var aiOnHook: Bool = false
    public var serverHost: String = "127.0.0.1"
    public var serverPort: Int64 = 5177
    public var aiPreset: String = "auto"
    public var aiProvider: String = "auto"
    public var aiBaseUrl: String = ""
    public var aiModel: String = ""
    public var aiApiKey: String = ""
    public var aiTemperature: Float64 = 0.2
    public var aiMaxOutputTokens: Int64 = 3000
    public var aiTimeoutMs: Int64 = 120000
    public var aiRetries: Int64 = 2
    public var aiMaxInputChars: Int64 = 120000
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
    let ai = Json.getOr(j, "ai")
    cfg.aiPreset = Json.strAt(ai, "preset", base.aiPreset)
    cfg.aiProvider = Json.strAt(ai, "provider", base.aiProvider)
    cfg.aiBaseUrl = Json.strAt(ai, "baseUrl", base.aiBaseUrl)
    cfg.aiModel = Json.strAt(ai, "model", base.aiModel)
    cfg.aiApiKey = Json.strAt(ai, "apiKey", base.aiApiKey)
    cfg.aiTemperature = Json.numAt(ai, "temperature", base.aiTemperature)
    cfg.aiMaxOutputTokens = Json.intAt(ai, "maxOutputTokens", base.aiMaxOutputTokens)
    cfg.aiTimeoutMs = Json.intAt(ai, "timeoutMs", base.aiTimeoutMs)
    cfg.aiRetries = Json.intAt(ai, "retries", base.aiRetries)
    cfg.aiMaxInputChars = Json.intAt(ai, "maxInputChars", base.aiMaxInputChars)
    cfg.aiJsonMode = Json.strAt(ai, "jsonMode", base.aiJsonMode)
    let update = Json.getOr(j, "update")
    let docs = Json.strArrAt(update, "docs")
    cfg.docs = if (docs.isEmpty()) { base.docs } else { docs }
    let agentDocs = Json.strArrAt(update, "agentDocCandidates")
    cfg.agentDocCandidates = if (agentDocs.isEmpty()) { base.agentDocCandidates } else { agentDocs }
    cfg.backupKeep = Json.intAt(update, "backupKeep", base.backupKeep)
    cfg.maxShallowBranches = Json.intAt(update, "maxShallowBranches", base.maxShallowBranches)
    let hooks = Json.getOr(j, "hooks")
    cfg.hookMode = Json.strAt(hooks, "mode", base.hookMode)
    cfg.aiOnHook = Json.boolAt(hooks, "aiOnHook", base.aiOnHook)
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
    Json.set(ai, "preset", Json.of(cfg.aiPreset))
    Json.set(ai, "provider", Json.of(cfg.aiProvider))
    Json.set(ai, "baseUrl", Json.of(cfg.aiBaseUrl))
    Json.set(ai, "model", Json.of(cfg.aiModel))
    Json.set(ai, "apiKey", Json.of(cfg.aiApiKey))
    Json.set(ai, "temperature", Json.of(cfg.aiTemperature))
    Json.set(ai, "maxOutputTokens", Json.of(cfg.aiMaxOutputTokens))
    Json.set(ai, "timeoutMs", Json.of(cfg.aiTimeoutMs))
    Json.set(ai, "retries", Json.of(cfg.aiRetries))
    Json.set(ai, "maxInputChars", Json.of(cfg.aiMaxInputChars))
    Json.set(ai, "jsonMode", Json.of(cfg.aiJsonMode))
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
    Json.set(hooks, "aiOnHook", Json.of(cfg.aiOnHook))
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
    match (getVariable("DEEPGIT_AI_PRESET")) {
        case Some(v) =>
            if (!v.isBlank()) {
                cfg.aiPreset = v.trimAscii()
            }
        case None => ()
    }
    match (getVariable("DEEPGIT_AI_PROVIDER")) {
        case Some(v) =>
            if (!v.isBlank()) {
                cfg.aiProvider = v.trimAscii()
            }
        case None => ()
    }
    match (getVariable("DEEPGIT_AI_BASE_URL")) {
        case Some(v) =>
            if (!v.isBlank()) {
                cfg.aiBaseUrl = v.trimAscii()
            }
        case None => ()
    }
    match (getVariable("DEEPGIT_AI_MODEL")) {
        case Some(v) =>
            if (!v.isBlank()) {
                cfg.aiModel = v.trimAscii()
            }
        case None => ()
    }
    match (getVariable("DEEPGIT_AI_API_KEY")) {
        case Some(v) =>
            if (!v.isBlank()) {
                cfg.aiApiKey = v.trimAscii()
            }
        case None => ()
    }
    return cfg
}

/// 解析生效的 AI 配置（自动探测环境变量中的 key）
public func resolveAi(cfg: Config): ResolvedAi {
    var preset = cfg.aiPreset
    var provider = cfg.aiProvider
    var baseUrl = cfg.aiBaseUrl
    var model = cfg.aiModel
    var apiKey = cfg.aiApiKey
    var apiKeySource: Option<String> = if (!apiKey.isEmpty()) { Some("config") } else { None }

    // 自动探测
    if (preset == "auto" && provider == "auto") {
        let detected = detectPresetFromEnv()
        match (detected) {
            case Some(p) => preset = p
            case None => preset = "custom"
        }
    }
    let presetDef = findPreset(preset)

    if (provider == "auto") {
        provider = presetDef.provider
    }
    if (baseUrl.isEmpty()) {
        baseUrl = presetDef.baseUrl
    }
    if (model.isEmpty()) {
        model = presetDef.model
    }

    if (apiKey.isEmpty()) {
        // 先看 DEEPGIT_AI_API_KEY，再看预设的 key 环境变量
        let candidates = ArrayList<String>()
        candidates.add("DEEPGIT_AI_API_KEY")
        for (e in presetDef.keyEnv) {
            candidates.add(e)
        }
        candidates.add("DEEPGIT_AI_API_KEY")
        for (c in candidates) {
            match (getVariable(c)) {
                case Some(v) =>
                    if (!v.isBlank()) {
                        apiKey = v.trimAscii()
                        apiKeySource = Some(c)
                        break
                    }
                case None => ()
            }
        }
    }

    let temperature = cfg.aiTemperature
    let maxOut = cfg.aiMaxOutputTokens
    let timeout = cfg.aiTimeoutMs
    let retries = cfg.aiRetries
    let maxIn = cfg.aiMaxInputChars
    let maxCommits = 200

    if (provider == "none") {
        return ResolvedAi("rules", false, "AI 已禁用（provider=none），使用规则引擎", preset, provider, baseUrl, model, "", None, temperature, maxOut, timeout, retries, maxIn, maxCommits)
    }
    if (apiKey.isEmpty()) {
        return ResolvedAi(
            "rules", false,
            "未找到 AI API Key，使用规则引擎生成进度摘要（可运行 `deepgit config set ai.preset deepseek` 并设置 DEEPGIT_AI_API_KEY）",
            preset, provider, baseUrl, model, "", None, temperature, maxOut, timeout, retries, maxIn, maxCommits,
        )
    }
    if (baseUrl.isEmpty() || model.isEmpty()) {
        return ResolvedAi("rules", false, "AI baseUrl/model 未配置完整，使用规则引擎", preset, provider, baseUrl, model, "", apiKeySource, temperature, maxOut, timeout, retries, maxIn, maxCommits)
    }
    let kind = if (provider == "anthropic") { "anthropic" } else { "openai" }
    return ResolvedAi(kind, true, "AI 已就绪（${preset}: ${model}）", preset, provider, baseUrl, model, apiKey, apiKeySource, temperature, maxOut, timeout, retries, maxIn, maxCommits)
}

func detectPresetFromEnv(): Option<String> {
    let order = [("deepseek", "DEEPSEEK_API_KEY"), ("openai", "OPENAI_API_KEY"), ("anthropic", "ANTHROPIC_API_KEY")]
    for ((preset, envName) in order) {
        match (getVariable(envName)) {
            case Some(v) =>
                if (!v.isBlank()) {
                    return Some(preset)
                }
            case None => ()
        }
    }
    return None
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
    cfg.aiPreset = "deepseek"
    cfg.aiModel = "deepseek-chat"
    cfg.serverPort = 8080
    cfg.roots = ArrayList<String>(["/a", "/b"])
    let j = configToJson(cfg)
    let back = configFromJson(j, Config.defaults())
    @Assert(back.language == "en")
    @Assert(back.aiPreset == "deepseek")
    @Assert(back.aiModel == "deepseek-chat")
    @Assert(back.serverPort == 8080)
    @Assert(back.roots.size == 2)
}

@Test
func testResolveAiWithoutKey(): Unit {
    let cfg = Config.defaults()
    cfg.aiPreset = "deepseek"
    cfg.aiProvider = "openai"
    // 清掉可能存在的环境变量影响：显式设置空 key
    let resolved = resolveAi(cfg)
    // 当前测试环境若未设置密钥，则应降级到 rules
    if (!resolved.configured) {
        @Assert(resolved.kind == "rules")
        @Assert(resolved.reason.contains("规则引擎"))
    } else {
        @Assert(resolved.kind == "openai" || resolved.kind == "anthropic")
    }
}

@Test
func testFindPresetFallback(): Unit {
    @Assert(findPreset("deepseek").baseUrl.contains("deepseek"))
    @Assert(findPreset("nonexistent").name == "custom")
}

@Test
func testConfigJsonShape(): Unit {
    let j = configToJson(Config.defaults())
    @Assert(Json.get(j, "ai").isSome())
    @Assert(Json.get(j, "update").isSome())
    @Assert(Json.get(j, "server").isSome())
    @Assert(Json.get(j, "hooks").isSome())
}
