// 文本处理工具：宽度计算、截断、Markdown 规整、JSON 提取。
package deepgit.util

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/// 显示宽度（CJK 宽字符按 2 计）
public func displayWidth(s: String): Int64 {
    var w: Int64 = 0
    for (r in s.runes()) {
        let cp = UInt32(r)
        if (isWide(cp)) {
            w += 2
        } else {
            w += 1
        }
    }
    return w
}

func isWide(cp: UInt32): Bool {
    return (cp >= 0x1100u32 && cp <= 0x115fu32)
        || (cp >= 0x2e80u32 && cp <= 0xa4cfu32)
        || (cp >= 0xac00u32 && cp <= 0xd7a3u32)
        || (cp >= 0xf900u32 && cp <= 0xfaffu32)
        || (cp >= 0xfe30u32 && cp <= 0xfe6fu32)
        || (cp >= 0xff00u32 && cp <= 0xff60u32)
        || (cp >= 0xffe0u32 && cp <= 0xffe6u32)
}

/// 按显示宽度截断（不是按字符数）
public func truncate(s: String, maxWidth: Int64, ellipsis: String): String {
    if (displayWidth(s) <= maxWidth) {
        return s
    }
    let ellWidth = displayWidth(ellipsis)
    let budget = maxWidth - ellWidth
    if (budget <= 0) {
        return ellipsis
    }
    var w: Int64 = 0
    let sb = StringBuilder()
    for (r in s.runes()) {
        let cw = if (isWide(UInt32(r))) { 2 } else { 1 }
        if (w + cw > budget) {
            break
        }
        sb.append(r.toString())
        w += cw
    }
    return sb.toString() + ellipsis
}

/// 折叠空白为单空格
public func oneLine(s: String): String {
    let sb = StringBuilder()
    var pendingSpace = false
    for (r in s.runes()) {
        let c = r.toString()
        if (c == " " || c == "\t" || c == "\n" || c == "\r") {
            pendingSpace = true
        } else {
            if (pendingSpace && sb.size > 0) {
                sb.append(" ")
            }
            pendingSpace = false
            sb.append(c)
        }
    }
    return sb.toString()
}

/// 规整 Markdown：统一换行、压缩多余空行、确保单个结尾换行
public func tidyMarkdown(s: String): String {
    let normalized = s.replace("\r\n", "\n")
    var lines = ArrayList<String>()
    var blankRun = 0
    for (line in normalized.split("\n")) {
        let trimmedRight = trimRightSpaces(line)
        if (trimmedRight.isEmpty()) {
            blankRun += 1
            if (blankRun <= 1) {
                lines.add("")
            }
        } else {
            blankRun = 0
            lines.add(trimmedRight)
        }
    }
    // 去掉尾部空行
    while (!lines.isEmpty() && lines[lines.size - 1].isEmpty()) {
        lines.remove(at: lines.size - 1)
    }
    let sb = StringBuilder()
    for (i in 0..lines.size) {
        if (i > 0) {
            sb.append("\n")
        }
        sb.append(lines[i])
    }
    sb.append("\n")
    return sb.toString()
}

func trimRightSpaces(s: String): String {
    var end = s.size
    while (end > 0) {
        let c = s[end - 1]
        if (c == 0x20u8 || c == 0x09u8) {
            end -= 1
        } else {
            break
        }
    }
    return s[..end]
}

public func bulletList(items: ArrayList<String>): String {
    let sb = StringBuilder()
    for (item in items) {
        let t = oneLine(item)
        if (t.isEmpty()) {
            continue
        }
        sb.append("- ")
        sb.append(t)
        sb.append("\n")
    }
    return sb.toString()
}

/// 从 LLM 输出中提取 JSON：剥离代码块围栏，取最外层对象
public func extractJsonBlock(text: String): Option<String> {
    var s = text.trimAscii()
    let fenceStart = s.indexOf("```")
    if (fenceStart.isSome()) {
        let start = fenceStart.getOrThrow()
        let afterFence = s[start + 3..]
        // 跳过语言标记行
        let nl = afterFence.indexOf("\n")
        let body = if (nl.isSome()) { afterFence[nl.getOrThrow() + 1..] } else { afterFence }
        let fenceEnd = body.indexOf("```")
        s = if (fenceEnd.isSome()) { body[..fenceEnd.getOrThrow()] } else { body }
    }
    let firstBrace = s.indexOf("{")
    if (firstBrace.isNone()) {
        return None
    }
    let lastBrace = s.lastIndexOf("}")
    if (lastBrace.isNone()) {
        return None
    }
    let a = firstBrace.getOrThrow()
    let b = lastBrace.getOrThrow()
    if (b <= a) {
        return None
    }
    return Some(s[a..b + 1])
}

