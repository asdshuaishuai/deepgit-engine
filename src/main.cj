package deepgit

import std.collection.*
import std.env.*
import deepgit.cli.*
import deepgit.util.*

main(): Int64 {
    let argv = ArrayList<String>()
    for (a in getCommandLine()) {
        argv.add(a)
    }
    // 首个参数是可执行文件路径，剔除
    if (argv.size > 0) {
        let first = argv[0]
        if (first.contains("/") || first.endsWith("deepgit")) {
            let trimmed = ArrayList<String>()
            var i: Int64 = 0
            for (a in argv) {
                if (i > 0) {
                    trimmed.add(a)
                }
                i += 1
            }
            return runCli(trimmed)
        }
    }
    return runCli(argv)
}

func runCli(argv: ArrayList<String>): Int64 {
    // 崩溃时至少要让用户知道**是哪条命令**炸的。argv[0] 是事实，不需要推断。
    let cmd = failingCommandName(argv)
    try {
        return main2(argv)
    } catch (e: DgError) {
        Log.error(e.msgText)
        if (Log.isVerbose()) {
            match (e.details) {
                case Some(d) => Log.dim(d)
                case None => ()
            }
        }
        return e.exitCode
    } catch (e: Exception) {
        // ⚠️ 原来只有 `内部错误：${e.message}`。运行时对原生调用失败给的是
        // 固定一句「Native function error.」，既不点名路径也不说哪一步失败 ——
        // 实测 `scan /` 与 `scan /private/var/db` 都只吐这一句。
        Log.error(internalErrorMessage(cmd, e.message))
        if (Log.isVerbose()) {
            Log.dim(e.toString())
        }
        return 1
    } catch (e: Error) {
        // Error 不是 Exception 的子类，Out of memory / StackOverflow 这类
        // 走不到上面两个分支，会直接把运行时裸信息吐给用户、没有统一格式。
        // 放在最后兜底。
        Log.error(internalErrorMessage(cmd, e.message))
        if (Log.isVerbose()) {
            Log.dim(e.toString())
        }
        return 1
    }
}
