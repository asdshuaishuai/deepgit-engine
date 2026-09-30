// 锁：防止并发更新同一项目。
package deepgit.kernel

import std.collection.*
import std.fs.*
import std.posix.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

/// 简单 pid+时间戳文件锁；超过 staleMs 的陈旧锁会被接管。
public func withLock<T>(lockFile: String, staleMs: Int64, body: () -> T): T {
    ensureDir(dirname(lockFile))
    var acquired = false
    if (fileExists(lockFile)) {
        // 检查是否陈旧
        let info = FileInfo(Path(lockFile))
        let ageMs = nowMillis() - info.lastModificationTime.toUnixTimeStamp().toMilliseconds()
        if (ageMs > staleMs) {
            Log.debug("接管陈旧锁：${lockFile}")
            removePathIfExists(lockFile)
        }
    }
    if (!fileExists(lockFile)) {
        let content = "{\"pid\":${getpid()}," + "\"at\":\"${nowIso()}\"}"
        File.writeTo(Path(lockFile), content.toArray())
        acquired = true
    }
    if (!acquired) {
        throw DgError("LOCKED", "该项目正在更新中（另一个 deepGit 进程持锁），请稍后重试", 1, Some(lockFile))
    }
    try {
        let result = body()
        removePathIfExists(lockFile)
        return result
    } catch (e: Exception) {
        removePathIfExists(lockFile)
        throw e
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testWithLockRunsBody(): Unit {
    let dir = "/tmp/deepgit-lock-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    let result = withLock(lock, 60000, {=> 42})
    @Assert(result == 42)
    @Assert(!fileExists(lock))  // 释放
    removePathIfExists(dir)
}

@Test
func testWithLockRejectsWhenHeld(): Unit {
    let dir = "/tmp/deepgit-lock2-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    File.writeTo(Path(lock), "{\"pid\":1}".toArray())
    var threw = false
    try {
        withLock(lock, 600000, {=> 1})
    } catch (e: DgError) {
        threw = e.code == "LOCKED"
    }
    @Assert(threw)
    removePathIfExists(dir)
}

@Test
func testWithLockReleasesOnError(): Unit {
    let dir = "/tmp/deepgit-lock3-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    try {
        withLock(lock, 60000, {=> throw DgError("X", "boom")})
    } catch (e: Exception) {
        ()
    }
    @Assert(!fileExists(lock))
    removePathIfExists(dir)
}
