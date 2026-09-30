// 手写 JSON 解析/序列化（零依赖）。对象保持插入顺序，保证状态文件稳定可 diff。
package deepgit.util

import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*

public enum JsonValue {
    | JNull
    | JBool(Bool)
    | JNum(Float64)
    | JStr(String)
    | JArr(ArrayList<JsonValue>)
    | JObj(ArrayList<(String, JsonValue)>)
}

public class Json {
    // ------------------------------ 构造 ------------------------------
    public static func obj(): JsonValue {
        return JObj(ArrayList<(String, JsonValue)>())
    }

    public static func arr(): JsonValue {
        return JArr(ArrayList<JsonValue>())
    }

    public static func of(v: Bool): JsonValue {
        return JBool(v)
    }

    public static func of(v: Int64): JsonValue {
        return JNum(Float64(v))
    }

    public static func of(v: Float64): JsonValue {
        return JNum(v)
    }

    public static func of(v: String): JsonValue {
        return JStr(v)
    }

    public static func null(): JsonValue {
        return JNull
    }

    public static func strArray(items: Array<String>): JsonValue {
        let a = ArrayList<JsonValue>()
        for (s in items) {
            a.add(JStr(s))
        }
        return JArr(a)
    }

    // ------------------------------ 读写 ------------------------------
    public static func set(o: JsonValue, key: String, value: JsonValue): Unit {
        match (o) {
            case JObj(m) =>
                var found = false
                for (i in 0..m.size) {
                    let (k, _) = m[i]
                    if (k == key) {
                        m[i] = (key, value)
                        found = true
                        break
                    }
                }
                if (!found) {
                    m.add((key, value))
                }
            case _ => ()
        }
    }

    public static func get(o: JsonValue, key: String): Option<JsonValue> {
        match (o) {
            case JObj(m) =>
                for ((k, v) in m) {
                    if (k == key) {
                        return Some(v)
                    }
                }
                return None
            case _ => return None
        }
    }

    /// 取字段，缺失时返回 JNull（避免 Option 解包噪音）
    public static func getOr(o: JsonValue, key: String): JsonValue {
        match (get(o, key)) {
            case Some(v) => return v
            case None => return JNull
        }
    }

    public static func has(o: JsonValue, key: String): Bool {
        return get(o, key).isSome()
    }

    public static func remove(o: JsonValue, key: String): Unit {
        match (o) {
            case JObj(m) =>
                var i = 0
                while (i < m.size) {
                    let (k, _) = m[i]
                    if (k == key) {
                        m.remove(at: i)
                    } else {
                        i += 1
                    }
                }
            case _ => ()
        }
    }

    public static func add(a: JsonValue, v: JsonValue): Unit {
        match (a) {
            case JArr(items) => items.add(v)
            case _ => ()
        }
    }

    // ------------------------------ 访问 ------------------------------
    public static func asStr(v: JsonValue): Option<String> {
        match (v) {
            case JStr(s) => return Some(s)
            case _ => return None
        }
    }

    public static func asNum(v: JsonValue): Option<Float64> {
        match (v) {
            case JNum(n) => return Some(n)
            case JBool(b) => return Some(if (b) { 1.0 } else { 0.0 })
            case _ => return None
        }
    }

    public static func asInt(v: JsonValue): Option<Int64> {
        match (asNum(v)) {
            case Some(n) => return Some(Int64(n))
            case None => return None
        }
    }

    public static func asBool(v: JsonValue): Option<Bool> {
        match (v) {
            case JBool(b) => return Some(b)
            case _ => return None
        }
    }

    public static func asArr(v: JsonValue): Option<ArrayList<JsonValue>> {
        match (v) {
            case JArr(a) => return Some(a)
            case _ => return None
        }
    }

    public static func asObj(v: JsonValue): Option<ArrayList<(String, JsonValue)>> {
        match (v) {
            case JObj(m) => return Some(m)
            case _ => return None
        }
    }

    public static func isNull(v: JsonValue): Bool {
        match (v) {
            case JNull => return true
            case _ => return false
        }
    }

    /// 取字符串字段，缺省返回 fallback
    public static func strAt(o: JsonValue, key: String, fallback: String): String {
        match (get(o, key)) {
            case Some(v) => match (asStr(v)) {
                case Some(s) => return s
                case None => return fallback
            }
            case None => return fallback
        }
    }

