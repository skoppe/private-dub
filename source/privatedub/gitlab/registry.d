module privatedub.gitlab.registry;

import privatedub.api : Token, AccessToken, JobToken;
import privatedub.gitlab.api;
import privatedub.gitlab.config;
import privatedub.work;
import concurrency.stoptoken;
import privatedub.registry;
import sumtype;
import std.algorithm : map, filter, joiner;
import std.array : array;
import dub.recipe.io;
import dub.recipe.packagerecipe;
import std.datetime.date : Date;
import dub.internal.vibecompat.data.json : Json, parseJsonString;
import std.typecons : Nullable;
import std.zip : ZipArchive;

struct GitlabDubPackage {
  int projectId;
  string name;
  VersionedPackage[] versions;
  Json toJson() {
    Json json = Json.emptyObject();
    json["versions"] = versions.map!(v => v.toJson()).array();
    json["projectId"] = projectId;
    json["name"] = name;
    return json;
  }

  static GitlabDubPackage fromJson(Json json) {
    auto p = GitlabDubPackage();
    p.projectId = json["projectId"].get!int;
    p.name = json["name"].get!string;
    p.versions = json["versions"][].map!(VersionedPackage.fromJson).array();
    return p;
  }
}

class GitlabRegistry : Registry {
  import std.datetime.date : Date;
  import std.typecons : Nullable;
  import core.sync.mutex : Mutex;

private:
  GitlabDubPackage[string] packages;
  GitlabConfig config;
  string packagesPath;
  enum string storageVersion = "2"; // increment when we modify the stuff we save to disk, it will trigger a recrawl
  Mutex mutex;
  Nullable!Date lastCrawl;
  auto lock() shared {
    import privatedub.sync : Guard;

    return Guard!(GitlabRegistry).acquire(this, cast() this.mutex);
  }

  auto lock() {
    import privatedub.sync : Guard;

    return Guard!(GitlabRegistry).acquire(cast(shared)this, this.mutex);
  }

  string getIndex(string name, int projectId) {
    import std.format : format;
    return format("%s-%s", name, projectId);
  }

  string getIndex(GitlabDubPackage pack) {
    return getIndex(pack.name, pack.projectId);
  }

  bool addPackage(GitlabDubPackage pack) {
    if (!findPackage(pack.name).isNull)
      return false;
    auto index = getIndex(pack);
    packages[index] = pack;
    return true;
  }

  private Nullable!GitlabDubPackage findPackage(string name) {
    import std.algorithm : find;
    auto it = packages.byValue.find!(p => p.name == name);
    if (it.empty)
      return typeof(return).init;
    return typeof(return)(it.front);
  }

public:
  this(GitlabConfig config) {
    import std.path : buildPath;
    import std.file : mkdirRecurse;

    mutex = new Mutex();
    this.config = config;
    this.packagesPath = buildPath(config.storage, config.hostname);
    mkdirRecurse(packagesPath);
    loadRegistry();
  }

  int priority() {
    return config.priority;
  }

  string getPrefix() {
    return config.prefix ~ ".";
  }

  PackageMeta[] search(string name) {
    // note we don't actually search, just match a single package and return if found
    return [getPackageMeta(name)];
  }

  PackageMeta getPackageMeta(string name) {
    import std.algorithm : startsWith;
    import std.exception : enforce;
    auto pack = findPackage(name);
    enforce(!pack.isNull, "Cannot find package "~name);

    return PackageMeta(this, name, pack.get.versions);
  }

  bool hasPackage(string name) {
    return !findPackage(name).isNull;
  }

  bool hasProjectRef(int projectId, string ref_, string commitId) shared {
    with (lock()) {
      import std.algorithm : canFind;

      return packages.byValue.canFind!(p => p.projectId == projectId
          && p.versions.canFind!(v => v.ref_ == ref_ && v.commitId == commitId));
    }
  }

  bool hasProject(int projectId) shared {
    with (lock()) {
      import std.algorithm : canFind;

      return packages.byValue.canFind!(p => p.projectId == projectId);
    }
  }

