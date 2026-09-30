// 项目注册表：记录被管理的项目群。
package deepgit.kernel

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import deepgit.util.*

public class ProjectEntry {
    public let id: String
    public let name: String
    public let path: String
    public let kind: String  // git | dir
    public let remote: String
    public let addedAt: String
    public var tags: ArrayList<String>
    public var disabled: Bool

    public init(id: String, name: String, path: String, kind: String, remote: String, addedAt: String, tags: ArrayList<String>, disabled: Bool) {
        this.id = id
        this.name = name
        this.path = path
        this.kind = kind
        this.remote = remote
        this.addedAt = addedAt
        this.tags = tags
        this.disabled = disabled
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "id", Json.of(this.id))
        Json.set(o, "name", Json.of(this.name))
        Json.set(o, "path", Json.of(this.path))
        Json.set(o, "kind", Json.of(this.kind))
        Json.set(o, "remote", Json.of(this.remote))
        Json.set(o, "addedAt", Json.of(this.addedAt))
        let tagsArr = ArrayList<JsonValue>()
        for (t in this.tags) {
            tagsArr.add(Json.of(t))
        }
        Json.set(o, "tags", JArr(tagsArr))
        Json.set(o, "disabled", Json.of(this.disabled))
        return o
    }

    public static func fromJson(j: JsonValue): ProjectEntry {
        return ProjectEntry(
            Json.strAt(j, "id", ""),
            Json.strAt(j, "name", ""),
            Json.strAt(j, "path", ""),
            Json.strAt(j, "kind", "dir"),
            Json.strAt(j, "remote", ""),
            Json.strAt(j, "addedAt", ""),
            Json.strArrAt(j, "tags"),
            Json.boolAt(j, "disabled", false),
        )
    }
}

public class Registry {
    public var projects: ArrayList<ProjectEntry>

    public init() {
        this.projects = ArrayList<ProjectEntry>()
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "version", Json.of(1))
        let arr = ArrayList<JsonValue>()
        for (p in this.projects) {
            arr.add(p.toJson())
        }
        Json.set(o, "projects", JArr(arr))
        return o
    }

    public static func fromJson(j: JsonValue): Registry {
        let reg = Registry()
        let arr = Json.arrAt(j, "projects")
        for (item in arr) {
            reg.projects.add(ProjectEntry.fromJson(item))
        }
        return reg
    }
}

public func loadRegistry(): Registry {
    match (readFileText(registryPath())) {
        case Some(text) =>
            match (Json.parse(text)) {
                case Some(j) => return Registry.fromJson(j)
                case None => return Registry()
            }
        case None => return Registry()
    }
}

public func saveRegistry(reg: Registry): Unit {
    writeFileAtomic(registryPath(), Json.pretty(reg.toJson()))
}

/// 探测路径的项目类型与远端
public func detectProjectInfo(absPath: String): (String, String) {
    let r = gitTry(absPath, ["rev-parse", "--show-toplevel"])
    if (r.ok() && !r.stdout.isBlank()) {
        let root = r.stdout.trimAscii()
        let remoteRes = gitTry(root, ["config", "--get", "remote.origin.url"])
        let remote = if (remoteRes.ok()) { remoteRes.stdout.trimAscii() } else { "" }
        return ("git", remote)
    }
    return ("dir", "")
}

/// 注册项目（已存在则返回既有条目）
public func addProject(inputPath: String, name: String, tags: ArrayList<String>, base: String): (ProjectEntry, Bool) {
    let abs = resolvePath(inputPath, base)
    if (!isDirectoryPath(abs)) {
        throw DgError.notFound("路径不存在或不是目录：${abs}")
    }
    let (kind, remote) = detectProjectInfo(abs)
    let root = if (kind == "git") { gitRun(abs, ["rev-parse", "--show-toplevel"], false) } else { abs }
    let id = projectIdFor(root)

    let reg = loadRegistry()
    for (p in reg.projects) {
        if (p.id == id || normalizePath(p.path) == normalizePath(root)) {
            return (p, false)
        }
    }
    let entry = ProjectEntry(id, if (name.isEmpty()) { basename(root) } else { name }, root, kind, remote, nowIso(), tags, false)
    reg.projects.add(entry)
    ensureDir(deepgitHome())
    saveRegistry(reg)
    return (entry, true)
}

