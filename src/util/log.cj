// 日志与终端输出：人类可读信息进 stderr，数据进 stdout。
package deepgit.util

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*

public class Log {
    static var quiet: Bool = false
    static var verbose: Bool = false
    static var useColor: Bool = true

    public static func setQuiet(q: Bool): Unit {
        Log.quiet = q
    }

    public static func setVerbose(v: Bool): Unit {
        Log.verbose = v
    }

    public static func setColor(c: Bool): Unit {
        Log.useColor = c
    }

    public static func isVerbose(): Bool {
        return Log.verbose
    }

    static func paint(code: String, s: String): String {
        if (!Log.useColor) {
            return s
        }
        return "\u{1b}[${code}m${s}\u{1b}[0m"
    }

    public static func info(msg: String): Unit {
        if (!Log.quiet) {
            eprintln(msg)
        }
    }

    public static func step(msg: String): Unit {
        if (!Log.quiet) {
            eprintln(paint("36", "›") + " " + msg)
        }
    }

    public static func ok(msg: String): Unit {
        if (!Log.quiet) {
            eprintln(paint("32", "✓") + " " + msg)
        }
    }

    public static func warn(msg: String): Unit {
        if (!Log.quiet) {
            eprintln(paint("33", "!") + " " + msg)
        }
    }

    public static func error(msg: String): Unit {
        eprintln(paint("31", "✗") + " " + msg)
    }

    public static func debug(msg: String): Unit {
        if (Log.verbose && !Log.quiet) {
            eprintln(paint("90", "·") + " " + msg)
        }
    }

    public static func dim(msg: String): Unit {
        if (!Log.quiet) {
            eprintln(paint("90", msg))
        }
    }
}

/// 打印数据（stdout）
public func printOut(line: String): Unit {
    println(line)
}

/// 对齐表格渲染
public func renderTable(headers: Array<String>, rows: Array<Array<String>>): String {
    let colCount = headers.size
    let widths = Array<Int64>(colCount, repeat: 0)
    for (i in 0..colCount) {
        widths[i] = displayWidth(headers[i])
    }
    for (row in rows) {
        for (i in 0..colCount) {
            if (i < row.size) {
                let w = displayWidth(row[i])
                if (w > widths[i]) {
                    widths[i] = w
                }
            }
        }
    }
    let sb = StringBuilder()
    // header
    for (i in 0..colCount) {
        sb.append(padTo(headers[i], widths[i]))
        if (i < colCount - 1) {
            sb.append("  ")
        }
    }
    sb.append("\n")
    // separator
    for (i in 0..colCount) {
        for (_ in 0..widths[i]) {
            sb.append("─")
        }
        if (i < colCount - 1) {
            sb.append("  ")
        }
    }
    sb.append("\n")
    for (row in rows) {
        for (i in 0..colCount) {
            let cell = if (i < row.size) { row[i] } else { "" }
            sb.append(padTo(cell, widths[i]))
            if (i < colCount - 1) {
                sb.append("  ")
            }
        }
        sb.append("\n")
    }
    return sb.toString().trimAsciiEnd()
}

func padTo(s: String, width: Int64): String {
    let w = displayWidth(s)
    if (w >= width) {
        return s
    }
    let sb = StringBuilder(s)
    for (_ in 0..(width - w)) {
        sb.append(" ")
    }
    return sb.toString()
}

public func formatBytes(n: Int64): String {
    if (n < 0) {
        return "-"
    }
    var v = Float64(n)
    let units = ["B", "KB", "MB", "GB"]
    var i = 0
    while (v >= 1024.0 && i < 3) {
        v = v / 1024.0
        i += 1
    }
    if (i == 0) {
        return "${n}B"
    }
    return "${Int64(v * 10.0) / 10}.${Int64(v * 10.0) % 10}${units[i]}"
}

// ------------------------------ 测试 ------------------------------

@Test
func testRenderTableAlignsByWidth(): Unit {
    let t = renderTable(["a", "名字"], [["1", "中文"], ["22", "x"]])
    @Assert(t.contains("a"))
    @Assert(t.contains("名字"))
    @Assert(t.contains("中文"))
}

@Test
func testRenderTableEmptyRows(): Unit {
    let t = renderTable(["h"], [])
    @Assert(t.contains("h"))
}

@Test
func testFormatBytes(): Unit {
    @Assert(formatBytes(512) == "512B")
    @Assert(formatBytes(2048).contains("KB"))
    @Assert(formatBytes(-1) == "-")
}

@Test
func testDisplayWidthPadToCJK(): Unit {
    @Assert(displayWidth(padTo("中", 4)) == 4)
    @Assert(displayWidth(padTo("abcd", 4)) == 4)
}