    public static func strAtOpt(o: JsonValue, key: String): Option<String> {
        match (get(o, key)) {
            case Some(v) => return asStr(v)
            case None => return None
        }
    }

    public static func intAt(o: JsonValue, key: String, fallback: Int64): Int64 {
        match (get(o, key)) {
            case Some(v) => match (asInt(v)) {
                case Some(n) => return n
                case None => return fallback
            }
            case None => return fallback
        }
    }

    public static func numAt(o: JsonValue, key: String, fallback: Float64): Float64 {
        match (get(o, key)) {
            case Some(v) => match (asNum(v)) {
                case Some(n) => return n
                case None => return fallback
            }
            case None => return fallback
        }
    }

    public static func boolAt(o: JsonValue, key: String, fallback: Bool): Bool {
        match (get(o, key)) {
            case Some(v) => match (asBool(v)) {
                case Some(b) => return b
                case None => return fallback
            }
            case None => return fallback
        }
    }

    public static func arrAt(o: JsonValue, key: String): ArrayList<JsonValue> {
        match (get(o, key)) {
            case Some(v) => match (asArr(v)) {
                case Some(a) => return a
                case None => return ArrayList<JsonValue>()
            }
            case None => return ArrayList<JsonValue>()
        }
    }

    public static func strArrAt(o: JsonValue, key: String): ArrayList<String> {
        let out = ArrayList<String>()
        for (v in arrAt(o, key)) {
            match (asStr(v)) {
                case Some(s) => out.add(s)
                case None => ()
            }
        }
        return out
    }

    // ------------------------------ 序列化 ------------------------------
    public static func compact(v: JsonValue): String {
        let sb = StringBuilder()
        writeValue(v, sb, 0, false)
        return sb.toString()
    }

    public static func pretty(v: JsonValue): String {
        let sb = StringBuilder()
        writeValue(v, sb, 0, true)
        return sb.toString()
    }

    static func writeValue(v: JsonValue, sb: StringBuilder, level: Int64, indent: Bool): Unit {
        match (v) {
            case JNull => sb.append("null")
            case JBool(b) => sb.append(if (b) { "true" } else { "false" })
            case JNum(n) =>
                if (n.isNaN() || n.isInf()) {
                    sb.append("null")
                } else if (n == Float64(Int64(n))) {
                    sb.append("${Int64(n)}")
                } else {
                    sb.append("${n}")
                }
            case JStr(s) => writeString(s, sb)
            case JArr(items) =>
                if (items.isEmpty()) {
                    sb.append("[]")
                    return
                }
                sb.append("[")
                for (i in 0..items.size) {
                    if (i > 0) {
                        sb.append(",")
                    }
                    if (indent) {
                        sb.append("\n")
                        appendIndent(sb, level + 1)
                    }
                    writeValue(items[i], sb, level + 1, indent)
                }
                if (indent) {
                    sb.append("\n")
                    appendIndent(sb, level)
                }
                sb.append("]")
            case JObj(m) =>
                if (m.isEmpty()) {
                    sb.append("{}")
                    return
                }
                sb.append("{")
                for (i in 0..m.size) {
                    if (i > 0) {
                        sb.append(",")
                    }
                    if (indent) {
                        sb.append("\n")
                        appendIndent(sb, level + 1)
                    }
                    let (k, val) = m[i]
                    writeString(k, sb)
                    sb.append(if (indent) { ": " } else { ":" })
                    writeValue(val, sb, level + 1, indent)
                }
                if (indent) {
                    sb.append("\n")
                    appendIndent(sb, level)
                }
                sb.append("}")
        }
    }

    static func appendIndent(sb: StringBuilder, level: Int64): Unit {
        for (_ in 0..(level * 2)) {
            sb.append(" ")
        }
    }

