module privatedub.api;

import privatedub.server;
import privatedub.registry;
import privatedub.resolve;
import privatedub.util;
import std.meta : AliasSeq;
import std.typecons : Nullable;
import sumtype;
import concurrency.sender : toSenderObject, SenderObjectBase;

auto api(Registry[] registries) {
  import concurrency.nursery;
  import concurrency.thread;
  import concurrency.operations;
  import concurrency.utils;

  auto regs = registries.dup();
  auto nursery = new shared Nursery();

  nursery.run(ThreadSender().then(closure((shared Nursery nursery, Registry[] regs) @trusted {
        import std.stdio;
        import std.traits : getUDAs;

        writeln("Server started");
        void handleConnection(Cgi cgi) @trusted {
          PathRequest pathRequest = PathRequest(cgi.pathInfo, cgi.get);
          static foreach (route; Routes) {
            static foreach (path; getUDAs!(route, Path)) {
              {
                auto match = pathRequest.matches(path);
                if (!match.isNull) {
                  auto task = route(match.get, regs, cgi);
                  if (task !is null)
                    nursery.run(task);
                  return;
                }
              }
            }
          }
          cgi.setResponseStatus("404 Not Found");
          cgi.close();
        }


        runCgi!(handleConnection)(nursery, 8889, "0.0.0.0");
        }, nursery, regs)));
  return nursery;
}

alias Routes = AliasSeq!(getInfos, getDownloadUri, getPackages, isReadyForQueries, mirror, packages, crawlProject);

struct NullToken {
}

struct AccessToken {
  string token;
}

struct OAuthToken {
  string token;
}

alias Token = SumType!(NullToken, AccessToken, OAuthToken);

@(Path("/token/$token/api/packages/search"))
@(Path("/oauthtoken/$oauthtoken/api/packages/search"))
@(Path("/api/packages/search"))
SenderObjectBase!void getPackages(MatchedPath path, Registry[] registries, Cgi cgi) {
  import std.algorithm : map;
  import asdf;
  import std.string : stripLeft;

  try {
    string q = path.query["q"];
    auto package_ = PackageName.parse(q);
    auto reg = registries.findRegistry(package_);
    cgi.setResponseContentType("application/json");
    cgi.setResponseStatus("200 Ok");
    if (reg.isNull) {
      cgi.write(`[]`);
    } else {
      auto results = reg.get().search(package_.base);
      auto sr = results.map!(result => SearchResult(result.name, null, result.versions.highestVersion().stripLeft("v")));
      cgi.write(sr.serializeToJson());
    }
  } catch (Exception e) {
    import std.stdio;
    writeln(e);
    cgi.setResponseStatus("404 Not Found");
  }
  cgi.close();
  return null;
}

@(Path("/token/$token/api/packages/infos"))
@(Path("/oauthtoken/$oauthtoken/api/packages/infos"))
@(Path("/api/packages/infos"))
SenderObjectBase!void getInfos(MatchedPath path, Registry[] registries, Cgi cgi) {
  import dub.internal.vibecompat.data.json : Json, parseJsonString;
  import std.format : format;
  import std.exception : enforce;

  try {
    Json packages = parseJsonString(path.query["packages"]);
    enforce(packages.length > 0, "must request at least one package");
    auto aa = resolve(registries, packages[0].get!string);
    cgi.setResponseContentType("application/json");
    cgi.setResponseStatus("200 Ok");
    if (aa.length == 0) {
      cgi.write(`{"%s":null}`.format(packages[0].get!string));
    } else {
      cgi.write(aa.toPackageDependencyInfo.toString());
    }
  } catch (Exception e) {
    import std.stdio;
    writeln(e);
    cgi.setResponseStatus("404 Not Found");
  }
  cgi.close();
  return null;
}

