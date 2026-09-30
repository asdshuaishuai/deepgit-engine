// CLI 层测试：位置参数解析与展示行格式。
package deepgit.cli

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.kernel.*
import deepgit.util.*

// ------------------------------ 测试 ------------------------------

@Test
func testPositionalsOnlySkipsValueFlagPairs(): Unit {
    let args = ArrayList<String>(["status", "--source", "hook", "-q", "proj"])
    let refs = positionalsOnly(args, VALUE_FLAGS)
    // --source 与它的值 hook 都不算位置参数；-q 是短 flag
    @Assert(refs.size == 2)
    @Assert(refs[0] == "status")
    @Assert(refs[1] == "proj")
}

@Test
func testValueFlagsCoversAllValueOptions(): Unit {
    // 所有「带值」的 flag 必须在名单里，否则其值会被误当项目名
    for (f in ["--name", "--depth", "--docs", "--scope", "--branch", "--port", "--source", "--tag", "--date", "--desc", "--out"]) {
        var found = false
        for (v in VALUE_FLAGS) {
            if (v == f) {
                found = true
            }
        }
        @Assert(found)
    }
}

@Test
func testMilestoneLineFormatting(): Unit {
    let it = Json.obj()
    Json.set(it, "projectName", Json.of("demo"))
    Json.set(it, "name", Json.of("v1.0"))
    Json.set(it, "status", Json.of("open"))
    Json.set(it, "targetDate", Json.of("2026-12-01"))
    Json.set(it, "daysToTarget", Json.of(62))
    Json.set(it, "commitsSince", Json.of(12))
    Json.set(it, "tagReached", Json.of(false))
    Json.set(it, "overdue", Json.of(false))
    let line = milestoneLine(it)
    @Assert(line.contains("demo｜v1.0"))
    @Assert(line.contains("进行中"))
    @Assert(line.contains("还剩 62 天"))
    @Assert(line.contains("12 提交"))

    // 逾期展示
    let od = Json.obj()
    Json.set(od, "projectName", Json.of("demo"))
    Json.set(od, "name", Json.of("old"))
    Json.set(od, "status", Json.of("open"))
    Json.set(od, "targetDate", Json.of("2026-01-01"))
    Json.set(od, "daysToTarget", Json.of(-9))
    Json.set(od, "commitsSince", Json.of(0))
    Json.set(od, "tagReached", Json.of(false))
    Json.set(od, "overdue", Json.of(true))
    @Assert(milestoneLine(od).contains("已逾期"))
    @Assert(milestoneLine(od).contains("逾期 9 天"))
}

@Test
func testMilestoneJsonRoundTrip(): Unit {
    let base = "/tmp/deepgit-mj-${nowMillis()}"
    ensureDir(base)
    setVariable("DEEPGIT_HOME", base)
    let (m, _) = addMilestone("p_rt", "v2.0", "desc", "2027-06-01", "v2.0.0")
    let p = ProjectEntry("p_rt", "demo", "/tmp/nowhere", "git", "", nowIso(), ArrayList<String>(), false)
    let prog = milestoneProgress(m, "", "")
    let j = milestoneJson(p, prog)
    @Assert(Json.strAt(j, "projectName", "") == "demo")
    @Assert(Json.strAt(j, "tagName", "") == "v2.0.0")
    @Assert(Json.strAt(j, "targetDate", "") == "2027-06-01")
    setVariable("DEEPGIT_HOME", "")
    removePathIfExists(base)
}