    static func writeString(s: String, sb: StringBuilder): Unit {
        sb.append("\"")
        for (r in s.runes()) {
            let cp = UInt32(r)
            if (cp == 0x22u32) {
                sb.append("\\\"")
            } else if (cp == 0x5cu32) {
                sb.append("\\\\")
            } else if (cp == 0x0au32) {
                sb.append("\\n")
            } else if (cp == 0x0du32) {
                sb.append("\\r")
            } else if (cp == 0x09u32) {
                sb.append("\\t")
            } else if (cp == 0x08u32) {
                sb.append("\\b")
            } else if (cp == 0x0cu32) {
                sb.append("\\f")
            } else if (cp < 0x20u32) {
                sb.append("\\u")
                sb.append(hex4(UInt8(cp)))
            } else {
                sb.append(r.toString())
            }
        }
        sb.append("\"")
    }

    static func hex4(b: UInt8): String {
        let chars = "0123456789abcdef"
        let hi = Int64(b >> 4)
        let lo = Int64(b & 0x0fu8)
        return chars[hi..hi + 1] + chars[lo..lo + 1]
    }

    // ------------------------------ 解析 ------------------------------
    public static func parse(input: String): Option<JsonValue> {
        let bytes = input.toArray()
        let p = JsonParser(bytes, 0)
        p.skipWs()
        match (p.value()) {
            case Some(v) =>
                p.skipWs()
                if (p.pos != bytes.size) {
                    return None
                }
                return Some(v)
            case None => return None
        }
    }
}

class JsonParser {
    let b: Array<UInt8>
    var pos: Int64

    init(b: Array<UInt8>, pos: Int64) {
        this.b = b
        this.pos = pos
    }

    func peek(): Option<UInt8> {
        if (this.pos < this.b.size) {
            return Some(this.b[this.pos])
        }
        return None
    }

    func bump(): Option<UInt8> {
        let c = this.peek()
        match (c) {
            case Some(_) => this.pos += 1
            case None => ()
        }
        return c
    }

    func skipWs(): Unit {
        while (true) {
            match (this.peek()) {
                case Some(c) =>
                    if (c == 0x20u8 || c == 0x09u8 || c == 0x0au8 || c == 0x0du8) {
                        this.pos += 1
                    } else {
                        break
                    }
                case None => break
            }
        }
    }

    func value(): Option<JsonValue> {
        this.skipWs()
        match (this.peek()) {
            case Some(c) =>
                if (c == 0x7bu8) {
                    return this.object()
                } else if (c == 0x5bu8) {
                    return this.array()
                } else if (c == 0x22u8) {
                    match (this.string()) {
                        case Some(s) => return Some(JStr(s))
                        case None => return None
                    }
                } else if (c == 0x74u8) {
                    return if (this.lit("true")) { Some(JBool(true)) } else { None }
                } else if (c == 0x66u8) {
                    return if (this.lit("false")) { Some(JBool(false)) } else { None }
                } else if (c == 0x6eu8) {
                    return if (this.lit("null")) { Some(JNull) } else { None }
                } else if (c == 0x2du8 || (c >= 0x30u8 && c <= 0x39u8)) {
                    return this.number()
                } else {
                    return None
                }
            case None => return None
        }
    }

    func lit(s: String): Bool {
        let target = s.toArray()
        if (this.pos + target.size > this.b.size) {
            return false
        }
        for (i in 0..target.size) {
            if (this.b[this.pos + i] != target[i]) {
                return false
            }
        }
        this.pos += target.size
        return true
    }

    func object(): Option<JsonValue> {
        this.bump()  // {
        let m = ArrayList<(String, JsonValue)>()
        this.skipWs()
        match (this.peek()) {
            case Some(c) =>
                if (c == 0x7du8) {
                    this.bump()
                    return Some(JObj(m))
                } else if (c == 0x22u8) {
                    // 空对象以外的情况继续
                } else {
                    return None
                }
            case None => return None
        }
        while (true) {
            this.skipWs()
            match (this.string()) {
                case Some(key) =>
                    this.skipWs()
                    match (this.bump()) {
                        case Some(c) =>
                            if (c != 0x3au8) {
                                return None
                            }
                        case None => return None
                    }
                    match (this.value()) {
                        case Some(v) => m.add((key, v))
                        case None => return None
                    }
                    this.skipWs()
                    match (this.bump()) {
                        case Some(c) =>
                            if (c == 0x2cu8) {
                                continue
                            } else if (c == 0x7du8) {
                                break
                            } else {
                                return None
                            }
                        case None => return None
                    }
                case None => return None
            }
        }
        return Some(JObj(m))
    }

