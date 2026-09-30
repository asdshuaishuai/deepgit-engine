// 项目扫描器：在给定根目录下发现项目（git 仓库 或 带清单+README 的目录）。
package deepgit.kernel

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

let SCAN_SKIP_DIRS = ["node_modules", ".git", ".svn", ".hg", ".build", ".swiftpm", "DerivedData", "dist", "build", "target", "__pycache__", ".venv", "venv", ".next", ".cache", ".gradle", ".idea", "_build", "coverage", "Library", ".Trash", "renders", "snapshots", ".playwright-mcp", ".zcode", "tmp"]

let STRONG_MARKERS = ["package.json", "moon.mod.json", "Cargo.toml", "Package.swift", "pyproject.toml", "go.mod", "pubspec.yaml", "pom.xml", "cjpm.toml", "build.gradle", "build.gradle.kts", "CMakeLists.txt"]

let README_MARKERS = ["README.md", "README.zh-CN.md", "AGENTS.md", "CLAUDE.md"]

func scanSkip(name: String): Bool {
    for (s in SCAN_SKIP_DIRS) {
        if (s == name) {
            return true
        }
    }
    return false
}

public class ScanCandidate {
    public let path: String
    public let name: String
    public let kind: String
    public let markers: ArrayList<String>
    public let remote: String

    public init(path: String, name: String, kind: String, markers: ArrayList<String>, remote: String) {
        this.path = path
        this.name = name
        this.kind = kind
        this.markers = markers
        this.remote = remote
    }
}

public class ScanResult {
    public let candidates: ArrayList<ScanCandidate>
    public let dirsVisited: Int64
    public let truncated: Bool

    public init(candidates: ArrayList<ScanCandidate>, dirsVisited: Int64, truncated: Bool) {
        this.candidates = candidates
        this.dirsVisited = dirsVisited
        this.truncated = truncated
    }
}

func detectMarkers(dir: String): ArrayList<String> {
    let hits = ArrayList<String>()
    for (m in STRONG_MARKERS) {
        if (fileExists("${dir}/${m}")) {
            hits.add(m)
        }
    }
    // Xcode 工程
    for (info in listDir(dir)) {
        if (info.isDirectory() && info.name.endsWith(".xcodeproj")) {
            hits.add(info.name)
        }
    }
    return hits
}

func hasReadme(dir: String): Bool {
    for (r in README_MARKERS) {
        if (fileExists("${dir}/${r}")) {
            return true
        }
    }
    return false
}

/// 扫描根目录，发现项目
public func scanRoots(roots: ArrayList<String>, depth: Int64, includeNonGit: Bool): ScanResult {
    let candidates = ArrayList<ScanCandidate>()
    let seen = ArrayList<String>()
    var dirsVisited: Int64 = 0
    var truncated = false

    // 显式队列式遍历（避免深递归）
    let queue = ArrayList<(String, Int64)>()
    for (r in roots) {
        queue.add((normalizePath(expandHome(r)), 0))
    }
    var head = 0
    while (head < queue.size) {
        let (dir, curDepth) = queue[head]
        head += 1
        dirsVisited += 1
        if (dirsVisited > 20000) {
            truncated = true
            break
        }

        let isGit = fileExists("${dir}/.git")
        if (isGit) {
            var already = false
            for (s in seen) {
                if (s == dir) {
                    already = true
                    break
                }
            }
            if (!already) {
                seen.add(dir)
                let remote = remoteUrl(dir)
                candidates.add(ScanCandidate(dir, basename(dir), "git", ArrayList<String>([".git"]), remote))
            }
            continue  // 不再深入仓库内部
        }

        if (includeNonGit) {
            let markers = detectMarkers(dir)
            if (markers.size > 0 && hasReadme(dir)) {
                var already = false
                for (s in seen) {
                    if (s == dir) {
                        already = true
                        break
                    }
                }
                if (!already) {
                    seen.add(dir)
                    candidates.add(ScanCandidate(dir, basename(dir), "dir", markers, ""))
                }
                continue  // 最外层非 git 项目优先
            }
        }

        if (curDepth >= depth) {
            continue
        }
        for (info in listDir(dir)) {
            if (!info.isDirectory()) {
                continue
            }
            let nm = info.name
            if (nm.startsWith(".") || scanSkip(nm)) {
                continue
            }
            queue.add((dir + "/" + nm, curDepth + 1))
        }
    }

    return ScanResult(candidates, dirsVisited, truncated)
}

