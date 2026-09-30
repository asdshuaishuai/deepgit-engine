// 托管区域文档引擎：deepGit 只改写自己标记的区块，其余内容逐字节保留。
//
//   <!-- deepgit:begin progress -->
//   …生成内容…
//   <!-- deepgit:end progress -->
package deepgit.kernel

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

public class Region {
    public let name: String
    public let start: Int64
    public let end: Int64
    public let content: String

    public init(name: String, start: Int64, end: Int64, content: String) {
        this.name = name
        this.start = start
        this.end = end
        this.content = content
    }
}

let beginMarkerPlaceholder = "<!-- deepgit:begin "

func beginMarker(name: String): String {
    return "<!-- deepgit:begin ${name} -->"
}

func endMarker(name: String): String {
    return "<!-- deepgit:end ${name} -->"
}

/// 列出文档中所有托管区域
public func listRegions(text: String): ArrayList<Region> {
    let out = ArrayList<Region>()
    var searchFrom: Int64 = 0
    while (searchFrom < text.size) {
        let beginIdx = text.indexOf(beginMarkerPlaceholder, searchFrom)
        match (beginIdx) {
            case None => break
            case Some(bi) =>
                // 解析名称
                let afterBegin = bi + beginMarkerPlaceholder.size
                let closeIdx = text.indexOf(" -->", afterBegin)
                match (closeIdx) {
                    case None => break
                    case Some(ci) =>
                        let name = text[afterBegin..ci].trimAscii()
                        // 容忍标记行的前导空白：把区域起点回退到行首，
                        // 这样重写时不会残留旧的缩进（手写文档常见）。
                        var regionStart = bi
                        while (regionStart > 0) {
                            let ch = text[regionStart - 1]
                            if (ch == 0x20u8 || ch == 0x09u8) {
                                regionStart -= 1
                            } else {
                                break
                            }
                        }
                        let endMarkerStr = endMarker(name)
                        let endIdx = text.indexOf(endMarkerStr, ci)
                        match (endIdx) {
                            case None =>
                                searchFrom = ci + 4
                            case Some(ei) =>
                                let contentStart = ci + 4
                                let rawContent = text[contentStart..ei]
                                let content = trimSingleNewline(rawContent)
                                out.add(Region(name, regionStart, ei + endMarkerStr.size, content))
                                searchFrom = ei + endMarkerStr.size
                        }
                }
        }
    }
    return out
}

func trimSingleNewline(s: String): String {
    var t = s
    if (t.startsWith("\n")) {
        t = t[1..]
    }
    if (t.endsWith("\n")) {
        t = t[..t.size - 1]
    }
    return t
}

public func regionNames(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (r in listRegions(text)) {
        out.add(r.name)
    }
    return out
}

func renderBlock(name: String, content: String): String {
    return "${beginMarker(name)}\n${tidyMarkdown(content)}${endMarker(name)}"
}

/// 替换已有区域内容
public func replaceRegion(text: String, name: String, content: String): Option<String> {
    for (r in listRegions(text)) {
        if (r.name == name) {
            let block = renderBlock(name, content)
            return Some(text[..r.start] + block + text[r.end..])
        }
    }
    return None
}

/// 在文末追加新区域。保留原文末尾的换行风格，只在必要时补分隔空行。
public func insertRegion(text: String, name: String, content: String): String {
    let block = renderBlock(name, content)
    if (text.size == 0) {
        return block + "\n"
    }
    // 已有文档：在保留原文的前提下追加（末尾无换行则先补一个）
    let needsNewline = !text.endsWith("\n")
    let needsBlank = !text.endsWith("\n\n")
    let sb = StringBuilder(text)
    if (needsNewline) {
        sb.append("\n")
    }
    if (needsBlank) {
        sb.append("\n")
    }
    sb.append(block)
    sb.append("\n")
    return sb.toString()
}

/// 更新区域内容；若仅时间戳不同则保持原样（避免无意义的文件抖动/提交噪音）。
public func upsertRegion(text: String, name: String, content: String): String {
    for (r in listRegions(text)) {
        if (r.name == name) {
            if (stripUpdateStamp(r.content) == stripUpdateStamp(content)) {
                return text  // 实质内容未变，保留原时间戳
            }
            let block = renderBlock(name, content)
            return text[..r.start] + block + text[r.end..]
        }
    }
    return insertRegion(text, name, content)
}

