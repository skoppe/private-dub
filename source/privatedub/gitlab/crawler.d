module privatedub.gitlab.crawler;

import privatedub.gitlab.registry;
import privatedub.gitlab.api;
import privatedub.gitlab.config;
import privatedub.work;
import privatedub.registry;
import sumtype;
import std.algorithm : map, filter, joiner, each;
import std.typecons : Nullable;
import dub.recipe.packagerecipe;
import std.json : JSONValue;

struct FindProjects {
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config,
      shared GitlabRegistry registry) {
    auto projects = config.callProjectsEndpoint().paginate()
      .map!(p => p.content.tryMatch!((JsonContent content) => content.json.array)).joiner();
    foreach (project; projects) {
      auto id = cast(int) project["id"].integer;
      if (registry.hasProject(id)) {
        continue;
      }
      queue.enqueue(queue.serial(DetermineDubPackage(id, project["path_with_namespace"].str), MarkProjectCrawled(id)));
    }
  }
}

struct DetermineDubPackage {
  int projectId;
  string namespace;
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config) {
    if (config.isDubPackage(projectId))
      queue.enqueue(FetchTags(projectId, namespace));
  }
}

struct FetchTags {
  int projectId;
  string namespace;
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config) {
    import std.json;

    auto tags = config.getProjectTags(projectId).paginate()
      .map!(p => p.content.tryMatch!((JsonContent content) {
          try {
            return content.json.array();
          }
          catch (Exception e) {
            JSONValue[] json;
            return json;
          }
        })).joiner();
    foreach (tag; tags)
      queue.enqueue(FetchVersionedPackageFile(projectId, namespace,
          tag["name"].str, tag["commit"]["id"].str));
  }
}

struct FetchVersionedPackageFile {
  int projectId;
  string namespace;
  string ref_;
  string commitId;
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config) {
    import privatedub.util : orElse;

    auto parseProjectFile(string path) {
      return .parseProjectFile(config, projectId, path, ref_);
    }

    auto recipeOpt = parseProjectFile("dub.sdl").orElse(parseProjectFile("dub.json"));
    if (!recipeOpt.isNull) {
      auto recipe = recipeOpt.get();
      queue.enqueue(ProjectVersionedPackage(projectId, namespace, VersionedPackage(ref_, commitId, recipe)));
      if (recipe.subPackages.length > 0)
        recipe.subPackages.filter!(sub => sub.path.length > 0).each!(sub => queue.enqueue(FetchProjectSubPackage(recipe.name,
            projectId, ref_, sub.path)));
    }
  }
}

struct FetchProjectSubPackage {
  string parent;
  int projectId;
  string ref_;
  string path;
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config) {
    import std.path : buildPath;
    import privatedub.util : orElse;

    auto parseProjectFile(string path) {
      return .parseProjectFile(config, projectId, path, ref_);
    }

    auto recipeOpt = parseProjectFile(buildPath(path, "dub.sdl")).orElse(
        parseProjectFile(buildPath(path, "dub.json")));
    if (!recipeOpt.isNull)
      queue.enqueue(ProjectVersionedSubPackage(parent, ref_, path, recipeOpt.get));
  }
}

struct ProjectVersionedPackage {
  int projectId;
  string namespace;
  VersionedPackage package_;
}

struct ProjectVersionedSubPackage {
  string parent;
  string ref_;
  string path;
  PackageRecipe subPackage;
}

struct MarkProjectCrawled {
  int projectId;
  string fullname;
}

struct CrawlComplete {
}

JSONValue[] expectJSONArray(JsonContent content) {
  try {
    return content.json.array;
  } catch (Exception e) {
    import std.stdio;
    writeln(content.response);
    throw e;
  }
}

struct CrawlEvents {
  import std.datetime.date : Date;

  Date after;
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config,
      shared GitlabRegistry registry) {
    import std.array : appender, array;
    import std.algorithm : sort, chunkBy;

    // TODO: this misses mirrored projects
    auto events = config.getEvents("pushed", after).paginate()
      .map!(p => p.content.tryMatch!((JsonContent content) => content.expectJSONArray())).joiner();

    auto app = appender!(FetchVersionedPackageFile[]);
    foreach (event; events) {
      if (event["action_name"].str != "pushed new")
        continue;
      if ("push_data" !in event)
        continue;
      auto push = event["push_data"];
      if (push["action"].str != "created")
        continue;
      if (push["ref_type"].str != "tag")
        continue;
      auto projectId = cast(int) event["project_id"].integer;
      auto ref_ = push["ref"].str;
      auto commitId = push["commit_to"].str;
      if (!registry.hasProjectRef(projectId, ref_, commitId))
        app.put(FetchVersionedPackageFile(projectId, ref_, commitId));
    }
    auto chunks = app.data
      .sort!((a, b) => a.projectId < b.projectId)
      .chunkBy!(a => a.projectId);
    foreach (chunk; chunks) {
      queue.enqueue(queue.serial(queue.parallel(chunk[1].array()), MarkProjectCrawled(chunk[0])));
    }
  }
}

alias CrawlerWorkQueue = WorkQueue!(FindProjects, DetermineDubPackage, FetchTags, FetchVersionedPackageFile, ProjectVersionedPackage, MarkProjectCrawled,
    CrawlComplete, CrawlEvents, FetchProjectSubPackage, ProjectVersionedSubPackage);

alias CrawlerScheduler = Scheduler!CrawlerWorkQueue;

Nullable!PackageRecipe parseProjectFile(GitlabConfig config,
    int projectId, string filename, string ref_) {
  import std.base64;
  import std.exception : enforce;
  import dub.recipe.io;

  auto packageFile = config.getProjectFile(projectId, filename, ref_);
  if (!packageFile.isOk)
    return typeof(return).init;

  auto json = packageFile.content.tryMatch!((JsonContent content) => content.json);
  enforce(json["encoding"].str == "base64", "can only decode base64 encodings");
  auto content = (cast(string) Base64.decode(json["content"].str)).removeBOM;
  return typeof(return)(parsePackageRecipe(content, filename));
}

string removeBOM(string content) {
  import std.encoding : getBOM, bomTable, BOM;

  auto bom = (cast(ubyte[]) content).getBOM();
  if (bom.schema != BOM.none) {
    auto bomLength = bom.sequence.length;
    content = cast(string)((cast(ubyte[]) content)[bomLength .. $]);
  }
  return content;
}
