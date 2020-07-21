module privatedub.api;

import privatedub.server;
import privatedub.registry;
import privatedub.resolve;
import privatedub.nursery;
import std.meta : AliasSeq;
import std.typecons : Nullable;

void runApi(Nursery nursery, Registry[] registries) {
  auto regs = registries.dup();
  auto task = nursery.thread().then(() {
    import std.stdio;

    writeln("Starting server");
    void handleConnection(Cgi cgi) @trusted {
      PathRequest pathRequest = PathRequest(cgi.pathInfo, cgi.get);
      static foreach (route; Routes) {
        {
          alias path = getPathUDA!route;
          auto match = pathRequest.matches(path);
          if (!match.isNull) {
            route(match.get, nursery, regs, cgi);
            return;
          }
        }
      }
    }

    runCgi!(handleConnection)(nursery, 8888, "0.0.0.0");
  });
  nursery.run(task);
}

template getPathUDA(alias T) {
  import std.traits : getUDAs;

  enum getPathUDA = getUDAs!(T, Path)[0];
}

alias Routes = AliasSeq!(getInfos, getDownloadUri);

@(Path("/api/packages/infos"))
void getInfos(MatchedPath path, Nursery nursery, Registry[] registries, Cgi cgi) {
  import dub.internal.vibecompat.data.json : Json, parseJsonString;

  Json packages = parseJsonString(path.query["packages"]);
  Json output = resolve(registries, packages[0].get!string).toPackageDependencyInfo;
  cgi.setResponseContentType("application/json");
  cgi.setResponseStatus("200 Ok");
  cgi.write(output.toString());
  cgi.close();
}

@(Path("/packages/$name/$version"))
void getDownloadUri(MatchedPath path, Nursery nursery, Registry[] registries, Cgi cgi) {
  import std.path : stripExtension;

  auto name = path.params["name"];
  auto ver = path.params["version"];
  auto reg = registries.findRegistry(PackageName.parse(name));
  cgi.setResponseStatus("302 Found");
  cgi.setResponseLocation(reg.getDownloadUri(name, ver.stripExtension));
  cgi.close();
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