    func array(): Option<JsonValue> {
        this.bump()  // [
        let a = ArrayList<JsonValue>()
        this.skipWs()
        match (this.peek()) {
            case Some(c) =>
                if (c == 0x5du8) {
                    this.bump()
                    return Some(JArr(a))
                }
            case None => ()
        }
        while (true) {
            match (this.value()) {
                case Some(v) => a.add(v)
                case None => return None
            }
            this.skipWs()
            match (this.bump()) {
                case Some(c) =>
                    if (c == 0x2cu8) {
                        continue
                    } else if (c == 0x5du8) {
                        break
                    } else {
                        return None
                    }
                case None => return None
            }
        }
        return Some(JArr(a))
    }

    func string(): Option<String> {
        match (this.bump()) {
            case Some(c) =>
                if (c != 0x22u8) {
                    return None
                }
            case None => return None
        }
        let sb = StringBuilder()
        var done = false
        while (!done) {
            match (this.bump()) {
                case Some(c) =>
                    if (c == 0x22u8) {
                        return Some(sb.toString())
                    } else if (c == 0x5cu8) {
                        match (this.bump()) {
                            case Some(e) =>
                                match (e) {
                                    case 0x22u8 => sb.append("\"")
                                    case 0x5cu8 => sb.append("\\")
                                    case 0x2fu8 => sb.append("/")
                                    case 0x62u8 => sb.append("\u{8}")
                                    case 0x66u8 => sb.append("\u{c}")
                                    case 0x6eu8 => sb.append("\n")
                                    case 0x72u8 => sb.append("\r")
                                    case 0x74u8 => sb.append("\t")
                                    case 0x75u8 =>
                                        match (this.hex4()) {
                                            case Some(cp) =>
                                                sb.append(Rune(cp).toString())
                                            case None => return None
                                        }
                                    case _ => return None
                                }
                            case None => return None
                        }
                    } else if (c < 0x20u8) {
                        return None
                    } else if (c < 0x80u8) {
                        sb.append(Rune(UInt32(c)).toString())
                    } else {
                        // UTF-8 多字节：回退一个字节，按 Rune 解码
                        this.pos -= 1
                        let rest = this.b[this.pos..]
                        match (runeFromUtf8(rest)) {
                            case Some(pair) =>
                                let (r, size) = pair
                                sb.append(r.toString())
                                this.pos += size
                            case None => return None
                        }
                    }
                case None =>
                    done = true
            }
        }
        return None
    }

    func hex4(): Option<UInt32> {
        var v: UInt32 = 0
        for (_ in 0..4) {
            match (this.bump()) {
                case Some(c) =>
                    var d: UInt32
                    if (c >= 0x30u8 && c <= 0x39u8) {
                        d = UInt32(c - 0x30u8)
                    } else if (c >= 0x61u8 && c <= 0x66u8) {
                        d = UInt32(c - 0x61u8 + 10u8)
                    } else if (c >= 0x41u8 && c <= 0x46u8) {
                        d = UInt32(c - 0x41u8 + 10u8)
                    } else {
                        return None
                    }
                    v = v * 16u32 + d
                case None => return None
            }
        }
        return Some(v)
    }

    func number(): Option<JsonValue> {
        let start = this.pos
        if (this.peek() == Some(0x2du8)) {
            this.bump()
        }
        while (true) {
            match (this.peek()) {
                case Some(c) =>
                    if (c >= 0x30u8 && c <= 0x39u8) {
                        this.pos += 1
                    } else {
                        break
                    }
                case None => break
            }
        }
        if (this.peek() == Some(0x2eu8)) {
            this.bump()
            while (true) {
                match (this.peek()) {
                    case Some(c) =>
                        if (c >= 0x30u8 && c <= 0x39u8) {
                            this.pos += 1
                        } else {
                            break
                        }
                    case None => break
                }
            }
        }
        match (this.peek()) {
            case Some(c) =>
                if (c == 0x65u8 || c == 0x45u8) {
                    this.bump()
                    match (this.peek()) {
                        case Some(s) =>
                            if (s == 0x2bu8 || s == 0x2du8) {
                                this.bump()
                            }
                        case None => ()
                    }
                    while (true) {
                        match (this.peek()) {
                            case Some(c2) =>
                                if (c2 >= 0x30u8 && c2 <= 0x39u8) {
                                    this.pos += 1
                                } else {
                                    break
                                }
                            case None => break
                        }
                    }
                }
            case None => ()
        }
        let s = String.fromUtf8(this.b[start..this.pos])
        match (parseFloatOpt(s)) {
            case Some(n) => return Some(JNum(n))
            case None => return None
        }
    }
}

