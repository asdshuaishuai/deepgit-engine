// 时间工具：格式化、解析、相对时间、天数差。
//
// 设计取舍：ISO 字符串的时间显示采用「字符串切片」而非时区换算——git 提交时间
// 由提交者时区决定，忠实显示原始值比转成本地时间更有意义。
package deepgit.util

import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

public func nowIso(): String {
    return DateTime.now().toString()
}

/// 解析 ISO-8601（宽松）：返回毫秒时间戳
public func parseIsoMillis(s: String): Option<Int64> {
    try {
        let dt = DateTime.parse(s)
        return Some(dt.toUnixTimeStamp().toMilliseconds())
    } catch (e: Exception) {
        return None
    }
}

/// 本地 "YYYY-MM-DD HH:mm"（基于 ISO 字符串切片，不做时区换算）
public func formatDateTime(iso: String): String {
    let s = iso.trimAscii()
    if (s.size < 16) {
        return "-"
    }
    if (s[4..5] != "-" || s[7..8] != "-") {
        return "-"
    }
    return s[..10] + " " + s[11..16]
}

public func formatDateOnly(iso: String): String {
    let s = iso.trimAscii()
    if (s.size < 10) {
        return "-"
    }
    return s[..10]
}

/// 距今毫秒数（正数表示过去）
public func millisSince(iso: String): Int64 {
    match (parseIsoMillis(iso)) {
        case Some(ms) => return DateTime.now().toUnixTimeStamp().toMilliseconds() - ms
        case None => return Int64.Max
    }
}

public func daysSince(iso: String): Float64 {
    let ms = millisSince(iso)
    if (ms == Int64.Max) {
        return Float64.Inf
    }
    return Float64(ms) / 86400000.0
}

/// "3 分钟前" / "2 天前"
public func timeAgo(iso: String, lang: String): String {
    let zh = lang != "en"
    let ms = millisSince(iso)
    if (ms == Int64.Max) {
        return "-"
    }
    if (ms < 0) {
        return if (zh) { "刚刚" } else { "just now" }
    }
    let sec = ms / 1000
    if (sec < 60) {
        return if (zh) { "刚刚" } else { "just now" }
    }
    let min = sec / 60
    if (min < 60) {
        return if (zh) { "${min} 分钟前" } else { "${min}m ago" }
    }
    let hours = min / 60
    if (hours < 24) {
        return if (zh) { "${hours} 小时前" } else { "${hours}h ago" }
    }
    let days = hours / 24
    if (days < 30) {
        return if (zh) { "${days} 天前" } else { "${days}d ago" }
    }
    let months = days / 30
    if (months < 12) {
        return if (zh) { "${months} 个月前" } else { "${months}mo ago" }
    }
    return if (zh) { "${months / 12} 年前" } else { "${months / 12}y ago" }
}

/// 当前本地时间戳（毫秒）
public func nowMillis(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}

/// 生成文件名安全的本地时间戳：2026-09-30T11-22-33
public func fileTimestamp(): String {
    let dt = DateTime.now()
    return "${pad4(dt.year)}-${pad2(monthToInt(dt.month))}-${pad2(dt.dayOfMonth)}T${pad2(dt.hour)}-${pad2(dt.minute)}-${pad2(dt.second)}"
}

func monthToInt(m: Month): Int64 {
    match (m) {
        case Month.January => return 1
        case Month.February => return 2
        case Month.March => return 3
        case Month.April => return 4
        case Month.May => return 5
        case Month.June => return 6
        case Month.July => return 7
        case Month.August => return 8
        case Month.September => return 9
        case Month.October => return 10
        case Month.November => return 11
        case Month.December => return 12
    }
}

public func pad2(v: Int64): String {
    if (v < 10) {
        return "0${v}"
    }
    return "${v}"
}

public func pad4(v: Int64): String {
    if (v < 10) {
        return "000${v}"
    } else if (v < 100) {
        return "00${v}"
    } else if (v < 1000) {
        return "0${v}"
    }
    return "${v}"
}

// ------------------------------ 测试 ------------------------------

@Test
func testTimeAgoBasic(): Unit {
    let now = nowIso()
    @Assert(timeAgo(now, "zh") == "刚刚")
    @Assert(timeAgo(now, "en") == "just now")
}

@Test
func testFormatDateTime(): Unit {
    @Assert(formatDateTime("2026-09-30T10:00:00+08:00") == "2026-09-30 10:00")
    @Assert(formatDateTime("bogus") == "-")
    @Assert(formatDateOnly("2026-09-30T10:00:00+08:00") == "2026-09-30")
}

@Test
func testDaysSince(): Unit {
    let d = daysSince(nowIso())
    @Assert(d > -0.5 && d < 0.5)
    @Assert(daysSince("bad") == Float64.Inf)
}

@Test
func testFileTimestampShape(): Unit {
    let ts = fileTimestamp()
    @Assert(ts.size == 19)
    @Assert(ts.contains("T"))
}

@Test
func testPadHelpers(): Unit {
    @Assert(pad2(3) == "03")
    @Assert(pad2(13) == "13")
    @Assert(pad4(7) == "0007")
    @Assert(pad4(2026) == "2026")
}

@Test
func testParseIsoMillis(): Unit {
    @Assert(parseIsoMillis("2026-09-30T10:00:00+08:00").isSome())
    @Assert(parseIsoMillis("not-a-date").isNone())
}

@Test
func testFormatDateTimeReadable(): Unit {
    let f = formatDateTime("2026-09-30T13:05:00Z")
    @Assert(!f.isEmpty())
    @Assert(!f.contains("T"))
}
