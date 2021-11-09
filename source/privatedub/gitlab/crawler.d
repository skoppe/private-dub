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
      queue.enqueue(queue.serial(DetermineDubPackage(id), MarkProjectCrawled(id)));
    }
  }
}

struct DetermineDubPackage {
  int projectId;
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config) {
    string branch = config.getDefaultBranch(projectId);
    if (config.isDubPackage(projectId, branch))
      queue.enqueue(FetchTags(projectId));
  }
}

struct FetchTags {
  int projectId;
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config,
                      shared GitlabRegistry registry) {
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
    foreach (tag; tags) {
      if (!registry.hasProjectRef(projectId, tag["name"].str, tag["commit"]["id"].str))
        queue.enqueue(FetchVersionedPackageFile(projectId, tag["name"].str, tag["commit"]["id"].str));
    }
  }
}

struct FetchVersionedPackageFile {
  int projectId;
  string ref_;
  string commitId;
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config, shared GitlabRegistry registry) {
    import privatedub.util : orElse;

    auto parseProjectFile(string path) {
      return .parseProjectFile(config, projectId, path, ref_);
    }
    if (registry.hasProjectRef(projectId, ref_, commitId))
      return;
    if (registry.isTagIgnored(projectId, ref_, commitId))
      return;

    auto recipeOpt = parseProjectFile("dub.sdl").orElse(parseProjectFile("dub.json"));
    if (!recipeOpt.isNull) {
      auto recipe = recipeOpt.get();
      queue.enqueue(ProjectVersionedPackage(projectId, VersionedPackage(ref_, commitId, recipe)));
      if (recipe.subPackages.length > 0)
        recipe.subPackages.filter!(sub => sub.path.length > 0).each!(sub => queue.enqueue(FetchProjectSubPackage(projectId, recipe.name, ref_, sub.path)));
    } else {
      registry.ignoreTag(projectId, ref_, commitId);
    }
  }
}

struct FetchProjectSubPackage {
  int parentId;
  string parentName;
  string ref_;
  string path;
  void run(WorkQueue)(ref WorkQueue queue, GitlabConfig config) {
    import std.path : buildPath;
    import privatedub.util : orElse;

    auto parseProjectFile(string path) {
      return .parseProjectFile(config, parentId, path, ref_);
    }

    auto recipeOpt = parseProjectFile(buildPath(path, "dub.sdl")).orElse(
        parseProjectFile(buildPath(path, "dub.json")));
    if (!recipeOpt.isNull)
      queue.enqueue(ProjectVersionedSubPackage(parentId, parentName, ref_, path, recipeOpt.get));
  }
}

struct ProjectVersionedPackage {
  int projectId;
  VersionedPackage package_;
}

struct ProjectVersionedSubPackage {
  int parentId;
  string parentName;
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
    import std.algorithm : sort, chunkBy, map, filter, canFind;

    // TODO: this misses mirrored projects
    auto events = config.getEvents("pushed", after).paginate()
      .map!(p => p.content.tryMatch!((JsonContent content) => content.expectJSONArray())).joiner();

    auto singleTagEvents = appender!(SingleTagEvent[]);
    auto multipleTagEvents = appender!(MultipleTagEvent[]);
    foreach (event; events) {
      auto newTagOpt = event.extractNewTagEvent;
      if (newTagOpt.isNull)
        continue;
      newTagOpt.get.match!((SingleTagEvent tag){
          if (!registry.hasProjectRef(tag.projectId, tag.ref_, tag.commitId))
            singleTagEvents.put(tag);
        },(MultipleTagEvent tag){
          multipleTagEvents.put(tag);
        },(InvalidTagEvent tag){
          import std.stdio : stderr;
          import std.conv : to;
          stderr.writeln("Invalid tag event received: "~tag.event.toString());
          stderr.writeln("Recrawling project "~tag.projectId.to!string);
          stderr.flush();
          multipleTagEvents.put(MultipleTagEvent(tag.projectId)); // ensure we crawl the project
        });
    }
    auto projectsToRecrawl = multipleTagEvents.data
      .sort!((a, b) => a.projectId < b.projectId)
      .chunkBy!(a => a.projectId)
      .map!(chunk => chunk[0])
      .array();

