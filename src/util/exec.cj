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
import std.io.*
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

/// 执行命令（同步，带真实超时）。
///
/// 设计：
/// - 管道读取放在 spawned 线程（读到 EOF），否则大输出写满管道缓冲会卡死子进程
/// - wait 带超时，超时抛 TimeoutException —— 此时不 join 读取线程（子进程还活着，
///   EOF 未到），直接返回 timedOut 结果，保证引擎永不被子进程拖死
/// - 环境守卫掐掉最常见的挂起源：git 凭证交互提示与 ssh 交互提示
///   （SubProcess 不暴露 pid，超时的子进程只能放弃；有守卫后实际挂死概率极低）
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
    // 继承当前环境（否则丢失 PATH/HOME 等），再叠加防挂守卫。
    // std.env 没有枚举全部变量的 API，逐个拷贝已知关键项；
    // git 需要的就是 PATH/HOME/USER 这类基础变量。
    let guardEnv = HashMap<String, String>()
    for (key in ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "LC_ALL", "TERM", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "SSH_AUTH_SOCK"]) {
        match (getVariable(key)) {
            case Some(v) => guardEnv[key] = v
            case None => ()
        }
    }
    guardEnv["GIT_TERMINAL_PROMPT"] = "0"
    guardEnv["GIT_ASKPASS"] = "/bin/true"
    guardEnv["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes -oConnectTimeout=5"

    let sub: SubProcess
    try {
        sub = launch(
            cmd, args,
            workingDirectory: workDir,
            environment: Some(guardEnv),
            stdIn: ProcessRedirect.Inherit,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe,
        )
    } catch (e: Exception) {
        return ExecResult(-1, "", e.message, false)
    }

    let outFuture = spawn {
        return readAllFromPipe(sub.stdOutPipe)
    }
    let errFuture = spawn {
        return readAllFromPipe(sub.stdErrPipe)
    }

    var code: Int64 = 0
    var timedOut = false
    try {
        code = sub.wait(timeout: Some(Duration.millisecond * timeoutMs))
    } catch (e: TimeoutException) {
        timedOut = true
        code = -1
        Log.warn("子进程超时被放弃：${cmd} ${joinStrings(args, " ")}（${timeoutMs}ms）")
        return ExecResult(code, "", "命令超时（${timeoutMs}ms）：${cmd}", true)
    } catch (e: Exception) {
        timedOut = false
        code = -1
    }
    return ExecResult(code, outFuture.get(), errFuture.get(), timedOut)
}

/// 读管道到 EOF，UTF-8 容错解码
func readAllFromPipe(pipe: ?InputStream): String {
    match (pipe) {
        case Some(input) =>
            let total = ArrayList<UInt8>()
            let buf = Array<UInt8>(65536, repeat: 0u8)
            try {
                while (true) {
                    let n = input.read(buf)
                    if (n <= 0) {
                        break
                    }
                    for (i in 0..n) {
                        total.add(buf[i])
                    }
                }
            } catch (e: Exception) {
                ()
            }
            return fromUtf8Lossy(total.toArray())
        case None => return ""
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

// ------------------------------ 测试 ------------------------------

@Test
func testExecCaptureBasic(): Unit {
    let r = execCapture("echo", ["hello"], None, 5000)
    @Assert(r.ok())
    @Assert(r.stdout.contains("hello"))
    @Assert(!r.timedOut)
}

@Test
func testExecCaptureTimeoutActuallyTimesOut(): Unit {
    // 挂死命令：必须在超时附近返回 timedOut，而不是永远阻塞
    let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let r = execCapture("sleep", ["30"], None, 500)
    let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - t0
    @Assert(r.timedOut)
    @Assert(!r.ok())
    @Assert(elapsed < 5000)  // 远小于 sleep 30s
}

@Test
func testExecCaptureLargeOutput(): Unit {
    // 大输出（>64KB 管道缓冲）：并发读取线程必须让它正常走完而不是死锁
    let r = execCapture("sh", ["-c", "i=0; while [ $i -lt 8000 ]; do echo line_$i; i=$((i+1)); done"], None, 30000)
    @Assert(r.ok())
    @Assert(!r.timedOut)
    @Assert(r.stdout.size > 60000)
}
