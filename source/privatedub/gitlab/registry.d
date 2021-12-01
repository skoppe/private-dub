module privatedub.gitlab.registry;

import privatedub.api : Token, AccessToken, OAuthToken;
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
  bool[string] ignoredTags;
  GitlabConfig config;
  string packagesPath;
  enum string storageVersion = "3"; // increment when we modify the stuff we save to disk, it will trigger a recrawl
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

  auto allPackages() {
    import std.algorithm : startsWith;
    return packages.byValue().filter!(p => p.name.startsWith(getPrefix));
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

  private string tagKey(int projectId, string ref_, string commitId) {
    import std.format : format;
    return "%s-%s-%s".format(projectId, ref_, commitId);
  }

  void ignoreTag(int projectId, string ref_, string commitId) shared {
    with (lock()) {
      ignoredTags[tagKey(projectId, ref_, commitId)] = true;
    }
  }

  bool isTagIgnored(int projectId, string ref_, string commitId) shared {
    with (lock()) {
      return null !is (tagKey(projectId, ref_, commitId) in ignoredTags);
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
                                  (OAuthToken t) => "&access_token="~encodeComponent(t.token),
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
      }, (OAuthToken t){
        return true;
      }, (_) => false);
  }

  void validate() {
    import std.exception;
    enforce(validateToken(Token(AccessToken(config.token))), "invalid token in configuration for hostname = "~config.hostname);
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
      loadLastCrawl();
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

  private void loadLastCrawl() {
    import std.file : readText;
    lastCrawl = Nullable!Date(Date.fromISOExtString(readText(lastCrawlFile)));
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

      if (!lastCrawl.isNull && lastCrawl.get == yesterdayish)
        return;

      lastCrawl = Nullable!Date(yesterdayish);
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

    if ((cast() lastCrawl).isNull) {
      if (!loadFromMirror()) {
        writeln(config.hostname, ": syncing metadata, this may take a few minutes.");
        if (!this.crawl(stopToken, CrawlerScheduler.Queue.serial(FindProjects(), CrawlComplete()))) {
          writeln(config.hostname, ": syncing cancelled.");
          return;
        }
      }
      writeln(config.hostname, ": syncing done.");
    }
    assert(!(cast() lastCrawl).isNull);
    if (!this.crawl(stopToken, CrawlerScheduler.Queue.serial(CrawlEvents((cast() lastCrawl).get), CrawlComplete())))
      writeln(config.hostname, ": syncing cancelled.");
    stdout.flush();
  }

  auto crawlProject(StopToken stopToken, int projectId) @trusted {
    import privatedub.gitlab.crawler;
    return this.crawl(stopToken, DetermineDubPackage(projectId));
  }

  bool crawl(T)(StopToken stopToken, T t) @trusted {
    return (cast(shared)this).crawl!T(stopToken, t);
  }

  bool crawl(T)(StopToken stopToken, T t) shared @trusted {
    import std.stdio;
    import privatedub.gitlab.crawler;

    struct CrawlerResultNotifier {
      shared GitlabRegistry registry;
      void notify(ref ProjectVersionedPackage task) {
        writefln("Adding version %s (projectId=%s, name=%s)", task.package_.ref_, task.projectId, task.package_.recipe.name);
        stdout.flush();
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
        writefln("Adding version %s (projectId=%s, name=%s)", task.ref_, task.parentId, task.subPackage.name);
        stdout.flush();
        registry.addVersionedSubPackage(task.parentId, task.parentName, task.ref_, task.path, task.subPackage);
      }
    }

    CrawlerScheduler crawler;
    crawler.queue.enqueue(t);
    return crawler.drain(stopToken, CrawlerResultNotifier(this), cast()config, this);
  }

  private bool loadFromMirror() shared {
    import requests;
    import std.path : buildPath;
    import privatedub.zip;
    import std.conv : to;
    import std.file : readText;

    if (config.mirror == "")
      return false;

    import std.stdio;
    writeln("Loading gitlab registry "~config.hostname~" from mirror "~config.mirror);
    stdout.flush();
    try {
      auto rq = Request();
      if (config.interceptor)
        rq.addInterceptor(cast()config.interceptor);
      auto response = rq.get(buildPath(config.mirror, "token", config.token, "mirror", config.prefix));
      if (response.code < 200 || response.code > 300)
        throw new Exception("Got status "~response.code.to!string);
      auto archive = new ZipArchive(response.responseBody.data);
      with(lock) {
        unzipFolder(packagesPath, archive);
        string ver = readText(versionFile);
        if (ver != storageVersion) {
          writeln(config.hostname, ": cache format changed, need to re-sync");
          clearRegistry();
          return false;
        }
        loadRegistry();
      }
      return true;
    } catch (Exception e) {
      import std.stdio;
      stderr.writeln("Failed to sync from mirror: ", e);
      stderr.flush();
      return false;
    }
  }
}

private Date yesterdayish() {
  import std.datetime.systime : Clock;
  import core.time : hours;
  return cast(typeof(return))(Clock.currTime() - 25.hours);
}

unittest {
  import unit_threaded;
  auto gitlabConfig = GitlabConfig("abcd","git.example.com","./tmp/storage",1,"test.", "");
  auto registry = cast(shared) new GitlabRegistry(gitlabConfig);

  import privatedub.resolve;
  import dub.recipe.io;

  enum rootSdl = `name "foo.bar"
dependency "foo.bar:fx" version="*"
subPackage "./fx/"
targetType "library"
`;

  enum subSdl = `name "fx"
description "fx library"
copyright "Copyright © 2021, foobar"
authors "foobar"
`;

  auto rootPackage = VersionedPackage("v0.0.1", "commit", parsePackageRecipe(rootSdl, "dub.sdl"));
  registry.addVersionedPackage(55, rootPackage);
  registry.addVersionedSubPackage(55, "foo.bar", "v0.0.1", "./fx/", parsePackageRecipe(subSdl, "dub.sdl"));

  auto pkg = registry.lock().findPackage("foo.bar");
  pkg.get.toJson().toString.should == `{"projectId":55,"versions":[{"version":"v0.0.1","recipe":{"subPackages":[{"description":"fx library","authors":["foobar"],"copyright":"Copyright © 2021, foobar","name":"fx"}],"dependencies":{"foo.bar:fx":">=0.0.0"},"targetType":"library","name":"foo.bar"},"commitId":"commit"}],"name":"foo.bar"}`;
  pkg.get.projectId.should == 55;
  pkg.get.name.should == "foo.bar";
  pkg.get.versions.length.should == 1;
  pkg.get.versions[0].recipe.toPackageDependencyInfo().toString.should == `{"subPackages":[{"dependencies":{},"configurations":[],"name":"fx"}],"dependencies":{"foo.bar:fx":">=0.0.0"},"configurations":[],"name":"foo.bar"}`;
}