  Nullable!string getDownloadUri(string name, string ver_, Token token) {
    import std.uri : encodeComponent;
    import privatedub.util : andThen, orElse;

    return findPackage(name).andThen!((p) {
        auto uri = config.endpoints.archive(p.projectId, "v" ~ ver_);
        auto extra = token.match!((AccessToken t) => "&private_token="~encodeComponent(t.token),
                                  (JobToken t) => "&job_token="~encodeComponent(t.token),
                                  (_) => "");
        return uri~extra;
      });
  }

  ZipArchive mirror() {
    import privatedub.zip;
    if (!readyForQueries())
      return null;

    with (lock()) {
      return zipFolder(packagesPath);
    }
  }

  bool validateToken(Token token) {
    return token.match!((AccessToken t){
        return config.getVersion(t).isOk();
      }, (JobToken t){
        return true;
      }, (_) => false);
  }

  override string toString() {
    import std.format : format;
    return "gitlab(hostname = %s, prefix = %s)".format(config.hostname, config.prefix);
  }

  private GitlabDubPackage* getPackage(int projectId, string name) {
    return getIndex(name, projectId) in packages;
  }

  private void addVersionedPackage(int projectId, VersionedPackage p) shared {
    with (lock()) {
      import std.algorithm : canFind, countUntil;
      import std.conv : to;
      import std.stdio : stderr, writeln;

      auto name = p.recipe.name;
      auto pack = getPackage(projectId, name);
      if (pack is null) {
        if (!addPackage(GitlabDubPackage(projectId, name, [p])))
          stderr.writeln("Package with name '"~name~"' is duplicate, skipping. Please change the package name of projectId "~projectId.to!string~" if you want it served here.");
      } else {
        auto idx = pack.versions.countUntil!(v => v.ref_ == p.ref_);
        if (idx == -1)
          pack.versions = pack.versions ~ p;
        else
          pack.versions[idx] = p;
      }
    }
  }

  private void addVersionedSubPackage(int parentId, string parentName, string ref_, string path, PackageRecipe p) shared {
    with (lock()) {
      import std.algorithm : countUntil;

      auto pack = getPackage(parentId, parentName);
      if (pack !is null) {
        auto idx = pack.versions.countUntil!(v => v.ref_ == ref_);
        if (idx == -1) {
          return;
        }
        auto subIdx = pack.versions[idx].recipe.subPackages.countUntil!(s => s.path == path);

        if (subIdx == -1) {
          return;
        }

        pack.versions[idx].recipe.subPackages[subIdx].recipe = p;
        pack.versions[idx].recipe.subPackages[subIdx].path = null; // NOTE: have to set path to null otherwise dub serializer doesn't spit out the recipe to disk...
      }
    }
  }

  private void saveProject(int projectId) shared {
    with (lock()) {
      import std.algorithm : find, each;
      import std.range : empty, front;

      packages.byValue
        .filter!(p => p.projectId == projectId)
        .each!(p => saveToDisk(p));
    }
  }

  private void saveToDisk(GitlabDubPackage p) {
    import std.path : buildPath, withExtension;
    import std.file : write, rename, remove;
    import std.conv : text;

    auto filename = buildPath(packagesPath, getIndex(p) ~ ".json");
    auto tmpfilename = filename ~ ".tmp";

    write(tmpfilename, p.toJson().toString());
    rename(tmpfilename, filename);
  }

  private void loadRegistry() {
    import std.file : dirEntries, SpanMode, readText, exists;
    import std.path : buildPath, extension;
    import std.stdio;

    try {
      string ver = readText(versionFile);
      if (ver != storageVersion) {
        writeln(config.hostname, ": cache format changed, need to re-sync");
        clearRegistry();
        return;
      }
      lastCrawl = Nullable!Date(Date.fromISOExtString(readText(lastCrawlFile)));
    }
    catch (Exception e) {
      clearRegistry();
      // if something bad happens we will just abort the loading and resync the whole thing
      // on the next call to sync
      return;
    }
    foreach (string name; dirEntries(packagesPath, SpanMode.shallow)) {
      if (name.extension != ".json")
        continue;
      auto p = GitlabDubPackage.fromJson(parseJsonString(readText(name)));
      if (!addPackage(p)) {
        stderr.writeln("Duplicate package with name '"~p.name~"' on disk, skipping. Duplicate entry is '"~ name ~"'. Please remove file manually.");
      }
    }
  }