/// 批量注册扫描结果，返回 (新增数, 已有数)
public func registerCandidates(candidates: ArrayList<ScanCandidate>): (Int64, Int64) {
    let reg = loadRegistry()
    var added: Int64 = 0
    var existing: Int64 = 0
    for (c in candidates) {
        let id = projectIdFor(c.path)
        var found = false
        for (p in reg.projects) {
            if (p.id == id) {
                found = true
                break
            }
        }
        if (found) {
            existing += 1
            continue
        }
        reg.projects.add(ProjectEntry(id, c.name, c.path, c.kind, c.remote, nowIso(), ArrayList<String>(), false))
        added += 1
    }
    saveRegistry(reg)
    return (added, existing)
}

// ------------------------------ 测试 ------------------------------

@Test
func testScanFindsGitRepo(): Unit {
    let base = "/tmp/deepgit-scan-${nowMillis()}"
    let repo = "${base}/proj-a"
    ensureDir(repo)
    // 构造一个最小 git 仓库
    gitRun(repo, ["init", "-b", "main"], true)
    writeFileAtomic(repo + "/README.md", "# a")
    let roots = ArrayList<String>([base])
    let res = scanRoots(roots, 3, true)
    var found = false
    for (c in res.candidates) {
        if (c.name == "proj-a" && c.kind == "git") {
            found = true
        }
    }
    @Assert(found)
    removePathIfExists(base)
}

@Test
func testScanFindsNonGitProjectWithMarker(): Unit {
    let base = "/tmp/deepgit-scan-ng-${nowMillis()}"
    let proj = "${base}/dirproj"
    ensureDir(proj)
    writeFileAtomic(proj + "/package.json", "{\"name\":\"x\"}")
    writeFileAtomic(proj + "/README.md", "# x")
    let roots = ArrayList<String>([base])
    let res = scanRoots(roots, 3, true)
    var found = false
    for (c in res.candidates) {
        if (c.name == "dirproj" && c.kind == "dir") {
            found = true
        }
    }
    @Assert(found)
    removePathIfExists(base)
}

@Test
func testScanSkipsNodeModules(): Unit {
    let base = "/tmp/deepgit-scan-skip-${nowMillis()}"
    let nm = "${base}/node_modules/pkg"
    ensureDir(nm)
    writeFileAtomic(nm + "/package.json", "{}")
    writeFileAtomic(nm + "/README.md", "# x")
    let roots = ArrayList<String>([base])
    let res = scanRoots(roots, 4, true)
    @Assert(res.candidates.size == 0)
    removePathIfExists(base)
}

@Test
func testScanRespectsDepth(): Unit {
    let base = "/tmp/deepgit-scan-depth-${nowMillis()}"
    let deep = "${base}/a/b/c/deep"
    ensureDir(deep)
    gitRun(deep, ["init", "-b", "main"], true)
    let roots = ArrayList<String>([base])
    let shallow = scanRoots(roots, 1, true)
    @Assert(shallow.candidates.size == 0)
    let deeper = scanRoots(roots, 4, true)
    @Assert(deeper.candidates.size == 1)
    removePathIfExists(base)
}

@Test
func testScanNonGitDisabled(): Unit {
    let base = "/tmp/deepgit-scan-ng2-${nowMillis()}"
    let proj = "${base}/dirproj"
    ensureDir(proj)
    writeFileAtomic(proj + "/package.json", "{}")
    writeFileAtomic(proj + "/README.md", "# x")
    let roots = ArrayList<String>([base])
    let res = scanRoots(roots, 3, false)
    @Assert(res.candidates.size == 0)
    removePathIfExists(base)
}
