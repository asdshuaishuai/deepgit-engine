// 文档读取：把项目内 README / AGENTS / CLAUDE 的内容供给客户端平铺展示。
package deepgit.flow

import std.collection.*
import deepgit.kernel.*
import deepgit.util.*
import std.unittest.*
import std.unittest.testmacro.*

public class DocFile {
    public let file: String
    public let content: String

    public init(file: String, content: String) {
        this.file = file
        this.content = content
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "file", Json.of(this.file))
        Json.set(o, "content", Json.of(this.content))
        return o
    }
}

let DOC_MAX_BYTES: Int64 = 200000

/// 读取项目内存在的研究文档（config.docs + agentDocCandidates 的交集按配置顺序），
/// 单文件截断到 200KB，避免巨型 README 拖垮 API。
public func readProjectDocs(root: String, config: Config): ArrayList<DocFile> {
    let out = ArrayList<DocFile>()
    for (name in detectDocsPresent(root, config)) {
        match (readFileText("${root}/${name}")) {
            case Some(text) =>
                let trimmed = if (text.size > DOC_MAX_BYTES) { safeSlice(text, DOC_MAX_BYTES) + "\n\n_（内容过长，已截断）_" } else { text }
                out.add(DocFile(name, trimmed))
            case None => ()
        }
    }
    return out
}

// ------------------------------ 测试 ------------------------------

@Test
func testReadProjectDocs(): Unit {
    let base = "/tmp/deepgit-docs-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    writeFileAtomic(base + "/README.md", "# 标题\n\n正文内容\n")
    writeFileAtomic(base + "/AGENTS.md", "# AGENTS 指南\n")
    writeFileAtomic(base + "/CLAUDE.md", "# CLAUDE 指南\n")

    let docs = readProjectDocs(base, Config.defaults())
    // README 在配置首位
    @Assert(docs.size >= 2)
    @Assert(docs[0].file == "README.md")
    @Assert(docs[0].content.contains("正文内容"))
    var hasAgents = false
    for (d in docs) {
        if (d.file == "AGENTS.md") {
            hasAgents = true
        }
    }
    @Assert(hasAgents)
    // toJson 一致性
    @Assert(Json.strAt(docs[0].toJson(), "file", "") == "README.md")

    // 没有任何文档的仓库 → 空列表
    let empty = "/tmp/deepgit-docs2-${nowMillis()}"
    ensureDir(empty)
    gitRun(empty, ["init", "-b", "main"], true)
    @Assert(readProjectDocs(empty, Config.defaults()).size == 0)
    removePathIfExists(base)
    removePathIfExists(empty)
}