    auto chunkedTagsToFetch = singleTagEvents.data
      .sort!((a, b) => a.projectId < b.projectId)
      .chunkBy!(a => a.projectId)
      .filter!(chunk => !projectsToRecrawl.canFind(chunk[0]));

    foreach (chunk; chunkedTagsToFetch) {
      auto next = chunk[1]
        .filter!(event => !registry.hasProjectRef(event.projectId, event.ref_, event.commitId) && !registry.isTagIgnored(event.projectId, event.ref_, event.commitId))
        .map!(event => FetchVersionedPackageFile(event.projectId, event.ref_, event.commitId));
      queue.enqueue(queue.serial(queue.parallel(next.array()), MarkProjectCrawled(chunk[0])));
    }

    foreach (projectId; projectsToRecrawl) {
      queue.enqueue(queue.serial(FetchTags(projectId), MarkProjectCrawled(projectId)));
    }
  }
}

struct SingleTagEvent {
  int projectId;
  string ref_;
  string commitId;
}

struct MultipleTagEvent {
  int projectId;
}

struct InvalidTagEvent {
  int projectId;
  JSONValue event;
}

alias NewTagEvent = SumType!(SingleTagEvent, MultipleTagEvent, InvalidTagEvent);

Nullable!NewTagEvent extractNewTagEvent(JSONValue event) {
  if (event["action_name"].str != "pushed new")
    return typeof(return).init;
  if ("push_data" !in event)
    return typeof(return).init;
  auto push = event["push_data"];
  if (push["action"].str != "created")
    return typeof(return).init;
  if (push["ref_type"].str != "tag")
    return typeof(return).init;
  auto projectId = cast(int) event["project_id"].integer;
  try {
    if (push["ref_count"].isNull) {
      auto ref_ = push["ref"].str;
      auto commitId = push["commit_to"].str;
      return typeof(return)(NewTagEvent(SingleTagEvent(projectId, ref_, commitId)));
    } else {
      return typeof(return)(NewTagEvent(MultipleTagEvent(projectId)));
    }
  } catch (Exception e) {
    return typeof(return)(NewTagEvent(InvalidTagEvent(projectId, event)));
  }
}

@("events.extract.NewTagEvent.single")
unittest {
  import unit_threaded;
  import std.json : parseJSON;
  enum rawEvent = `{"action_name":"pushed new","author":{"avatar_url":"https:\/\/git.example.com\/uploads\/-\/system\/user\/avatar\/42\/avatar.png","id":42,"name":"John Doe","state":"active","username":"jdoe","web_url":"https:\/\/git.examples.com\/jdoe"},"author_id":42,"author_username":"jdoe","created_at":"2021-10-10T10:39:42.931Z","id":23403,"project_id":892,"push_data":{"action":"created","commit_count":1,"commit_from":null,"commit_title":"Some commit","commit_to":"3ee2d8ef4875b4b3c4798dbc3b6fea1447a5f51c","ref":"v2.9.9","ref_count":null,"ref_type":"tag"},"target_id":null,"target_iid":null,"target_title":null,"target_type":null}`;
  auto tagEvent = extractNewTagEvent(parseJSON(rawEvent));
  tagEvent.isNull.shouldBeFalse;
  tagEvent.get.tryMatch!((SingleTagEvent event){
      event.projectId.should == 892;
      event.ref_.should == "v2.9.9";
      event.commitId.should == "3ee2d8ef4875b4b3c4798dbc3b6fea1447a5f51c";
    });
}

