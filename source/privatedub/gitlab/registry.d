module privatedub.gitlab.registry;

import privatedub.gitlab.api;
import privatedub.gitlab.config;
import privatedub.work;
import privatedub.registry;
import sumtype;
import std.algorithm : map, filter, joiner;
import std.array : array;
import dub.recipe.io;
import dub.recipe.packagerecipe;
import std.datetime.date : Date;
import dub.internal.vibecompat.data.json : Json, parseJsonString;

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
  immutable GitlabConfig config;
  immutable string packagesPath;
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
    return config.hostname;
  }

  PackageMeta getPackageMeta(string name) {
    import std.algorithm : startsWith;

    auto fullname = name;
    if (name.startsWith(config.hostname))
      name = name[config.hostname.length + 1 .. $];
    else
      fullname = config.hostname ~ "/" ~ name;
    return PackageMeta(this, name, packages[name].versions);
  }

  bool hasPackage(string name) {
    if (name in packages)
      return true;
    return false;
  }

  bool hasProjectRef(int projectId, string ref_) shared {
    with (lock()) {
      import std.algorithm : canFind;

      return packages.byValue.canFind!(p => p.projectId == projectId
          && p.versions.canFind!(v => v.ref_ == ref_));
    }
  }

  bool hasProject(int projectId) shared {
    with (lock()) {
      import std.algorithm : canFind;

      return packages.byValue.canFind!(p => p.projectId == projectId);
    }
  }

  string getDownloadUri(string name, string ver_) {
    throw new Exception("WIP");
  }

  private void addVersionedPackage(int projectId, VersionedPackage p) shared {
    with (lock()) {
      import std.algorithm : canFind;

      if (auto pack = p.recipe.name in packages) {
        if (!pack.versions.canFind!(v => v.ref_ == p.ref_))
          pack.versions = pack.versions ~ p;
        return;
      }
      packages[p.recipe.name] = GitlabDubPackage(projectId, p.recipe.name, [p]);
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

    auto filename = buildPath(packagesPath, p.name.withExtension("json").text());
    auto tmpfilename = filename ~ ".tmp";

    write(tmpfilename, p.toJson().toString());
    rename(tmpfilename, filename);
  }

  private void loadRegistry() {
    import std.file : dirEntries, SpanMode, readText, exists;
    import std.path : buildPath, extension;

    try {
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
    }
  }

  private string lastCrawlFile() {
    import std.path : buildPath;

    return buildPath(config.storage, config.hostname, "last-crawl");
  }

  void sync() {
    (cast(shared) this).sync();
  }

  void sync() shared {
    import std.stdio;
    import privatedub.gitlab.crawler;

    struct CrawlerResultNotifier {
      shared GitlabRegistry registry;
      void notify(ref ProjectVersionedPackage task) {
        writeln(registry.config.hostname,
            ": found " ~ task.package_.recipe.name ~ "@" ~ task.package_.ref_);
        registry.addVersionedPackage(task.projectId, task.package_);
      }

      void notify(ref MarkProjectCrawled task) {
        registry.saveProject(task.projectId);
      }

      void notify(ref CrawlComplete task) {
        registry.completedCrawl();
      }

      void notify(ref ProjectVersionedSubPackage task) {
        writeln(registry.config.hostname,
            ": found " ~ task.parent ~ ":" ~ task.subPackage.name ~ "@" ~ task.ref_);
        registry.addVersionedSubPackage(task.parent, task.ref_, task.path, task.subPackage);
      }
    }

    CrawlerScheduler crawler;
    if ((cast() lastCrawl).isNull) {
      writeln(config.hostname, ": syncing metadata, this may take a few minutes.");
      crawler.queue.enqueue(crawler.queue.serial(FindProjects(), CrawlComplete()));
      crawler.drain(CrawlerResultNotifier(this), config, this);
    }
    assert(!(cast() lastCrawl).isNull);
    crawler.queue.enqueue(crawler.queue.serial(CrawlEvents((cast() lastCrawl)
        .get), CrawlComplete()));
    crawler.drain(CrawlerResultNotifier(this), config, this);
  }
}

Date yesterday() {
  import std.datetime.systime;

  return Date().fromISOExtString(Clock.currTime().roll!"days"(-1).toISOExtString()[0 .. 10]);
}