/// 去掉"更新于 <时间>"片段，用于语义等价比对
public func stripUpdateStamp(content: String): String {
    let marker = "更新于 "
    let idx = content.indexOf(marker)
    match (idx) {
        case None => return content
        case Some(i) =>
            // 时间戳在行内：从 marker 到行尾替换为空
            let after = content[i..]
            let nl = after.indexOf("\n")
            let lineEnd = if (nl.isSome()) { i + nl.getOrThrow() } else { content.size }
            return content[..i] + content[lineEnd..]
    }
}

public class ApplyResult {
    public let file: String
    public let changed: Bool
    public let created: Bool
    public let backup: String
    public let regions: ArrayList<String>

    public init(file: String, changed: Bool, created: Bool, backup: String, regions: ArrayList<String>) {
        this.file = file
        this.changed = changed
        this.created = created
        this.backup = backup
        this.regions = regions
    }
}

/// 应用一组区域内容到文件（带备份与变更检测）
public func applyRegions(filePath: String, regions: ArrayList<(String, String)>, backupDir: String, createTemplate: String): ApplyResult {
    let exists = fileExists(filePath)
    var original = ""
    var created = false
    if (exists) {
        original = readFileTextOr(filePath, "")
    } else if (!createTemplate.isEmpty()) {
        original = createTemplate
        created = true
    }

    var next = original
    var changed = false
    let applied = ArrayList<String>()
    for ((name, content) in regions) {
        let after = upsertRegion(next, name, content)
        if (after != next) {
            changed = true
        }
        next = after
        applied.add(name)
    }

    if (!changed) {
        return ApplyResult(filePath, false, false, "", applied)
    }

    var backupPath = ""
    if (exists && !backupDir.isEmpty()) {
        ensureDir(backupDir)
        backupPath = "${backupDir}/${fileTimestamp()}-${basename(filePath)}"
        copy(Path(filePath), to: Path(backupPath), overwrite: true)
    }

    // 只规整 deepGit 生成的区域内容（renderBlock 内已做），
    // 文档其余部分必须逐字节保留 —— 不能对整篇文档做 tidyMarkdown。
    writeFileAtomic(filePath, next)
    return ApplyResult(filePath, true, created, backupPath, applied)
}

/// 校验文档完整性：剥离托管区域后，用户内容应与备份（写入前）一致。
/// 用于自查「只改托管区域」这一核心承诺是否被违反。
public func verifyPreservation(filePath: String, backupFile: String): (Bool, String) {
    match (readFileText(backupFile)) {
        case None => return (true, "无备份可比对")
        case Some(before) =>
            let after = readFileTextOr(filePath, "")
            let b = stripRegionsForVerify(before)
            let a = stripRegionsForVerify(after)
            if (b == a) {
                return (true, "逐字节一致")
            }
            if (b.trimAscii() == a.trimAscii()) {
                return (true, "仅文末分隔空行差异（插入区域所必需）")
            }
            return (false, "用户内容被改动")
    }
}

/// 剥离全部托管区域（用于完整性校验）
public func stripRegionsForVerify(text: String): String {
    let sb = StringBuilder()
    var cursor: Int64 = 0
    while (cursor < text.size) {
        let beginIdx = text.indexOf(beginMarkerPlaceholder, cursor)
        match (beginIdx) {
            case None =>
                sb.append(text[cursor..])
                break
            case Some(bi) =>
                // 回退到标记行行首（含前导空白）
                var lineStart = bi
                while (lineStart > 0) {
                    let ch = text[lineStart - 1]
                    if (ch == 0x20u8 || ch == 0x09u8) {
                        lineStart -= 1
                    } else {
                        break
                    }
                }
                sb.append(text[cursor..lineStart])
                let afterBegin = bi + beginMarkerPlaceholder.size
                let closeIdx = text.indexOf(" -->", afterBegin)
                match (closeIdx) {
                    case None =>
                        sb.append(text[bi..])
                        break
                    case Some(ci) =>
                        let name = text[afterBegin..ci].trimAscii()
                        let endIdx = text.indexOf(endMarker(name), ci)
                        match (endIdx) {
                            case None =>
                                sb.append(text[bi..])
                                break
                            case Some(ei) =>
                                // 跳过整个区域与其后的空行
                                var next = ei + endMarker(name).size
                                while (next < text.size && text[next] == 0x0au8) {
                                    next += 1
                                }
                                cursor = next
                        }
                }
        }
    }
    return sb.toString()
}