@("events.extract.NewTagEvent.multiple")
unittest {
  import unit_threaded;
  import std.json : parseJSON;
  enum rawEvent = `{"action_name":"pushed new","author":{"avatar_url":"https:\/\/git.example.com\/uploads\/-\/system\/user\/avatar\/42\/avatar.png","id":42,"name":"John Doe","state":"active","username":"jdoe","web_url":"https:\/\/git.examples.com\/jdoe"},"author_id":42,"author_username":"jdoe","created_at":"2021-10-10T10:39:42.931Z","id":23403,"project_id":892,"push_data":{"commit_count": 0,"action": "created","ref_type": "tag","commit_from": null,"commit_to": null,"ref": null,"commit_title": null,"ref_count": 13},"target_id":null,"target_iid":null,"target_title":null,"target_type":null}`;
  auto tagEvent = extractNewTagEvent(parseJSON(rawEvent));
  tagEvent.isNull.shouldBeFalse;
  tagEvent.get.tryMatch!((MultipleTagEvent event){
      event.projectId.should == 892;
    });
}

@("events.extract.NewTagEvent.none")
unittest {
  import unit_threaded;
  import std.json : parseJSON;
  enum rawEvent = `{"action_name":"pushed new","author":{"avatar_url":"https:\/\/git.example.com\/uploads\/-\/system\/user\/avatar\/42\/avatar.png","id":42,"name":"John Doe","state":"active","username":"jdoe","web_url":"https:\/\/git.examples.com\/jdoe"},"author_id":42,"author_username":"jdoe","created_at":"2021-10-10T10:39:42.931Z","id":23403,"project_id":892,"target_id":null,"target_iid":null,"target_title":null,"target_type":null}`;
  auto tagEvent = extractNewTagEvent(parseJSON(rawEvent));
  tagEvent.isNull.shouldBeTrue;
}

@("events.extract.NewTagEvent.invalid")
unittest {
  import unit_threaded;
  import std.json : parseJSON;
  enum rawEvent = `{"action_name":"pushed new","author":{"avatar_url":"https:\/\/git.example.com\/uploads\/-\/system\/user\/avatar\/42\/avatar.png","id":42,"name":"John Doe","state":"active","username":"jdoe","web_url":"https:\/\/git.examples.com\/jdoe"},"author_id":42,"author_username":"jdoe","created_at":"2021-10-10T10:39:42.931Z","id":23403,"project_id":892,"push_data":{"commit_count": 0,"action": "created","ref_type": "tag","commit_from": null,"commit_to": null,"ref": null,"commit_title": null,"ref_count": null},"target_id":null,"target_iid":null,"target_title":null,"target_type":null}`;
  auto tagEvent = extractNewTagEvent(parseJSON(rawEvent));
  tagEvent.isNull.shouldBeFalse;
  tagEvent.get.tryMatch!((InvalidTagEvent event){
      event.projectId.should == 892;
    });
}

alias CrawlerWorkQueue = WorkQueue!(FindProjects, DetermineDubPackage, FetchTags, FetchVersionedPackageFile, ProjectVersionedPackage, MarkProjectCrawled,
                                    CrawlComplete, CrawlEvents, FetchProjectSubPackage, ProjectVersionedSubPackage);

alias CrawlerScheduler = Scheduler!CrawlerWorkQueue;

Nullable!PackageRecipe parseProjectFile(GitlabConfig config,
    int projectId, string filename, string ref_) {
  import std.base64;
  import std.exception : enforce;
  import dub.recipe.io;
  import std.stdio : stderr;

  auto packageFile = config.getProjectFile(projectId, filename, ref_);
  if (!packageFile.isOk)
    return typeof(return).init;

  auto json = packageFile.content.tryMatch!((JsonContent content) => content.json);
  enforce(json["encoding"].str == "base64", "can only decode base64 encodings");

  auto content = (cast(string) Base64.decode(json["content"].str)).removeBOM;
  try {
    return typeof(return)(parsePackageRecipe(content, filename));
  } catch (Exception e) {
    stderr.writefln("Skipping package file from %d @ %s: %s", projectId, ref_, e.message);
    stderr.flush();
    return typeof(return).init;
  }
}

@("parsePackageRecipe")
unittest {
  import unit_threaded;
  import dub.recipe.io;

  enum dubsdl = `name "foobar"
dependency "foobar:fx" version="*"
subPackage "./fx/"
targetType "library"
`;
  auto recipe = parsePackageRecipe(dubsdl, "dub.sdl");
  recipe.subPackages.length.should == 1;
  recipe.subPackages[0].path.should == "./fx/";
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
