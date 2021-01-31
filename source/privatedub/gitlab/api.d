module privatedub.gitlab.api;

import std.json;
import sumtype;
import std.datetime.date : Date;
import privatedub.gitlab.config;

Endpoints endpoints(GitlabConfig config) {
  return Endpoints(config.baseUrl);
}

auto makeRequest(GitlabConfig config) {
  import requests;

  auto rq = Request();
  rq.addHeaders(["PRIVATE-TOKEN": config.token]);
  return rq;
}

struct Endpoints {
  import std.uri : encodeComponent;
  import std.path : buildPath;

  private string host;

  this(string host) {
    this.host = host;
  }

  string projects() {
    return buildPath(host, "projects");
  }

  string files(int projectId, string filePath, string ref_) {
    import std.conv : to;

    return buildPath(projects(), projectId.to!string, "repository/files",
        encodeComponent(filePath) ~ "?ref=" ~ ref_);
  }

  string project(int projectId) {
    import std.conv : to;
    return buildPath(projects(), projectId.to!string);
  }

  string tags(int projectId) {
    import std.conv : to;

    return buildPath(projects(), projectId.to!string, "repository/tags");
  }

  string events(string action, Date after) {
    return buildPath(host,
        "events?action=" ~ action ~ "&scope=all&sort=asc&after=" ~ after.toISOExtString());
  }

  string archive(int projectId, string ref_) {
    import std.conv : to;

    return buildPath(projects(), projectId.to!string, "repository/archive.zip?sha="~ref_);
  }
}

struct Link {
  string[string] params;
  string uri;
}

Link[] parseLinkHeader(string header) {
  import std.algorithm : splitter, map;
  import std.exception : enforce;
  import std.string : split, strip;
  import std.array : assocArray, array;
  import std.typecons : tuple;

  return header.splitter(',').map!((item) {
    auto parts = item.split(';');
    enforce(parts.length > 1, "need at least 2 parts in a link header item");
    auto uri = parts[0].strip()[1 .. $ - 1];
    string[string] params = parts[1 .. $].map!((part) {
      auto kv = part.strip.split('=');
      return tuple(kv[0].strip(" \""), kv[1].strip(" \""));
    }).assocArray();
    return Link(params, uri);
  }).array();
}

unittest {
  import unit_threaded;

  auto links = "<https://first>; rel=\"first\", <https://second>; rel=\"second\"; another=2"
    .parseLinkHeader;
  links.shouldEqual([
      Link(["rel": "first"], "https://first"),
      Link(["rel": "second", "another": "2"], "https://second")
      ]);
}

struct JsonContent {
  import requests : Response;

  Response response;
  JSONValue json() {
    try {
    return parseJSON(cast(string) response.responseBody.data);
    } catch (Exception e) {
      import std.stdio;
      writeln(cast(string)response.responseBody.data);
      throw e;
    }
  }

  string text() {
    return cast(string) response.responseBody.data;
  }
}

struct TextContent {
  import requests : Response;

  Response response;
  string text() {
    return cast(string) response.responseBody.data;
  }
}

struct RawContent {
  import requests : Response;

  Response response;
  ubyte[] raw() {
    return response.responseBody.data;
  }
}

alias Content = SumType!(JsonContent, TextContent, RawContent);

struct GitlabResponse {
  import requests : Response;
  import std.typecons : Nullable, nullable;
  import std.exception : enforce;

  private Response response;
  private GitlabConfig config;

  this(Response response, GitlabConfig config) {
    this.response = response;
    this.config = config;
  }

  Content content() {
    import std.algorithm : startsWith;

    auto type = "content-type" in response.responseHeaders;
    enforce(type !is null, "Expected 'content-type' header");
    if (*type == "application/json")
      return Content(JsonContent(response));
    if ((*type).startsWith("text"))
      return Content(TextContent(response));
    return Content(RawContent(response));
  }

  Nullable!Link getLink(string rel) {
    import std.algorithm : find;
    import std.range : empty, front;

    if (auto link = "link" in response.responseHeaders()) {
      auto links = parseLinkHeader(*link);
      auto next = links.find!(l => l.params.get("rel", "") == rel);
      if (next.empty)
        return typeof(return).init;
      return typeof(return)(next.front);
    }
    return typeof(return).init;
  }

  bool isOk() {
    return response.code >= 200 && response.code < 300;
  }

  Nullable!GitlabResponse next() {
    auto next = getLink("next");

    if (next.isNull)
      return typeof(return).init;

    return typeof(return)(GitlabResponse(config.makeRequest().get(next.get.uri), config));
  }

  auto paginate() {
    return PaginatedGitlabResponse(this);
  }
}

GitlabResponse callProjectsEndpoint(GitlabConfig config) {
  return GitlabResponse(config.makeRequest()
      .get(config.endpoints.projects() ~ "?pagination=keyset&per_page=50&order_by=id&sort=asc"),
      config);
}

GitlabResponse getProject(GitlabConfig config, int projectId) {
  return GitlabResponse(config.makeRequest().get(config.endpoints.project(projectId)), config);
}

GitlabResponse getProjectFile(GitlabConfig config, int id, string filepath, string ref_) {
  auto endpoint = config.endpoints.files(id, filepath, ref_);
  return GitlabResponse(config.makeRequest().get(endpoint), config);
}

GitlabResponse getProjectTags(GitlabConfig config, int id) {
  return GitlabResponse(config.makeRequest().get(config.endpoints.tags(id)), config);
}

GitlabResponse getProjectFileMeta(GitlabConfig config, int id, string filepath, string ref_) {
  return GitlabResponse(config.makeRequest().execute("HEAD",
      config.endpoints.files(id, filepath, ref_)), config);
}

GitlabResponse getEvents(GitlabConfig config, string action, Date after) {
  return GitlabResponse(config.makeRequest().execute("GET",
      config.endpoints.events(action, after)), config);
}

struct PaginatedGitlabResponse {
  import std.typecons : Nullable;

  Nullable!GitlabResponse head;
  this(GitlabResponse head) {
    this.head = Nullable!GitlabResponse(head);
  }

  bool empty() {
    return head.isNull;
  }

  auto front() {
    return head.get;
  }

  void popFront() {
    head = head.next();
  }
}

bool isDubPackage(GitlabConfig config, int projectId) {
  return config.getProjectFileMeta(projectId, "dub.sdl", "master").isOk()
    || config.getProjectFileMeta(projectId, "dub.json", "master").isOk();
}

struct GitlabDubPackage {
  int projectId;
}