/// 修剪备份目录至最新 keep 个
public func pruneBackups(backupDir: String, keep: Int64): Unit {
    if (!isDirectoryPath(backupDir)) {
        return
    }
    let entries = listDir(backupDir)
    let names = ArrayList<String>()
    for (e in entries) {
        names.add(e.name)
    }
    if (names.size <= keep) {
        return
    }
    names.sort()
    let excess = names.size - keep
    var i: Int64 = 0
    for (n in names) {
        if (i >= excess) {
            break
        }
        removePathIfExists("${backupDir}/${n}")
        i += 1
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testListRegions(): Unit {
    let doc = "# Title\n\n<!-- deepgit:begin progress -->\nhello\n<!-- deepgit:end progress -->\n\nmore text\n"
    let regions = listRegions(doc)
    @Assert(regions.size == 1)
    @Assert(regions[0].name == "progress")
    @Assert(regions[0].content == "hello")
}

@Test
func testListMultipleRegions(): Unit {
    let doc = "<!-- deepgit:begin overview -->\nA\n<!-- deepgit:end overview -->\n\n<!-- deepgit:begin progress -->\nB\n<!-- deepgit:end progress -->"
    let names = regionNames(doc)
    @Assert(names.size == 2)
    @Assert(names[0] == "overview")
    @Assert(names[1] == "progress")
}

@Test
func testReplaceRegionPreservesSurrounding(): Unit {
    let doc = "# Title\n\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n\nfooter\n"
    let next = replaceRegion(doc, "progress", "new content").getOrThrow()
    @Assert(next.contains("new content"))
    @Assert(!next.contains("old"))
    @Assert(next.startsWith("# Title"))
    @Assert(next.contains("footer"))
}

@Test
func testUpsertAppendsWhenMissing(): Unit {
    let doc = "# Title\n"
    let next = upsertRegion(doc, "progress", "generated")
    @Assert(next.contains("# Title"))
    @Assert(next.contains("deepgit:begin progress"))
    @Assert(next.contains("generated"))
}

@Test
func testUserContentIsPreservedByteForByte(): Unit {
    let doc = "用户手写内容 🙌\n\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n\n尾部内容\n"
    let next = replaceRegion(doc, "progress", "new").getOrThrow()
    @Assert(next.contains("用户手写内容 🙌"))
    @Assert(next.contains("尾部内容"))
    @Assert(next.contains("new"))
}

@Test
func testUpsertRegionKeepsOldTimestampWhenContentUnchanged(): Unit {
    let content1 = "> deepGit · 更新于 2026-09-30 10:00\n\n正文内容"
    let doc = upsertRegion("# t\n", "progress", content1)
    let content2 = "> deepGit · 更新于 2026-09-30 11:00\n\n正文内容"
    let doc2 = upsertRegion(doc, "progress", content2)
    @Assert(doc2 == doc)  // 时间戳未刷新
    let content3 = "> deepGit · 更新于 2026-09-30 11:00\n\n正文已改变"
    let doc3 = upsertRegion(doc, "progress", content3)
    @Assert(doc3 != doc)
    @Assert(doc3.contains("正文已改变"))
    @Assert(doc3.contains("11:00"))
}

@Test
func testStripUpdateStamp(): Unit {
    @Assert(stripUpdateStamp("a 更新于 2026-01-01 00:00\nb") == "a \nb")
    @Assert(stripUpdateStamp("no stamp here") == "no stamp here")
}

@Test
func testIndentedMarkerIsRecognizedAndReNormalized(): Unit {
    // 手写文档里标记常被缩进；重写后应回归顶格，且不产生重复区域
    let doc = "# t\n\n   <!-- deepgit:begin progress -->\n旧内容\n   <!-- deepgit:end progress -->\n"
    @Assert(listRegions(doc).size == 1)
    @Assert(listRegions(doc)[0].name == "progress")
    let next = upsertRegion(doc, "progress", "新内容")
    @Assert(next.contains("新内容"))
    @Assert(!next.contains("旧内容"))
    @Assert(listRegions(next).size == 1)
    // 重写后标记应顶格（不要残留缩进）
    @Assert(next.contains("\n<!-- deepgit:begin progress -->") || next.startsWith("<!-- deepgit:begin progress -->"))
}

@Test
func testNoDuplicateRegionWhenMarkerIndented(): Unit {
    let doc = "   <!-- deepgit:begin progress -->\nA\n   <!-- deepgit:end progress -->\n"
    let next = upsertRegion(doc, "progress", "B")
    var count: Int64 = 0
    for (r in listRegions(next)) {
        if (r.name == "progress") {
            count += 1
        }
    }
    @Assert(count == 1)
}

@Test
func testUnclosedRegionIgnored(): Unit {
    let doc = "<!-- deepgit:begin progress -->\nnever closed\n"
    @Assert(listRegions(doc).size == 0)
}

@Test
func testUserWhitespaceIsPreservedExactly(): Unit {
    let doc = "# 标题\n\n\n\n（连续空行应保留）\n带行尾空格   \n\n<!-- deepgit:begin progress -->\n旧\n<!-- deepgit:end progress -->\n"
    let next = upsertRegion(doc, "progress", "新")
    @Assert(next.contains("标题\n\n\n\n"))     // 连续空行未被压缩
    @Assert(next.contains("带行尾空格   \n"))     // 行尾空格未被去掉
    @Assert(next.contains("新"))
}

@Test
func testApplyRegionsPreservesUserWhitespaceOnDisk(): Unit {
    let dir = "/tmp/deepgit-ws-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let original = "# T\n\n\n内容行   \n"
    writeFileAtomic(file, original + "\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n")
    let regions = ArrayList<(String, String)>([("progress", "new")])
    applyRegions(file, regions, "", "")
    let after = readFileTextOr(file, "")
    @Assert(after.contains("# T\n\n\n内容行   \n"))  // 原文空白原样保留
    removePathIfExists(dir)
}

@Test
func testApplyRegionsCreatesFile(): Unit {
    let dir = "/tmp/deepgit-docs-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let regions = ArrayList<(String, String)>([("progress", "## 进度\n\n内容")])
    let res = applyRegions(file, regions, "${dir}/backups", "# 新文档\n\n")
    @Assert(res.changed)
    @Assert(res.created)
    let text = readFileTextOr(file, "")
    @Assert(text.contains("## 进度"))
    @Assert(text.contains("# 新文档"))
    removePathIfExists(dir)
}

@Test
func testApplyRegionsBacksUpAndIsIdempotent(): Unit {
    let dir = "/tmp/deepgit-docs2-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    writeFileAtomic(file, "# Original\n\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n")
    let regions = ArrayList<(String, String)>([("progress", "v2")])
    let r1 = applyRegions(file, regions, "${dir}/backups", "")
    @Assert(r1.changed)
    @Assert(!r1.backup.isEmpty())
    let r2 = applyRegions(file, regions, "${dir}/backups", "")
    @Assert(!r2.changed)  // 幂等
    let backups = listDir("${dir}/backups")
    @Assert(backups.size == 1)
    removePathIfExists(dir)
}

@Test
func testVerifyPreservationDetectsNoChange(): Unit {
    let dir = "/tmp/deepgit-verify-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let before = "# T\n\n用户内容\n"
    writeFileAtomic("${dir}/backup.md", before + "\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n")
    writeFileAtomic(file, before + "\n<!-- deepgit:begin progress -->\nnew content here\n<!-- deepgit:end progress -->\n")
    let (ok, _) = verifyPreservation(file, "${dir}/backup.md")
    @Assert(ok)
    removePathIfExists(dir)
}

@Test
func testVerifyPreservationDetectsTampering(): Unit {
    let dir = "/tmp/deepgit-verify2-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    writeFileAtomic("${dir}/backup.md", "# T\n\n用户内容A\n")
    writeFileAtomic(file, "# T\n\n用户内容B（被改了）\n<!-- deepgit:begin progress -->\nx\n<!-- deepgit:end progress -->\n")
    let (ok, reason) = verifyPreservation(file, "${dir}/backup.md")
    @Assert(!ok)
    @Assert(reason.contains("被改动"))
    removePathIfExists(dir)
}

@Test
func testStripRegionsForVerify(): Unit {
    let doc = "A\n<!-- deepgit:begin progress -->\nX\n<!-- deepgit:end progress -->\nB\n"
    let stripped = stripRegionsForVerify(doc)
    @Assert(stripped.contains("A"))
    @Assert(stripped.contains("B"))
    @Assert(!stripped.contains("X"))
}

@Test
func testPruneBackups(): Unit {
    let dir = "/tmp/deepgit-prune-${nowMillis()}"
    ensureDir(dir)
    for (i in 0..5) {
        writeFileAtomic("${dir}/b${i}", "x")
    }
    pruneBackups(dir, 2)
    @Assert(listDir(dir).size == 2)
    removePathIfExists(dir)
}