/// 按 id / 名称 / 路径查找
public func findProject(ref: String): Option<ProjectEntry> {
    let reg = loadRegistry()
    return findProjectIn(reg, ref)
}

public func findProjectIn(reg: Registry, ref: String): Option<ProjectEntry> {
    if (ref.isEmpty()) {
        return None
    }
    for (p in reg.projects) {
        if (p.id == ref) {
            return Some(p)
        }
    }
    for (p in reg.projects) {
        if (p.name == ref) {
            return Some(p)
        }
    }
    let abs = resolveMacSymlink(normalizePath(expandHome(ref)))
    for (p in reg.projects) {
        if (samePath(p.path, abs)) {
            return Some(p)
        }
    }
    for (p in reg.projects) {
        if (resolveMacSymlink(normalizePath(p.path)).startsWith(abs + "/")) {
            return Some(p)
        }
    }
    for (p in reg.projects) {
        if (basename(p.path) == ref) {
            return Some(p)
        }
    }
    let lower = ref.toAsciiLower()
    for (p in reg.projects) {
        if (p.name.toAsciiLower().contains(lower) || p.path.toAsciiLower().contains(lower)) {
            return Some(p)
        }
    }
    return None
}

public func requireProject(ref: String): ProjectEntry {
    match (findProject(ref)) {
        case Some(p) => return p
        case None =>
            throw DgError.notFound("未找到项目：${ref}（可用 `deepgit list` 查看，或 `deepgit scan` 扫描注册）")
    }
}

public func removeProject(ref: String, purge: Bool): ProjectEntry {
    let reg = loadRegistry()
    match (findProjectIn(reg, ref)) {
        case Some(target) =>
            let keep = ArrayList<ProjectEntry>()
            for (p in reg.projects) {
                if (p.id != target.id) {
                    keep.add(p)
                }
            }
            reg.projects = keep
            saveRegistry(reg)
            if (purge) {
                removePathIfExists(deepgitPath(["store", target.id]))
            }
            return target
        case None => throw DgError.notFound("未找到项目：${ref}")
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testRegistryRoundTrip(): Unit {
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_x", "demo", "/tmp/demo", "git", "git@x:y", nowIso(), ArrayList<String>(["a"]), false))
    let j = reg.toJson()
    let back = Registry.fromJson(j)
    @Assert(back.projects.size == 1)
    @Assert(back.projects[0].name == "demo")
    @Assert(back.projects[0].kind == "git")
    @Assert(back.projects[0].tags.size == 1)
}

@Test
func testFindProjectByVariousRefs(): Unit {
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_abc", "myproj", "/Volumes/x/myproj", "git", "", nowIso(), ArrayList<String>(), false))
    @Assert(findProjectIn(reg, "p_abc").isSome())
    @Assert(findProjectIn(reg, "myproj").isSome())
    @Assert(findProjectIn(reg, "/Volumes/x/myproj").isSome())
    @Assert(findProjectIn(reg, "MYPROJ").isSome())
    @Assert(findProjectIn(reg, "/Volumes/x").isSome())
    @Assert(findProjectIn(reg, "nonexistent-xyz").isNone())
}

@Test
func testProjectEntryJsonShape(): Unit {
    let e = ProjectEntry("p_1", "n", "/p", "dir", "", "2026-01-01", ArrayList<String>(), false)
    let j = e.toJson()
    @Assert(Json.strAt(j, "id", "") == "p_1")
    @Assert(Json.boolAt(j, "disabled", true) == false)
    @Assert(Json.arrAt(j, "tags").size == 0)
}

@Test
func testDetectProjectInfoNonGit(): Unit {
    let tmp = "/tmp/deepgit-detect-${nowMillis()}"
    ensureDir(tmp)
    let (kind, remote) = detectProjectInfo(tmp)
    @Assert(kind == "dir")
    @Assert(remote.isEmpty())
    removePathIfExists(tmp)
}