/// 从 UTF-8 字节序列解出一个 Rune（返回 rune 与消耗字节数）
func runeFromUtf8(b: Array<UInt8>): Option<(Rune, Int64)> {
    if (b.size == 0) {
        return None
    }
    let c0 = b[0]
    if (c0 < 0x80u8) {
        return Some((Rune(UInt32(c0)), 1))
    }
    var need: Int64 = 0
    var cp: UInt32 = 0
    if (c0 >= 0xc0u8 && c0 < 0xe0u8) {
        need = 2
        cp = UInt32(c0 & 0x1fu8)
    } else if (c0 >= 0xe0u8 && c0 < 0xf0u8) {
        need = 3
        cp = UInt32(c0 & 0x0fu8)
    } else if (c0 >= 0xf0u8 && c0 < 0xf8u8) {
        need = 4
        cp = UInt32(c0 & 0x07u8)
    } else {
        return None
    }
    if (b.size < need) {
        return None
    }
    for (i in 1..need) {
        let c = b[i]
        if (c < 0x80u8 || c >= 0xc0u8) {
            return None
        }
        cp = (cp << 6) | UInt32(c & 0x3fu8)
    }
    return Some((Rune(cp), need))
}

func parseFloatOpt(s: String): Option<Float64> {
    try {
        return Some(Float64.parse(s))
    } catch (e: Exception) {
        return None
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testJsonParseBasic(): Unit {
    let v = Json.parse("{\"a\": 1, \"b\": [true, null, \"x\"], \"c\": {\"d\": 1.5}}")
    @Assert(v.isSome())
    let o = v.getOrThrow()
    @Assert(Json.intAt(o, "a", -1) == 1)
    @Assert(Json.arrAt(o, "b").size == 3)
    match (Json.get(o, "c")) {
        case Some(c) => @Assert(Json.numAt(c, "d", 0.0) == 1.5)
        case None => @Fail("missing c")
    }
}

@Test
func testJsonCjkAndEscapes(): Unit {
    let v = Json.parse("{\"s\":\"你好 \\\"世界\\\"\\n\\t\\\\ \\u4e2d\\u6587\"}")
    @Assert(v.isSome())
    let s = Json.strAt(v.getOrThrow(), "s", "")
    @Assert(s.contains("你好"))
    @Assert(s.contains("\"世界\""))
    @Assert(s.contains("\n"))
    @Assert(s.contains("中"))
}

@Test
func testJsonRoundTrip(): Unit {
    let o = Json.obj()
    Json.set(o, "z", Json.of(1))
    Json.set(o, "a", Json.of("中\"文\\"))
    Json.set(o, "n", Json.null())
    Json.set(o, "arr", Json.strArray(["x", "y"]))
    let text = Json.compact(o)
    @Assert(text.startsWith("{\"z\":1,\"a\":"))
    let back = Json.parse(text)
    @Assert(back.isSome())
    @Assert(Json.strAt(back.getOrThrow(), "a", "") == "中\"文\\")
    @Assert(Json.arrAt(back.getOrThrow(), "arr").size == 2)
    let pretty = Json.pretty(o)
    @Assert(Json.parse(pretty).isSome())
}

@Test
func testJsonErrors(): Unit {
    @Assert(Json.parse("{").isNone())
    @Assert(Json.parse("{} trailing").isNone())
    @Assert(Json.parse("{\"a\": }").isNone())
    @Assert(Json.parse("[1,2").isNone())
}

@Test
func testJsonIntegralNumbers(): Unit {
    let o = Json.obj()
    Json.set(o, "i", Json.of(42))
    @Assert(Json.compact(o) == "{\"i\":42}")
}
