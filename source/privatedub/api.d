module privatedub.api;

import privatedub.server;
import privatedub.registry;
import privatedub.resolve;
import std.meta : AliasSeq;
import std.typecons : Nullable;
import sumtype;

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
                  route(match.get, regs, cgi);
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

alias Routes = AliasSeq!(getInfos, getDownloadUri, getPackages, isReadyForQueries);

struct NullToken {
}

struct AccessToken {
  string token;
}

struct JobToken {
  string token;
}

alias Token = SumType!(NullToken, AccessToken, JobToken);

@(Path("/token/$token/api/packages/search"))
@(Path("/jobtoken/$jobtoken/api/packages/search"))
@(Path("/api/packages/search"))
void getPackages(MatchedPath path, Registry[] registries, Cgi cgi) {
  import std.algorithm : map;
  import asdf;
  import std.string : stripLeft;

  try {
    string q = path.query["q"];
    auto reg = registries.findRegistry(PackageName.parse(q));
    cgi.setResponseContentType("application/json");
    cgi.setResponseStatus("200 Ok");
    if (reg.isNull) {
      cgi.write(`[]`);
    } else {
      auto results = reg.search(q);
      auto sr = results.map!(result => SearchResult(result.name, null, result.versions.highestVersion().stripLeft("v")));
      cgi.write(sr.serializeToJson());
    }
  } catch (Exception e) {
    import std.stdio;
    writeln(e);
    cgi.setResponseStatus("404 Not Found");
  }
  cgi.close();
}

@(Path("/token/$token/api/packages/infos"))
@(Path("/jobtoken/$jobtoken/api/packages/search"))
@(Path("/api/packages/infos"))
void getInfos(MatchedPath path, Registry[] registries, Cgi cgi) {
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
}

@(Path("/token/$token/packages/$name/$version"))
@(Path("/jobtoken/$jobtoken/api/packages/search"))
@(Path("/packages/$name/$version"))
void getDownloadUri(MatchedPath path, Registry[] registries, Cgi cgi) {
  import std.path : stripExtension;

  auto name = path.params["name"];
  auto ver = path.params["version"];
  auto reg = registries.findRegistry(PackageName.parse(name));
  auto uri = reg.getDownloadUri(name, ver.stripExtension, path.params.getToken());
  if (uri.isNull) {
    cgi.setResponseStatus("404 Not Found");
  } else {
    cgi.setResponseStatus("302 Found");
    cgi.setResponseLocation(uri.get);
    cgi.close();
  }
}

@(Path("/status/readyforqueries"))
@(Path("/jobtoken/$jobtoken/api/packages/search"))
void isReadyForQueries(MatchedPath path, Registry[] registries, Cgi cgi) {
  import std.algorithm : all;
  if (registries.all!(r => r.readyForQueries()))
    cgi.setResponseStatus("204 No Content");
  else
    cgi.setResponseStatus("503 Service Unavailable");
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
  auto jobtoken = params.getOpt("jobtoken");
  if (!jobtoken.isNull)
    return Token(JobToken(jobtoken.get));
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
  match.params.shouldEqual(["section": "abcd", "id": "1234"]);

  PathRequest("/root/abcd/stuff/1234/extra").matches(path).isNull.shouldBeFalse;
  PathRequest("/root/abcd/stuff/").matches(path).isNull.shouldBeTrue;
  PathRequest("/root/abcd/stuff").matches(path).isNull.shouldBeTrue;

  PathRequest("/").matches(Path("/")).isNull.shouldBeFalse;
  PathRequest("/stuff").matches(Path("/stuff")).isNull.shouldBeFalse;

  PathRequest("/a/b/c/d").matches(Path("/a"), false).isNull.shouldBeFalse;
  auto match2 = PathRequest("/a/b/c/d").matches(Path("/a/$q"), false);
  match2.isNull.shouldBeFalse;
  match2.params.shouldEqual(["q": "b"]);
}