@(Path("/token/$token/packages/$name/$version"))
@(Path("/oauthtoken/$oauthtoken/packages/$name/$version"))
@(Path("/packages/$name/$version"))
SenderObjectBase!void getDownloadUri(MatchedPath path, Registry[] registries, Cgi cgi) {
  import std.path : stripExtension;

  auto name = path.params["name"];
  auto ver = path.params["version"];
  auto reg = registries.findRegistry(PackageName.parse(name))
    .andThen!((reg) => reg.getDownloadUri(name, ver.stripExtension, path.params.getToken()))
    .andThen!((uri){
        cgi.setResponseStatus("302 Found");
        cgi.setResponseLocation(uri);
        cgi.close();
      })
    .orElse!(() => cgi.setResponseStatus("404 Not Found"));
  return null;
}

@(Path("/status/readyforqueries"))
@(Path("/oauthtoken/$oauthtoken/status/readyforqueries"))
SenderObjectBase!void isReadyForQueries(MatchedPath path, Registry[] registries, Cgi cgi) {
  import std.algorithm : all;
  if (registries.all!(r => r.readyForQueries()))
    cgi.setResponseStatus("204 No Content");
  else
    cgi.setResponseStatus("503 Service Unavailable");
  return null;
}

@(Path("/token/$token/mirror/$registry"))
SenderObjectBase!void mirror(MatchedPath path, Registry[] registries, Cgi cgi) {
  import std.algorithm : all;

  auto r = path.params
    .getOpt("registry")
    .andThen!(name => findRegistry(registries, name))
    .andThen!((registry) {
        auto token = path.params.getToken;
        auto isAccessToken = token.match!((AccessToken t) => true, (_) => false);
        if (!isAccessToken || !registry.validateToken(path.params.getToken)) {
          cgi.setResponseStatus("403 Forbidden");
        } else if (!registry.readyForQueries) {
          cgi.setResponseStatus("503 Service Unavailable");
        } else {
          auto archive = registry.mirror();
          if (archive is null) {
            cgi.setResponseStatus("404 Not Found");
          } else {
            cgi.header("Content-Type: application/zip");
            cgi.header(`Content-Disposition: attachment; filename="mirror.zip"`);
            cgi.write(archive.build);
          }
        }
      })
    .orElse!((){
        cgi.setResponseStatus("404 Not Found");
      });
  return null;
}

@(Path("/token/$token/crawl/$registry/project/$id"))
SenderObjectBase!void crawlProject(MatchedPath path, Registry[] registries, Cgi cgi) {
  import std.algorithm : all;
  import privatedub.gitlab.registry;
  import concurrency.sender : just;
  import concurrency.stoptoken;
  import concurrency.operations : withStopToken, via;
  import concurrency.thread : ThreadSender;
  import std.conv : to;

  return path.params
    .getOpt("registry")
    .andThen!(name => findRegistry(registries, name))
    .andThen!((registry) {
        auto token = path.params.getToken;
        auto isAccessToken = token.match!((AccessToken t) => true, (_) => false);
        if (!isAccessToken || !registry.validateToken(path.params.getToken)) {
          cgi.setResponseStatus("403 Forbidden");
        } else if (!registry.readyForQueries) {
          cgi.setResponseStatus("503 Service Unavailable");
        } else if (auto gitlab = cast(GitlabRegistry)registry) {
          cgi.setResponseStatus("204 No Content");
          return just(gitlab, path.params["id"].to!int)
            .withStopToken((StopToken stopToken, GitlabRegistry reg, int projectId){
              reg.crawlProject(stopToken, projectId);
            })
            .via(ThreadSender())
            .toSenderObject;
        } else {
          cgi.setResponseStatus("400 Bad Request");
        }
        return null;
      })
    .orElse!((){
        cgi.setResponseStatus("404 Not Found");
        return null;
      });
}

