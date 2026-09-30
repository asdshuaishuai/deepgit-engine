// 统一错误类型与结果封装。
package deepgit.util

import std.unittest.*
import std.unittest.testmacro.*

public class DgError <: Exception {
    public let code: String
    public let msgText: String
    public let exitCode: Int64
    public let details: Option<String>

    public init(code: String, message: String) {
        super(message)
        this.code = code
        this.msgText = message
        this.exitCode = 1
        this.details = None
    }

    public init(code: String, message: String, exitCode: Int64, details: Option<String>) {
        super(message)
        this.code = code
        this.msgText = message
        this.exitCode = exitCode
        this.details = details
    }

    public static func usage(message: String): DgError {
        return DgError("USAGE", message, 2, None)
    }

    public static func notFound(message: String): DgError {
        return DgError("NOT_FOUND", message, 1, None)
    }

    public static func git(message: String): DgError {
        return DgError("GIT_FAILED", message, 1, None)
    }

    public func withDetails(d: String): DgError {
        return DgError(this.code, this.msgText, this.exitCode, Some(d))
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "code", Json.of(this.code))
        Json.set(o, "message", Json.of(this.msgText))
        match (this.details) {
            case Some(d) => Json.set(o, "details", Json.of(d))
            case None => ()
        }
        return o
    }

    public override func toString(): String {
        return "[${this.code}] ${this.msgText}"
    }
}

/// 在上下文失败信息中包装底层错误，保留原始 code。
public func chainError(context: String, e: Exception): DgError {
    match (e as DgError) {
        case Some(de) =>
            return DgError(de.code, "${context}：${de.msgText}", de.exitCode, de.details)
        case None =>
            return DgError("UNEXPECTED", "${context}：${e.message}", 1, None)
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testErrorJson(): Unit {
    let e = DgError("X", "boom").withDetails("d")
    let j = e.toJson()
    @Assert(Json.strAt(j, "code", "") == "X")
    @Assert(Json.strAt(j, "details", "") == "d")
    @Assert(Json.strAt(j, "message", "") == "boom")
}

@Test
func testErrorExitCodes(): Unit {
    @Assert(DgError.usage("u").exitCode == 2)
    @Assert(DgError.notFound("n").exitCode == 1)
}

@Test
func testChainError(): Unit {
    let inner = DgError("INNER", "cause")
    let wrapped = chainError("while doing x", inner)
    @Assert(wrapped.code == "INNER")
    @Assert(wrapped.msgText.contains("while doing x"))
    @Assert(wrapped.msgText.contains("cause"))
}

@Test
func testChainErrorNonDg(): Unit {
    let plain = Exception("plain failure")
    let wrapped = chainError("ctx", plain)
    @Assert(wrapped.code == "UNEXPECTED")
    @Assert(wrapped.msgText.contains("plain failure"))
}