/// 近似 token 数（中英混合的粗略护栏，非精确计数）
public func approxTokens(s: String): Int64 {
    var cjk: Int64 = 0
    var other: Int64 = 0
    for (r in s.runes()) {
        let cp = UInt32(r)
        if (cp >= 0x3040u32 && cp <= 0x30ffu32 || cp >= 0x3400u32 && cp <= 0x9fffu32 || cp >= 0xf900u32 && cp <= 0xfaffu32) {
            cjk += 1
        } else {
            other += 1
        }
    }
    return Int64(Float64(cjk) * 1.2 + Float64(other) / 3.5) + 1
}

/// 按字节长度安全截断字符串（不切断 UTF-8 多字节序列）
public func truncateChars(s: String, maxChars: Int64): String {
    if (s.size <= maxChars) {
        return s
    }
    return s[..charBoundaryAt(s, maxChars)]
}

/// 按字节上限安全截断（不切断 UTF-8 字符）。所有来自外部的字符串切片都应经此。
public func safeSlice(s: String, maxBytes: Int64): String {
    if (maxBytes <= 0) {
        return ""
    }
    if (s.size <= maxBytes) {
        return s
    }
    return s[..charBoundaryAt(s, maxBytes)]
}

/// 返回 <= 目标字节位置的安全字符边界（避免切断 UTF-8 多字节序列）
public func charBoundaryAt(s: String, target: Int64): Int64 {
    let bytes = s.toArray()
    var i: Int64 = 0
    var last = 0
    while (i < bytes.size && i <= target) {
        let b = bytes[i]
        var step: Int64 = 1
        if (b >= 0xf0u8) {
            step = 4
        } else if (b >= 0xe0u8) {
            step = 3
        } else if (b >= 0xc0u8) {
            step = 2
        }
        if (i + step > target) {
            break
        }
        i += step
        last = i
    }
    return last
}

/// 缩进多行文本
public func indentLines(s: String, prefix: String): String {
    let sb = StringBuilder()
    let parts = s.split("\n")
    for (i in 0..parts.size) {
        if (i > 0) {
            sb.append("\n")
        }
        if (!parts[i].isEmpty()) {
            sb.append(prefix)
        }
        sb.append(parts[i])
    }
    return sb.toString()
}

/// 用分隔符拼接字符串数组
public func joinStrings(items: Collection<String>, sep: String): String {
    let sb = StringBuilder()
    var first = true
    for (item in items) {
        if (!first) {
            sb.append(sep)
        }
        first = false
        sb.append(item)
    }
    return sb.toString()
}

// ------------------------------ 测试 ------------------------------

@Test
func testDisplayWidth(): Unit {
    @Assert(displayWidth("abc") == 3)
    @Assert(displayWidth("中文") == 4)
    @Assert(displayWidth("a中b") == 4)
}

@Test
func testTruncate(): Unit {
    @Assert(truncate("hello world", 8, "…") == "hello w…")
    @Assert(truncate("中文测试文本", 6, "…") == "中文…")
    @Assert(truncate("short", 10, "…") == "short")
}

@Test
func testOneLine(): Unit {
    @Assert(oneLine("a  b\n\tc") == "a b c")
    @Assert(oneLine("  leading") == "leading")
}

@Test
func testTidyMarkdown(): Unit {
    let messy = "a\r\n\n\n\nb  \n"
    @Assert(tidyMarkdown(messy) == "a\n\nb\n")
    @Assert(tidyMarkdown("").isEmpty() == false)
}

@Test
func testExtractJsonBlock(): Unit {
    let fenced = "```json\n{\"a\": 1}\n```"
    @Assert(extractJsonBlock(fenced).getOrThrow() == "{\"a\": 1}")
    let plain = "prefix {\"b\": 2} suffix"
    @Assert(extractJsonBlock(plain).getOrThrow() == "{\"b\": 2}")
    @Assert(extractJsonBlock("no json").isNone())
}

@Test
func testApproxTokens(): Unit {
    @Assert(approxTokens("") == 1)
    @Assert(approxTokens("hello world") > 1)
    @Assert(approxTokens("中文字符测试") > 4)
}