@(Path("/oauthtoken/$oauthtoken/packages/$registry"))
@(Path("/token/$token/packages/$registry"))
SenderObjectBase!void packages(MatchedPath path, Registry[] registries, Cgi cgi) {
  import std.algorithm : all, map;
  import std.array : array;
  import dub.internal.vibecompat.data.json : Json;
  import privatedub.gitlab.registry : GitlabRegistry;

  auto r = path.params
    .getOpt("registry")
    .andThen!(name => findRegistry(registries, name))
    .andThen!((registry) {
        auto token = path.params.getToken;
        auto isAccessToken = token.match!((AccessToken t) => true, (_) => false);
        if (!isAccessToken || !registry.validateToken(path.params.getToken)) {
          cgi.setResponseStatus("403 Forbidden");
        } else if (auto gitlab = cast(GitlabRegistry)registry){
          if (!gitlab.readyForQueries) {
            cgi.setResponseStatus("503 Service Unavailable");
          }
          cgi.setResponseContentType("application/json");
          cgi.setResponseStatus("200 Ok");
          auto json = Json.emptyObject();
          json["packages"] = gitlab.allPackages().map!(p => p.toJson).array;
          cgi.write(json.toString());
        } else {
          cgi.setResponseStatus("404 Not Found");
        }
      })
    .orElse!((){
        cgi.setResponseStatus("404 Not Found");
      });
  return null;
}

struct SearchResult {
  import asdf : serializationKeys;
  string name;
  string description;
  @serializationKeys("version")
  string ver;
}

struct Path {
  string path;
  Path params(string[string] ps) {
    import std.string : replace;

    string clone = path;
    foreach (key, value; ps) {
      clone = clone.replace("$" ~ key, value);
    }
    return Path(clone);
  }
}

struct MatchedPath {
  Path originalPath;
  string path;
  immutable string[string] query;
  string[string] params;
}

Nullable!string getOpt(string[string] params, string key) {
  if (auto v = key in params)
    return typeof(return)(*v);
  return typeof(return).init;
}

Token getToken(string[string] params) {
  auto token = params.getOpt("token");
  if (!token.isNull)
    return Token(AccessToken(token.get));
  auto oauthtoken = params.getOpt("oauthtoken");
  if (!oauthtoken.isNull)
    return Token(OAuthToken(oauthtoken.get));
  return Token(NullToken());
}

struct PathRequest {
  string path;
  immutable string[string] query;
  Nullable!(MatchedPath) matches(Path path, bool strict = false) {
    import std.algorithm : countUntil, startsWith;

    string[string] result;
    string base = path.path;
    string input = this.path;

    for (; base.length;) {
      auto section = base.countUntil('$');
      if (section == -1)
        section = base.length;

      if (!input.startsWith(base[0 .. section]))
        return typeof(return).init;

      if (strict && section > input.length)
        return typeof(return).init;

      auto value = input[section .. $].countUntil('/');
      auto key = base[section .. $].countUntil('/');

      if (value == -1)
        value = input.length - section;
      if (key == -1)
        key = base.length - section;

      if (!strict && key == 0)
        return typeof(return)(MatchedPath(path, this.path, query, result));
      if (key != 0 && value != 0) {
        result[base[section + 1 .. section + key]] = input[section .. section + value];
      }
      else if (key != 0 || value != 0)
        return typeof(return).init;

      input = input[section + value .. $];
      base = base[section + key .. $];
    }

    if (strict && input.length > 0)
      return typeof(return).init;

    return typeof(return)(MatchedPath(path, this.path, query, result));
  }
}

@("path.match")
unittest {
  import unit_threaded;

  auto path = Path("/root/$section/stuff/$id");
  auto match = PathRequest("/root/abcd/stuff/1234").matches(path);
  match.isNull.shouldBeFalse;
  match.get.params.shouldEqual(["section": "abcd", "id": "1234"]);

  PathRequest("/root/abcd/stuff/1234/extra").matches(path).isNull.shouldBeFalse;
  PathRequest("/root/abcd/stuff/").matches(path).isNull.shouldBeTrue;
  PathRequest("/root/abcd/stuff").matches(path).isNull.shouldBeTrue;

  PathRequest("/").matches(Path("/")).isNull.shouldBeFalse;
  PathRequest("/stuff").matches(Path("/stuff")).isNull.shouldBeFalse;

  PathRequest("/a/b/c/d").matches(Path("/a"), false).isNull.shouldBeFalse;
  auto match2 = PathRequest("/a/b/c/d").matches(Path("/a/$q"), false);
  match2.isNull.shouldBeFalse;
  match2.get.params.shouldEqual(["q": "b"]);
}
