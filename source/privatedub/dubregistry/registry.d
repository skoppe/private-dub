module privatedub.dubregistry.registry;

import privatedub.registry;
import privatedub.api : Token;
import concurrency.stoptoken;
import dub.internal.vibecompat.data.json : Json, parseJsonString;
import dub.recipe.packagerecipe : PackageRecipe, BuildSettingsTemplate;
import std.typecons : Nullable;
import std.zip : ZipArchive;
import std.datetime : DateTime;

import dub.recipe.json : parseJson;

struct DubRegistryRegistryConfig {
  import dini : IniSection;
  import url : URL, parseURL;

  enum type = "dlang";
  int priority = 3;
  URL upstream;

  static DubRegistryRegistryConfig loadConfig(IniSection section) {
    import std.conv : to;

    return DubRegistryRegistryConfig(
      section.getKey("priority", DubRegistryRegistryConfig.init.priority.to!string).to!int,
      section.getKey("upstream", "https://code.dlang.org").parseURL);
  }
}

struct CacheEntry {
  DateTime time;
  Json content;
}

class DubRegistryRegistry : Registry {
  import core.sync.mutex : Mutex;

private:
  DubRegistryRegistryConfig config;
  CacheEntry[string] cache;
  Mutex mutex;

  auto lock() shared {
    import privatedub.sync : Guard;

    return Guard!(DubRegistryRegistry).acquire(this, cast() this.mutex);
  }

  auto lock() @trusted {
    return (cast(shared)this).lock();
  }

public:
  this(DubRegistryRegistryConfig config) {
    this.config = config;
    this.mutex = new Mutex();
  }

  void sync(StopToken stopToken) @trusted {
  }

  void sync(StopToken stopToken) shared @trusted {
  }

  bool readyForQueries() {
    return true;
  }

  int priority() {
    return config.priority;
  }

  string getPrefix() {
    return "";
  }

  void validate() {}

  string getPackageUrl(string name) {
    import std.algorithm : startsWith;
    import std.exception : enforce;
    import std.conv : text;
    import std.format : format;
    auto pack = getPackage(name);
    enforce(!pack.isNull, "Cannot find package "~name);

    auto repo = pack.get["repository"];
    auto domain = repo["kind"].get!string.getRepositoryDomain();
    auto owner = repo["owner"].get!string;
    auto project = repo["project"].get!string;

    return format("https://%s/%s/%s", domain, owner, project);
  }

  PackageMeta[] search(string name) {
    // note we don't actually search, just match a single package and return if found
    return [getPackageMeta(name)];
  }

  PackageMeta getPackageMeta(string name) {
    import std.algorithm : map;
    import privatedub.dlang.registry : normalizeVersion;
    import std.array : array;

    auto content = getPackage(name);
    if (content.isNull)
      throw new Exception("Not found");

    return PackageMeta(this, name, content.get["versions"][].map!((v) {
        PackageRecipe recipe;
        parseJson(recipe, v, "");
        return VersionedPackage(v["version"].get!string.normalizeVersion, "", recipe);
      }).array());
  }

  bool hasPackage(string name) {
    return !getPackage(name).isNull;
  }

  Nullable!string getDownloadUri(string name, string rawVer, Token token) {
    import std.algorithm : find;
    import std.range : front, empty;
    import std.format : format;

    return typeof(return)(config.upstream ~ "packages/%s/%s.zip".format(name, rawVer));
  }

  ZipArchive mirror() {
    return null;
  }

  bool validateToken(Token token) {
    return true;
  }

  override string toString() {
    return "dub-registry @ "~config.upstream;
  }

  private Nullable!Json getPackage(string name) {
    import std.datetime.systime : Clock;
    import core.time : minutes;
    import std.uri : encodeComponent;
    import requests : Request;

    auto now = cast(DateTime)Clock.currTime;
    if (auto c = name in cache) {
      if (c.time + 3.minutes > now) {
        return Nullable!Json(c.content);
      }
    }
    auto packages = `["`~name~`"]`;
    auto url = config.upstream ~ "/api/packages/infos";
    url.queryParams.add("packages", packages);
    url.queryParams.add("minimize", "false");
    auto rq = Request();
    auto response = rq.get(url);
    auto content = parseJsonString(cast(string) response.responseBody.data)[name];
    if (content.type == Json.Type.null_) {
      return Nullable!Json();
    }
    cache[name] = CacheEntry(now, content);
    return Nullable!Json(content);
  }
}

private string getRepositoryDomain(string kind) {
  switch (kind) {
  case "github": return "github.com";
  case "gitlab": return "gitlab.com";
  default:
    throw new Exception("Unknown repository "~kind);
  }
}
