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
        Log.error("内部错误：${e.message}")
        if (Log.isVerbose()) {
            Log.dim(e.toString())
        }
        return 1
    }
}
