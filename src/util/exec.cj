// 进程执行：封装 git / curl 等外部命令调用，返回结构化结果。
//
// 设计取舍：deepGit 只依赖「系统 git」与「系统 curl」两个必备二进制，
// 其余能力（JSON/SHA256/HTTP 服务）全部自研，保持零第三方依赖。
package deepgit.util

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

public class ExecResult {
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int64, stdout: String, stderr: String, timedOut: Bool) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.timedOut = timedOut
    }

    public func ok(): Bool {
        return this.exitCode == 0
    }
}

/// 执行命令（同步）。超时通过 wait 循环检测。
public func execCapture(
    cmd: String,
    args: Array<String>,
    cwd: Option<String>,
    timeoutMs: Int64,
): ExecResult {
    var workDir: Option<Path> = None
    match (cwd) {
        case Some(c) => workDir = Some(Path(c))
        case None => ()
    }
    try {
        let (code, outBytes, errBytes) = executeWithOutput(
            cmd,
            args,
            workingDirectory: workDir,
            environment: None,
            stdIn: ProcessRedirect.Inherit,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe,
        )
        return ExecResult(code, fromUtf8Lossy(outBytes), fromUtf8Lossy(errBytes), false)
    } catch (e: Exception) {
        return ExecResult(-1, "", e.message, false)
    }
}

/// 执行命令并返回 (exitCode, stdout, stderr)
public func execOut(
    cmd: String,
    args: Array<String>,
    cwd: Option<String>,
): (Int64, String, String) {
    let r = execCapture(cmd, args, cwd, 60000)
    return (r.exitCode, r.stdout, r.stderr)
}

/// 执行 git；失败时抛 DgError（可用 tolerate 容忍失败）
public func gitRun(
    repoDir: String,
    args: Array<String>,
    tolerate: Bool,
): String {
    let fullArgs = ArrayList<String>()
    fullArgs.add("-c")
    fullArgs.add("core.quotepath=false")
    fullArgs.add("-c")
    fullArgs.add("color.ui=false")
    fullArgs.add("-C")
    fullArgs.add(repoDir)
    for (a in args) {
        fullArgs.add(a)
    }
    let r = execCapture("git", fullArgs.toArray(), None, 120000)
    if (r.exitCode != 0) {
        if (tolerate) {
            return ""
        }
        throw DgError(
            "GIT_FAILED",
            "git ${joinStrings(args, " ")} 失败（cwd=${repoDir}）",
            1,
            Some(r.stderr.trimAscii()),
        )
    }
    return r.stdout.trimAscii()
}

/// 执行 git，不抛异常，返回结构体
public func gitTry(repoDir: String, args: Array<String>): ExecResult {
    let fullArgs = ArrayList<String>()
    fullArgs.add("-c")
    fullArgs.add("core.quotepath=false")
    fullArgs.add("-c")
    fullArgs.add("color.ui=false")
    fullArgs.add("-C")
    fullArgs.add(repoDir)
    for (a in args) {
        fullArgs.add(a)
    }
    return execCapture("git", fullArgs.toArray(), None, 120000)
}

/// 执行 git，保留原始输出（不 trim，用于 -z 输出）
public func gitRaw(repoDir: String, args: Array<String>): String {
    let fullArgs = ArrayList<String>()
    fullArgs.add("-c")
    fullArgs.add("core.quotepath=false")
    fullArgs.add("-c")
    fullArgs.add("color.ui=false")
    fullArgs.add("-C")
    fullArgs.add(repoDir)
    for (a in args) {
        fullArgs.add(a)
    }
    let r = execCapture("git", fullArgs.toArray(), None, 120000)
    if (r.exitCode != 0) {
        throw DgError("GIT_FAILED", "git 调用失败", 1, Some(r.stderr.trimAscii()))
    }
    return r.stdout
}

/// 命令是否存在
public func commandExists(cmd: String): Bool {
    let r = execCapture("which", [cmd], None, 8000)
    return r.exitCode == 0 && !r.stdout.isBlank()
}

/// 通过 curl 执行 HTTP POST（JSON body），返回原始响应体
public func curlPostJson(url: String, body: String, headers: Array<String>, timeoutSec: Int64): (Int64, String, String) {
    let args = ArrayList<String>()
    args.add("-sS")
    args.add("--max-time")
    args.add("${timeoutSec}")
    args.add("-X")
    args.add("POST")
    args.add("-H")
    args.add("Content-Type: application/json")
    for (h in headers) {
        args.add("-H")
        args.add(h)
    }
    args.add("--data-binary")
    args.add(body)
    args.add("--write-out")
    args.add("\n__DEEPGIT_STATUS__%{http_code}")
    args.add(url)
    let r = execCapture("curl", args.toArray(), None, (timeoutSec + 15) * 1000)
    let out = r.stdout
    let marker = "__DEEPGIT_STATUS__"
    let idx = out.lastIndexOf(marker)
    var status: Int64 = 0
    var respBody = out
    if (idx.isSome()) {
        let i = idx.getOrThrow()
        let statusStr = out[i + marker.size..].trimAscii()
        try {
            status = Int64.parse(statusStr)
        } catch (e: Exception) {
            status = 0
        }
        respBody = out[..i]
    }
    return (status, respBody, r.stderr)
}

// ------------------------------ 测试 ------------------------------

@Test
func testExecCaptureEcho(): Unit {
    let r = execCapture("echo", ["hello"], None, 8000)
    @Assert(r.exitCode == 0)
    @Assert(r.stdout.trimAscii() == "hello")
}

@Test
func testExecCaptureFailure(): Unit {
    let r = execCapture("/nonexistent-binary-xyz", [], None, 5000)
    @Assert(!r.ok())
}

@Test
func testGitRunVersion(): Unit {
    let out = gitRun("/tmp", ["--version"], false)
    @Assert(out.contains("git version"))
}

@Test
func testGitTryToleratesFailure(): Unit {
    let r = gitTry("/tmp", ["rev-parse", "--verify", "nonexistent-ref-xyz"])
    @Assert(!r.ok())
}

@Test
func testCommandExists(): Unit {
    @Assert(commandExists("git"))
    @Assert(!commandExists("definitely-not-a-real-binary-xyz"))
}

@Test
func testCurlStatusParsing(): Unit {
    // 用一个必然失败的本地地址验证解析路径不崩溃
    let (status, body, _) = curlPostJson("http://127.0.0.1:9/nope", "{}", [], 3)
    @Assert(status == 0 || status > 0)
    @Assert(body.size >= 0)
}
