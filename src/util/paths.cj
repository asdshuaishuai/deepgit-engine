// 路径工具：~ 展开、全局数据目录、项目 ID、相对路径。
package deepgit.util

import std.collection.*
import std.env.*
import std.posix.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

public func homeDir(): String {
    match (getVariable("HOME")) {
        case Some(h) => return h
        case None => return "/tmp"
    }
}

/// 展开 ~ 前缀
public func expandHome(p: String): String {
    if (p == "~") {
        return homeDir()
    }
    if (p.startsWith("~/")) {
        return homeDir() + p[1..]
    }
    return p
}

/// 相对路径解析为绝对路径（不做 symlink 解析）
public func resolvePath(p: String, base: String): String {
    let expanded = expandHome(p)
    if (expanded.startsWith("/")) {
        return normalizePath(expanded)
    }
    return normalizePath(base + "/" + expanded)
}

/// 归一化路径：去掉 . 与 .. 段、重复斜杠
public func normalizePath(p: String): String {
    let absolute = p.startsWith("/")
    let parts = p.split("/")
    let stack = ArrayList<String>()
    for (part in parts) {
        if (part.isEmpty() || part == ".") {
            continue
        }
        if (part == "..") {
            if (!stack.isEmpty()) {
                stack.remove(at: stack.size - 1)
            }
            continue
        }
        stack.add(part)
    }
    let body = joinStrings(stack, "/")
    return if (absolute) { "/" + body } else { body }
}

/// 解析 macOS 常见符号链接目录前缀（/tmp → /private/tmp、/var → /private/var）。
/// 纯词法替换，仅用于路径等价比较，不访问文件系统。
public func resolveMacSymlink(p: String): String {
    if (p == "/tmp") {
        return "/private/tmp"
    }
    if (p.startsWith("/tmp/")) {
        return "/private/tmp" + p[4..]
    }
    if (p == "/var") {
        return "/private/var"
    }
    if (p.startsWith("/var/")) {
        return "/private/var" + p[4..]
    }
    return p
}

/// 路径等价判断：先做词法规范化，再容忍 macOS 符号链接前缀差异
public func samePath(a: String, b: String): Bool {
    if (a == b) {
        return true
    }
    let na = resolveMacSymlink(normalizePath(a))
    let nb = resolveMacSymlink(normalizePath(b))
    return na == nb
}

/// 全局数据目录（可用 DEEPGIT_HOME 覆盖，便于测试隔离）
public func deepgitHome(): String {
    match (getVariable("DEEPGIT_HOME")) {
        case Some(v) =>
            let t = v.trimAscii()
            if (!t.isEmpty()) {
                return normalizePath(expandHome(t))
            }
        case None => ()
    }
    return homeDir() + "/.deepgit"
}

public func deepgitPath(segments: Array<String>): String {
    let sb = StringBuilder(deepgitHome())
    for (s in segments) {
        sb.append("/")
        sb.append(s)
    }
    return sb.toString()
}

/// 稳定项目 ID：p_ + SHA256(绝对路径) 前 12 位
public func projectIdFor(absPath: String): String {
    let hex = sha256HexOf(normalizePath(absPath))
    return "p_" + hex[..12]
}

/// 取路径最后一段
public func basename(p: String): String {
    let trimmed = if (p.endsWith("/") && p.size > 1) { p[..p.size - 1] } else { p }
    let idx = trimmed.lastIndexOf("/")
    match (idx) {
        case Some(i) => return trimmed[i + 1..]
        case None => return trimmed
    }
}

public func dirname(p: String): String {
    let trimmed = if (p.endsWith("/") && p.size > 1) { p[..p.size - 1] } else { p }
    let idx = trimmed.lastIndexOf("/")
    match (idx) {
        case Some(i) =>
            if (i == 0) {
                return "/"
            }
            return trimmed[..i]
        case None => return "."
    }
}

/// 显示用短路径：/Volumes/data/…/deepGit
public func prettyPath(p: String, maxLen: Int64): String {
    if (p.size <= maxLen) {
        return p
    }
    let parts = p.split("/")
    if (parts.size <= 4) {
        return "…" + p[p.size - (maxLen - 1)..]
    }
    let tail = parts[parts.size - 2] + "/" + parts[parts.size - 1]
    return "…/" + tail
}

/// 确保目录存在
public func ensureDir(dir: String): Unit {
    let p = Path(dir)
    if (exists(p)) {
        return
    }
    try {
        Directory.create(p, recursive: true)
    } catch (e: Exception) {
        // 并发创建竞态（如钩子 track 与手动 update 同时首跑）：
        // 已存在视为成功，其余异常向上抛
        if (!exists(p)) {
            throw e
        }
    }
}

public func fileExists(p: String): Bool {
    return exists(Path(p))
}