  private void clearRegistry() {
    import std.file : mkdirRecurse, rmdirRecurse;

    rmdirRecurse(packagesPath);
    mkdirRecurse(packagesPath);
    lastCrawl = typeof(lastCrawl).init;
  }

  private void completedCrawl() shared {
    with (lock()) {
      import std.file : write;

      if (!lastCrawl.isNull && lastCrawl.get == yesterday)
        return;

      lastCrawl = Nullable!Date(yesterday);
      write(lastCrawlFile, lastCrawl.get.toISOExtString);
      write(versionFile, storageVersion);
    }
  }

  private string versionFile() {
    import std.path : buildPath;

    return buildPath(config.storage, config.hostname, "version");
  }

  private string lastCrawlFile() {
    import std.path : buildPath;

    return buildPath(config.storage, config.hostname, "last-crawl");
  }

  void sync(StopToken stopToken) @trusted {
    (cast(shared) this).sync(stopToken);
  }

  bool readyForQueries() {
    return !lastCrawl.isNull;
  }

  void sync(StopToken stopToken) shared @trusted {
    import std.stdio;
    import privatedub.gitlab.crawler;

    struct CrawlerResultNotifier {
      shared GitlabRegistry registry;
      void notify(ref ProjectVersionedPackage task) {
        writefln("Adding version %s (projectId=%s, name=%s)", task.package_.ref_, task.projectId, task.package_.recipe.name);
        registry.addVersionedPackage(task.projectId, task.package_);
      }

      void notify(ref MarkProjectCrawled task) {
        registry.saveProject(task.projectId);
      }

      void notify(ref CrawlComplete task) {
        writeln(task);
        registry.completedCrawl();
      }

      void notify(ref ProjectVersionedSubPackage task) {
        writeln(task);
        registry.addVersionedSubPackage(task.parentId, task.parentName, task.ref_, task.path, task.subPackage);
      }
    }

    CrawlerScheduler crawler;
    if ((cast() lastCrawl).isNull) {
      if (!loadFromMirror()) {
        writeln(config.hostname, ": syncing metadata, this may take a few minutes.");
        crawler.queue.enqueue(crawler.queue.serial(FindProjects(), CrawlComplete()));
        if (!crawler.drain(stopToken, CrawlerResultNotifier(this), cast()config, this)) {
          writeln(config.hostname, ": syncing cancelled.");
          return;
        }
      }
      writeln(config.hostname, ": syncing done.");
    }
    assert(!(cast() lastCrawl).isNull);
    crawler.queue.enqueue(crawler.queue.serial(CrawlEvents((cast() lastCrawl)
        .get), CrawlComplete()));
    if (!crawler.drain(stopToken, CrawlerResultNotifier(this), cast()config, this))
      writeln(config.hostname, ": syncing cancelled.");
  }

  private bool loadFromMirror() shared {
    import requests;
    import std.path : buildPath;
    import privatedub.zip;

    if (config.mirror == "")
      return false;

    try {
      auto rq = Request();
      if (config.interceptor)
        rq.addInterceptor(cast()config.interceptor);
      auto response = rq.get(buildPath(config.mirror, "token", config.token, "mirror", config.prefix));
      auto archive = new ZipArchive(response.responseBody.data);
      with(lock) {
        unzipFolder(packagesPath, archive);
      }
      return true;
    } catch (Exception e) {
      import std.stdio;
      stderr.writeln("Failed to sync from mirror: ", e);
      return false;
    }
  }
}

Date yesterday() {
  import std.datetime.systime;

  return Date().fromISOExtString(Clock.currTime().roll!"days"(-1).toISOExtString()[0 .. 10]);
}