/// 宽松 UTF-8 解码：非法字节序列替换为 U+FFFD，绝不抛异常。
/// 外部命令输出与用户文件都不可保证是合法 UTF-8，读取路径必须用它。
public func fromUtf8Lossy(bytes: Array<UInt8>): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < bytes.size) {
        let b0 = bytes[i]
        if (b0 < 0x80u8) {
            sb.append(Rune(UInt32(b0)).toString())
            i += 1
            continue
        }
        var need: Int64 = 0
        var cp: UInt32 = 0
        if (b0 >= 0xc2u8 && b0 <= 0xdfu8) {
            need = 2
            cp = UInt32(b0 & 0x1fu8)
        } else if (b0 >= 0xe0u8 && b0 <= 0xefu8) {
            need = 3
            cp = UInt32(b0 & 0x0fu8)
        } else if (b0 >= 0xf0u8 && b0 <= 0xf4u8) {
            need = 4
            cp = UInt32(b0 & 0x07u8)
        } else {
            sb.append("\u{fffd}")
            i += 1
            continue
        }
        if (i + need > bytes.size) {
            sb.append("\u{fffd}")
            i += 1
            continue
        }
        var ok = true
        var k: Int64 = 1
        while (k < need) {
            let c = bytes[i + k]
            if (c < 0x80u8 || c > 0xbfu8) {
                ok = false
                break
            }
            cp = (cp << 6) | UInt32(c & 0x3fu8)
            k += 1
        }
        if (!ok) {
            sb.append("\u{fffd}")
            i += 1
            continue
        }
        // 校验码点范围（排除代理区与越界）
        if (cp > 0x10ffffu32 || (cp >= 0xd800u32 && cp <= 0xdfffu32)) {
            sb.append("\u{fffd}")
        } else {
            sb.append(Rune(cp).toString())
        }
        i += need
    }
    return sb.toString()
}

@Test
func testSafeSliceDoesNotSplitUtf8(): Unit {
    let s = "中文提交信息内容很长"  // 每字 3 字节
    @Assert(safeSlice(s, 4) == "中")        // 4 落在"中"之后、第二个字中间 → 退到边界
    @Assert(safeSlice(s, 3) == "中")
    @Assert(safeSlice(s, 2) == "")          // 不足一个字
    @Assert(safeSlice(s, 0) == "")
    @Assert(safeSlice(s, 1000) == s)
    // 结果必须是合法 UTF-8（能再次编码不抛）
    @Assert(safeSlice(s, 7).toArray().size <= 7)
}

@Test
func testTruncateCharsIsCharSafe(): Unit {
    let s = "中文字符测试内容"
    // 目标字节位置落在字符中间时，不得切断
    let t = truncateChars(s, 7)
    @Assert(displayWidth(t) % 2 == 0)
    @Assert(s.startsWith(t))
    @Assert(truncateChars("abc", 10) == "abc")
}

@Test
func testFromUtf8LossyValid(): Unit {
    @Assert(fromUtf8Lossy("你好abc".toArray()) == "你好abc")
    @Assert(fromUtf8Lossy(Array<UInt8>()).size == 0)
}

@Test
func testFromUtf8LossyInvalid(): Unit {
    // 单个非法字节
    let bad: Array<UInt8> = [0xffu8, 0x61u8]
    let s = fromUtf8Lossy(bad)
    @Assert(s.contains("a"))
    @Assert(s.contains("\u{fffd}"))
    // 截断的多字节序列
    let truncated: Array<UInt8> = [0xe4u8, 0xb8u8]
    @Assert(fromUtf8Lossy(truncated).contains("\u{fffd}"))
    // GBK 中文（常见于中文提交信息）
    let gbk: Array<UInt8> = [0xc4u8, 0xe3u8, 0xbau8, 0xc3u8]
    @Assert(fromUtf8Lossy(gbk).size > 0)
}

// ------------------------------ String 扩展 ------------------------------
//
// 仓颉的 extend 允许给任何类型补方法（无需继承/包装），这里把散落各处的
// "trim + isEmpty" 与 "取首行" 收敛成语义化方法。

extend String {
    /// 空白行判断：空串或仅含空白字符
    public func isBlank(): Bool {
        return this.trimAscii().isEmpty()
    }

    /// 取第一行（无换行则原样返回）
    public func firstLine(): String {
        return match (this.indexOf("\n")) {
            case Some(i) => this[..i]
            case None => this
        }
    }

    /// 按字符安全截断并按需补省略号（UTF-8 边界安全）
    public func ellipsis(maxChars: Int64): String {
        if (this.size <= maxChars) {
            return this
        }
        return truncateChars(this, maxChars) + "…"
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testStringExtensions(): Unit {
    @Assert("".isBlank())
    @Assert("   \t\n".isBlank())
    @Assert(!"x".isBlank())
    @Assert("hello\nworld".firstLine() == "hello")
    @Assert("no-newline".firstLine() == "no-newline")
    @Assert("\n".firstLine() == "")
    // 中文不会被截断出乱码
    let e = "仓颉语言特性演示字符串".ellipsis(6)
    @Assert(e.size <= 6 + "…".size)
    @Assert(e.endsWith("…"))
    @Assert("短的".ellipsis(10) == "短的")
}

@Test
func testFirstLineOnLongText(): Unit {
    let text = "# 标题\n\n正文内容\n更多"
    @Assert(text.firstLine() == "# 标题")
}
