module privatedub.gitlab.registry;

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

struct GitlabDubPackage {
  int projectId;
  string namespace;
  string name;
  VersionedPackage[] versions;
  Json toJson() {
    Json json = Json.emptyObject();
    json["versions"] = versions.map!(v => v.toJson()).array();
    json["projectId"] = projectId;
    json["namespace"] = namespace;
    json["name"] = name;
    return json;
  }

  static GitlabDubPackage fromJson(Json json) {
    auto p = GitlabDubPackage();
    p.projectId = json["projectId"].get!int;
    p.name = json["name"].get!string;
    p.namespace = json["namespace"].get!string;
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
  enum string storageVersion = "1"; // increment when we modify the stuff we save to disk, it will trigger a recrawl
  Mutex mutex;
  Nullable!Date lastCrawl;
  auto lock() shared {
    import privatedub.sync : Guard;

    return Guard!(GitlabRegistry).acquire(this, cast() this.mutex);
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
    enforce(hasPackage(name), "Cannot find package "~name);

    return PackageMeta(this, name, packages[name].versions);
  }

  bool hasPackage(string name) {
    if (name in packages)
      return true;
    return false;
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

  string getDownloadUri(string name, string ver_, Nullable!string token) {
    import std.uri : encodeComponent;
    import privatedub.util : andThen, orElse;

    auto p = packages[name];
    auto uri = config.endpoints.archive(p.projectId, "v" ~ ver_);
    auto extra = token.andThen!(t => "&private_token="~encodeComponent(t)).orElse("");
    return uri~extra;
  }

  private void addVersionedPackage(int projectId, string namespace, VersionedPackage p) shared {
    with (lock()) {
      import std.algorithm : canFind, countUntil;

      if (auto pack = p.recipe.name in packages) {
        auto idx = pack.versions.countUntil!(v => v.ref_ == p.ref_);
        if (idx == -1)
          pack.versions = pack.versions ~ p;
        else
          pack.versions[idx] = p;
        return;
      }
      packages[p.recipe.name] = GitlabDubPackage(projectId, namespace, p.recipe.name, [p]);
    }
  }

  private void addVersionedSubPackage(string parent, string ref_, string path, PackageRecipe p) shared {
    with (lock()) {
      import std.algorithm : countUntil;

      if (auto pack = parent in packages) {
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
      import std.algorithm : find;
      import std.range : empty, front;

      auto r = packages.byValue.find!(p => p.projectId == projectId);
      if (!r.empty)
        saveToDisk(r.front());
    }
  }

  private void saveToDisk(GitlabDubPackage p) {
    import std.path : buildPath, withExtension;
    import std.file : write, rename, remove;
    import std.conv : text;

    auto filename = buildPath(packagesPath, p.name ~ ".json");
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
        return;
      }
      lastCrawl = Nullable!Date(Date.fromISOExtString(readText(lastCrawlFile)));
    }
    catch (Exception e) {
      // if something bad happens we will just abort the loading and resync the whole thing
      // on the next call to sync
      return;
    }
    foreach (string name; dirEntries(packagesPath, SpanMode.shallow)) {
      if (name.extension != ".json")
        continue;
      auto p = GitlabDubPackage.fromJson(parseJsonString(readText(name)));
      packages[p.name] = p;
    }
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
        writeln(task);
        registry.addVersionedPackage(task.projectId, task.namespace, task.package_);
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
        registry.addVersionedSubPackage(task.parent, task.ref_, task.path, task.subPackage);
      }
    }

    CrawlerScheduler crawler;
    if ((cast() lastCrawl).isNull) {
      writeln(config.hostname, ": syncing metadata, this may take a few minutes.");
      crawler.queue.enqueue(crawler.queue.serial(FindProjects(), CrawlComplete()));
      if (!crawler.drain(stopToken, CrawlerResultNotifier(this), cast()config, this)) {
        writeln(config.hostname, ": syncing cancelled.");
        return;
      }
      writeln(config.hostname, ": syncing done.");
    }
    assert(!(cast() lastCrawl).isNull);
    crawler.queue.enqueue(crawler.queue.serial(CrawlEvents((cast() lastCrawl)
        .get), CrawlComplete()));
    if (!crawler.drain(stopToken, CrawlerResultNotifier(this), cast()config, this))
      writeln(config.hostname, ": syncing cancelled.");
  }
}

void sync(shared GitlabRegistry registry) {

}

Date yesterday() {
  import std.datetime.systime;

  return Date().fromISOExtString(Clock.currTime().roll!"days"(-1).toISOExtString()[0 .. 10]);
}
