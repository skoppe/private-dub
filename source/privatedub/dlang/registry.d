module privatedub.dlang.registry;

import privatedub.registry;
import kaleidic.experimental.concurrency.stoptoken;
import dub.internal.vibecompat.data.json : Json, parseJsonString;
import dub.recipe.packagerecipe : PackageRecipe, BuildSettingsTemplate;
import std.typecons : Nullable;

import dub.recipe.json : parseJson;

struct DlangRegistryConfig {
  import dini : IniSection;

  enum type = "dlang";
  string storage = "./storage";
  int priority = 1;

  static DlangRegistryConfig loadConfig(IniSection section) {
    import std.conv : to;

    return DlangRegistryConfig(section.getKey("storage", DlangRegistryConfig.init.storage),
        section.getKey("priority", DlangRegistryConfig.init.priority.to!string).to!int);
  }
}

class DlangRegistry : Registry {
  import core.sync.mutex : Mutex;

private:
  Repo repo;
  DlangRegistryConfig config;
  Json[string] cache;
  Mutex mutex;
  string storage() {
    import std.path : buildPath;

    return buildPath(config.storage, "dlang");
  }

  auto lock() shared {
    import privatedub.sync : Guard;

    return Guard!(DlangRegistry).acquire(this, cast() this.mutex);
  }

  auto lock() @trusted {
    return (cast(shared)this).lock();
  }

public:
  this(DlangRegistryConfig config) {
    this.config = config;
    this.mutex = new Mutex();
    repo = cloneRegistry(storage);
  }

  void sync(StopToken stopToken) @trusted {
    (cast(shared) this).sync(stopToken);
  }

  void sync(StopToken stopToken) shared @trusted {
    with (lock()) {
      if (repo.pull())
        cache.clear();
    }
  }

  int priority() {
    return config.priority;
  }

  string getPrefix() {
    return "";
  }

  PackageMeta[] search(string name) {
    // note we don't actually search, just match a single package and return if found
    return [getPackageMeta(name)];
  }

  PackageMeta getPackageMeta(string name) {
    import std.algorithm : map;
    import std.array : array;

    Json content = getPackage(name);
    return PackageMeta(this, name, content["versions"][].map!((v) {
        PackageRecipe recipe;
        parseJson(recipe, v, "");
        return VersionedPackage(v["version"].get!string.normalizeVersion, v["commitID"].get!string, recipe);
      }).array());
  }

  bool hasPackage(string name) {
    import std.path : buildPath;
    import std.file : exists;

    auto path = buildPath(storage, getPackageDir(name), name);
    return exists(path);
  }

  string getDownloadUri(string name, string rawVer, Nullable!string token) {
    import std.algorithm : find;
    import std.range : front, empty;
    import std.format : format;

    auto meta = getPackage(name);
    auto repo = meta["repository"];
    auto kind = repo["kind"].get!string;
    auto owner = repo["owner"].get!string;
    auto project = repo["project"].get!string;
    string ver = rawVer.normalizeVersion();
    if (kind == "github")
      return "https://github.com/%s/%s/archive/%s.zip".format(owner, project, ver);
    else if (kind == "gitlab")
      return "https://gitlab.com/%s/%s/-/archive/%s/%s-%s.zip".format(owner,
          project, ver, project, ver);
    throw new Exception(kind ~ " is not supported");
  }

  private Json getPackage(string name) {
    import std.path : buildPath;
    import std.file : readText;

    if (auto j = name in cache)
      return *j;

    /// lock in case to avoid a git pull happening at the same time
    with (lock()) {
      auto path = buildPath(storage, getPackageDir(name), name);
      auto content = parseJsonString(readText(path));
      cache[name] = content;
      return content;
    }
  }
}

// Dub stores a dub package's 'version' internally WITHOUT a leading 'v' in the case of a
// semver version and WITH a leading '~' in the case of a branch.
// We just use the EXACT same ref as found in the git repo.
string normalizeVersion(string ver) {
  import privatedub.resolve;
  import std.string : stripLeft;
  if (ver.parseVersion().isNull)
    return ver.stripLeft("~");
  return "v"~ver.stripLeft("v");
}

Repo cloneRegistry(string path) {
  import std.format : format;
  import std.path : buildPath;
  import std.file : exists;

  if (exists(buildPath(path, ".git")))
    return Repo(path);

  executeShellOrThrow("git clone https://github.com/skoppe/dub-packages-index.git " ~ path);
  return Repo(path);
}

auto getPackageDir(string name) {
  import std.algorithm : filter, joiner;
  import std.format : format;
  import std.conv : text;
  import std.range : only, take, retro;

  return only(name.take(2).text(), name.retro.take(2).text()).filter!(c => c.length > 0)
    .joiner("/").text();
}

struct Repo {
  string path;
  bool pull() {
    import std.process : Config;

    auto oldHead = executeShellOrThrow("git rev-parse HEAD", null, Config.none, size_t.max, path);
    executeShellOrThrow("git pull origin --ff-only", null, Config.none, size_t.max, path);
    auto newHead = executeShellOrThrow("git rev-parse HEAD", null, Config.none, size_t.max, path);

    return oldHead.output != newHead.output;
  }
}

auto executeShellOrThrow(Args...)(auto ref Args args) {
  import std.process : executeShell;
  import std.functional : forward;

  auto result = executeShell(forward!args);
  if (result.status != 0)
    throw new Exception(args[0] ~ " failed", result.output);
  return result;
}