public func isDirectoryPath(p: String): Bool {
    let path = Path(p)
    if (!exists(path)) {
        return false
    }
    return FileInfo(path).isDirectory()
}

/// 目录直接子项（不含递归）
public func listDir(p: String): ArrayList<FileInfo> {
    let out = ArrayList<FileInfo>()
    let path = Path(p)
    if (!exists(path)) {
        return out
    }
    try {
        for (info in Directory.readFrom(path)) {
            out.add(info)
        }
    } catch (e: Exception) {
        return out
    }
    return out
}

/// 原子写文件：先写临时文件再 rename
public func writeFileAtomic(filePath: String, content: String): Unit {
    ensureDir(dirname(filePath))
    let tmp = filePath + ".tmp-${getpid()}"
    File.writeTo(Path(tmp), content.toArray())
    let src = Path(tmp)
    let dst = Path(filePath)
    rename(src, to: dst, overwrite: true)
}

public func readFileText(filePath: String): Option<String> {
    let p = Path(filePath)
    if (!exists(p)) {
        return None
    }
    try {
        return Some(fromUtf8Lossy(File.readFrom(p)))
    } catch (e: Exception) {
        return None
    }
}

public func readFileTextOr(filePath: String, fallback: String): String {
    match (readFileText(filePath)) {
        case Some(s) => return s
        case None => return fallback
    }
}

public func removePathIfExists(filePath: String): Unit {
    let p = Path(filePath)
    if (exists(p)) {
        try {
            remove(p, recursive: true)
        } catch (e: Exception) {
            ()
        }
    }
}

public func appendLine(filePath: String, line: String): Unit {
    ensureDir(dirname(filePath))
    let p = Path(filePath)
    if (exists(p)) {
        File.appendTo(p, (line + "\n").toArray())
    } else {
        File.writeTo(p, (line + "\n").toArray())
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testNormalizePath(): Unit {
    @Assert(normalizePath("/a/b/../c") == "/a/c")
    @Assert(normalizePath("/a//b/./c") == "/a/b/c")
    @Assert(normalizePath("/../a") == "/a")
    @Assert(normalizePath("a/b") == "a/b")
}

@Test
func testBasenameDirname(): Unit {
    @Assert(basename("/a/b/c.txt") == "c.txt")
    @Assert(basename("/a/b/") == "b")
    @Assert(dirname("/a/b/c.txt") == "/a/b")
    @Assert(dirname("/x") == "/")
}

@Test
func testProjectIdStable(): Unit {
    let a = projectIdFor("/tmp/x")
    let b = projectIdFor("/tmp/x")
    let c = projectIdFor("/tmp/y")
    @Assert(a == b)
    @Assert(a != c)
    @Assert(a.startsWith("p_"))
    @Assert(a.size == 14)
}

@Test
func testProjectIdNormalizesSlashes(): Unit {
    @Assert(projectIdFor("/tmp//x/") == projectIdFor("/tmp/x"))
}

@Test
func testDeepgitHomeOverride(): Unit {
    let h = deepgitHome()
    @Assert(h.startsWith("/") || h.startsWith("~") == false)
    @Assert(!h.endsWith("/"))
}

@Test
func testPrettyPath(): Unit {
    let long = "/Volumes/data/dev/coding/deepcodeUI/deepGit/engine/src/util"
    let p = prettyPath(long, 30)
    @Assert(p.size <= 30)
    @Assert(prettyPath("/short", 30) == "/short")
}

@Test
func testExpandHome(): Unit {
    @Assert(expandHome("/abs") == "/abs")
    @Assert(expandHome("~").size > 1)
    @Assert(expandHome("~/x").endsWith("/x"))
}

@Test
func testResolvePath(): Unit {
    @Assert(resolvePath("b", "/a") == "/a/b")
    @Assert(resolvePath("../c", "/a/b") == "/a/c")
    @Assert(resolvePath("/x/y", "/a") == "/x/y")
}

@Test
func testResolveMacSymlink(): Unit {
    @Assert(resolveMacSymlink("/tmp") == "/private/tmp")
    @Assert(resolveMacSymlink("/tmp/a/b") == "/private/tmp/a/b")
    @Assert(resolveMacSymlink("/var/log") == "/private/var/log")
    @Assert(resolveMacSymlink("/Users/x") == "/Users/x")
    @Assert(resolveMacSymlink("/private/tmp/a") == "/private/tmp/a")
}

@Test
func testSamePath(): Unit {
    @Assert(samePath("/tmp/a", "/tmp/a"))
    @Assert(samePath("/tmp/a", "/private/tmp/a"))
    @Assert(samePath("/tmp/a//b/../c", "/tmp/a/c"))
    @Assert(!samePath("/tmp/a", "/tmp/b"))
    @Assert(!samePath("relative", "/tmp/relative"))
}
