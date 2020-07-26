module privatedub.registry;

import dub.recipe.packagerecipe;
import dub.recipe.json;
import dub.internal.vibecompat.data.json;
import std.typecons : Nullable;

struct VersionedPackage {
  string ref_;
  string commitId;
  PackageRecipe recipe;
  Json toJson() {
    Json json = Json.emptyObject();
    json["version"] = ref_;
    json["commitId"] = commitId;
    json["recipe"] = recipe.toJson();
    return json;
  }

  static VersionedPackage fromJson(Json json) {
    auto p = VersionedPackage();
    p.ref_ = json["version"].get!string;
    p.commitId = json["commitId"].get!string;
    parseJson(p.recipe, json["recipe"], "");
    return p;
  }
}

struct PackageMeta {
  Registry registry;
  string name;
  VersionedPackage[] versions;
}

interface Registry {
  string getPrefix();
  PackageMeta[] search(string name);
  PackageMeta getPackageMeta(string name);
  bool hasPackage(string name);
  string getDownloadUri(string name, string ver_, Nullable!string token);
  int priority();
  void sync() shared;
  void sync();
}

@("Ensure we can use slash in name and dependency")
unittest {
  import dub.recipe.io;
  import unit_threaded;

  parsePackageRecipe(`name "git.kaleidic.io/web"`, "dub.sdl").shouldNotThrow;
  parsePackageRecipe(`
name "git.kaleidic.io/web"
dependency "git.kaleidic.io/stuff" version="~>1.2.3"`, "dub.sdl")
    .shouldNotThrow;
  parsePackageRecipe(`{"name":"git.kaleidic.io/web"}`, "dub.json").shouldNotThrow;
  parsePackageRecipe(`
{"name":"git.kaleidic.io/web",
"dependencies": {"git.kaleidic.io/stuff": "~>1.2.3"}
}`, "dub.json").shouldNotThrow;
}
