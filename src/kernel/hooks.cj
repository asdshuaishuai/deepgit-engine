// git 钩子安装器。
//
// 安全设计：
// - 只装 post-commit（非阻塞，绝不会让 commit 失败）
// - 钩子后台异步调用 deepgit track，提交不等待任何扫描或 AI
// - 托管块标记：重装只替换 deepGit 自己的块，其余内容保留；
//   卸载只删这一块
package deepgit.kernel

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

let HOOK_BEGIN = "# deepgit:begin"
let HOOK_END = "# deepgit:end"

func hookBody(enginePath: String, hookName: String): String {
    let note = if (hookName == "post-merge") {
        "deepGit post-merge hook — 合并后记录默认分支进度。"
    } else {
        "deepGit post-commit hook — 后台记录分支进度。"
    }
    let sb = StringBuilder()
    sb.append(HOOK_BEGIN)
    sb.append("\n")
    sb.append("# ${note}\n")
    sb.append("# 托管块：请在块外编辑，块内内容会被覆盖。\n")
    sb.append("if command -v deepgit >/dev/null 2>&1; then\n")
    sb.append("  (deepgit track --quiet --source hook >/dev/null 2>&1 &)\n")
    sb.append("elif [ -x \"${enginePath}\" ]; then\n")
    sb.append("  (\"${enginePath}\" track --quiet --source hook >/dev/null 2>&1 &)\n")
    sb.append("fi\n")
    sb.append(HOOK_END)
    sb.append("\n")
    return sb.toString()
}

func stripHookBlock(content: String): (String, Bool) {
    let beginIdx = content.indexOf(HOOK_BEGIN)
    match (beginIdx) {
        case None => return (content, false)
        case Some(bi) =>
            let endIdx = content.indexOf(HOOK_END, bi)
            match (endIdx) {
                case None => return (content, false)
                case Some(ei) =>
                    let after = content[ei + HOOK_END.size..]
                    let cleaned = if (after.startsWith("\n")) { after[1..] } else { after }
                    return (content[..bi] + cleaned, true)
            }
    }
}

public func hookPath(repoDir: String): Option<String> {
    return hookPathFor(repoDir, "post-commit")
}

public func hookPathFor(repoDir: String, hookName: String): Option<String> {
    let r = gitTry(repoDir, ["rev-parse", "--git-path", "hooks/" + hookName])
    if (!r.ok()) {
        return None
    }
    let p = r.stdout.trimAscii()
    if (p.startsWith("/")) {
        return Some(p)
    }
    return Some("${repoDir}/${p}")
}

public class HookResult {
    public let file: String
    public let installed: Bool
    public let created: Bool
    public let replaced: Bool

    public init(file: String, installed: Bool, created: Bool, replaced: Bool) {
        this.file = file
        this.installed = installed
        this.created = created
        this.replaced = replaced
    }
}

public func installHook(repoDir: String, enginePath: String): HookResult {
    return installHookFor(repoDir, enginePath, "post-commit")
}

public func installHookFor(repoDir: String, enginePath: String, hookName: String): HookResult {
    match (hookPathFor(repoDir, hookName)) {
        case None => throw DgError("NOT_GIT", "不是 git 仓库：${repoDir}")
        case Some(file) =>
            ensureDir(dirname(file))
            var existing = ""
            var exists = false
            match (readFileText(file)) {
                case Some(c) =>
                    existing = c
                    exists = true
                case None => ()
            }
            let (stripped, wasPresent) = stripHookBlock(existing)
            let shebang = extractShebang(existing)
            let bodyWithoutShebang = stripShebang(stripped)
            let next = "${shebang}\n${hookBody(enginePath, hookName)}\n${bodyWithoutShebang}".trimAsciiEnd() + "\n"
            writeFileAtomic(file, next)
            // chmod 755
            chmodExecutable(file)
            return HookResult(file, true, !exists, wasPresent)
    }
}

public func uninstallHook(repoDir: String): HookResult {
    return uninstallHookFor(repoDir, "post-commit")
}

public func uninstallHookFor(repoDir: String, hookName: String): HookResult {
    match (hookPathFor(repoDir, hookName)) {
        case None => throw DgError("NOT_GIT", "不是 git 仓库：${repoDir}")
        case Some(file) =>
            match (readFileText(file)) {
                case None => return HookResult(file, false, false, false)
                case Some(existing) =>
                    let (cleaned, found) = stripHookBlock(existing)
                    if (!found) {
                        return HookResult(file, false, false, false)
                    }
                    let meaningful = stripShebang(cleaned).trimAscii()
                    if (meaningful.size == 0) {
                        removePathIfExists(file)
                        return HookResult(file, false, false, true)
                    }
                    writeFileAtomic(file, cleaned.trimAsciiEnd() + "\n")
                    return HookResult(file, false, false, true)
            }
    }
}

public func hookInstalled(repoDir: String): Bool {
    return hookInstalledFor(repoDir, "post-commit")
}

public func hookInstalledFor(repoDir: String, hookName: String): Bool {
    match (hookPathFor(repoDir, hookName)) {
        case None => return false
        case Some(file) =>
            match (readFileText(file)) {
                case Some(c) => return c.contains(HOOK_BEGIN)
                case None => return false
            }
    }
}

func extractShebang(content: String): String {
    if (content.startsWith("#!")) {
        let nl = content.indexOf("\n")
        match (nl) {
            case Some(i) => return content[..i]
            case None => return content
        }
    }
    return "#!/bin/sh"
}

func stripShebang(content: String): String {
    if (content.startsWith("#!")) {
        let nl = content.indexOf("\n")
        match (nl) {
            case Some(i) => return content[i + 1..]
            case None => return ""
        }
    }
    return content
}

func chmodExecutable(file: String): Unit {
    // 用系统 chmod 保证权限（仓颉 std 无 chmod）
    let r = execCapture("chmod", ["755", file], None, 8000)
    if (!r.ok()) {
        Log.debug("chmod 755 失败：${file}")
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testStripHookBlock(): Unit {
    let content = "#!/bin/sh\necho hello\n${HOOK_BEGIN}\nstuff\n${HOOK_END}\necho world\n"
    let (cleaned, found) = stripHookBlock(content)
    @Assert(found)
    @Assert(!cleaned.contains(HOOK_BEGIN))
    @Assert(cleaned.contains("echo hello"))
    @Assert(cleaned.contains("echo world"))
}

@Test
func testStripHookBlockNotFound(): Unit {
    let (cleaned, found) = stripHookBlock("#!/bin/sh\necho x\n")
    @Assert(!found)
    @Assert(cleaned.contains("echo x"))
}

@Test
func testInstallAndUninstallHook(): Unit {
    let base = "/tmp/deepgit-hook-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    let res = installHook(base, "/usr/local/bin/deepgit")
    @Assert(res.installed)
    @Assert(res.created)
    @Assert(hookInstalled(base))

    // 重装幂等（不重复块）
    let res2 = installHook(base, "/usr/local/bin/deepgit")
    @Assert(res2.replaced)
    match (readFileText(res.file)) {
        case Some(c) =>
            var count: Int64 = 0
            for (line in c.split("\n")) {
                if (line.startsWith(HOOK_BEGIN)) {
                    count += 1
                }
            }
            @Assert(count == 1)
        case None => @Assert(false)
    }

    let un = uninstallHook(base)
    @Assert(un.file.size > 0)
    @Assert(!hookInstalled(base))
    removePathIfExists(base)
}

@Test
func testInstallHookPreservesExistingContent(): Unit {
    let base = "/tmp/deepgit-hook2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    match (hookPath(base)) {
        case Some(p) =>
            ensureDir(dirname(p))
            writeFileAtomic(p, "#!/bin/sh\necho my-custom-hook\n")
        case None => @Assert(false)
    }
    installHook(base, "/x/deepgit")
    match (hookPath(base)) {
        case Some(p) =>
            let c = readFileTextOr(p, "")
            @Assert(c.contains("my-custom-hook"))
            @Assert(c.contains(HOOK_BEGIN))
            @Assert(c.startsWith("#!/bin/sh"))
        case None => @Assert(false)
    }
    removePathIfExists(base)
}

@Test
func testHookPathRequiresGit(): Unit {
    let tmp = "/tmp/deepgit-hook3-${nowMillis()}"
    ensureDir(tmp)
    @Assert(hookPath(tmp).isNone())
    removePathIfExists(tmp)
}

@Test
func testPostMergeHookLifecycle(): Unit {
    let base = "/tmp/deepgit-hk-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], true)
    // 未安装
    @Assert(!hookInstalledFor(base, "post-merge"))
    // 安装
    let res = installHookFor(base, "/fake/engine", "post-merge")
    @Assert(res.installed)
    @Assert(hookInstalledFor(base, "post-merge"))
    // 内容包含 post-merge 注释（而非 post-commit）
    let content = readFileText(res.file).getOrThrow()
    @Assert(content.contains("post-merge hook"))
    @Assert(!content.contains("post-commit hook"))
    @Assert(content.contains("deepgit track --quiet --source hook"))
    // 重装幂等（不重复）
    let res2 = installHookFor(base, "/fake/engine", "post-merge")
    @Assert(res2.replaced)
    let content2 = readFileText(res.file).getOrThrow()
    @Assert(content2.split("deepgit:begin").size == 2)  // 恰好一个托管块
    // 卸载
    let rm = uninstallHookFor(base, "post-merge")
    @Assert(rm.replaced)
    @Assert(!hookInstalledFor(base, "post-merge"))
    removePathIfExists(base)
}

@Test
func testHookBodyCommentVaries(): Unit {
    let cm = hookBody("/e", "post-commit")
    let pm = hookBody("/e", "post-merge")
    @Assert(cm.contains("post-commit hook"))
    @Assert(pm.contains("post-merge hook"))
}
