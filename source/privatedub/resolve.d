module privatedub.resolve;

import privatedub.registry;
import dub.dependency;
import dub.recipe.packagerecipe : PackageRecipe, BuildSettingsTemplate, ConfigurationInfo;
import std.typecons : Nullable;
// import dub.recipe.json;
import dub.internal.vibecompat.data.json : Json;

PackageMeta[string] resolve(Registry[] registries, string name) {
  import std.array : Appender, array;
  import std.algorithm : joiner, sort, uniq, each, filter, find, map;
  import std.range : chain;
  import privatedub.util : andThen;

  PackageMeta[string] packages;

  Appender!(PackageName[]) queue;
  queue.put(PackageName.parse(name));

  while (queue.data.length) {
    auto current = queue.data[$ - 1];
    queue.shrinkTo(queue.data.length - 1);
    if (current.base in packages)
      continue;

    registries.findRegistry(current).andThen!((reg){
      auto meta = reg.getPackageMeta(current.base);
      packages[current.base] = meta;

      meta.versions.each!((v) {
        auto deps = chain(v.recipe.buildSettings.getDependencies(),
        v.recipe.buildTypes.byValue.map!(t => getDependencies(t)).joiner,
        v.recipe.configurations.map!(c => c.buildSettings.getDependencies).joiner // v.recipe.subPackages.map!(s => chain(
        //                                      s.recipe.buildSettings.getDependencies(),
        //                                      s.recipe.buildTypes.byValue.map!(getDependencies).joiner,
        //                                      s.recipe.configurations.map!(c => c.buildSettings.getDependencies).joiner)).joiner
        ).array().sort!((a, b) => a.base < b.base)
        .uniq!((a, b) => a.base == b.base);
        deps.each!((p) {
          if (p.base !in packages) {
            queue.put(p);
          }
        });
      });
      });
  }
  return packages;
}

Json toPackageDependencyInfo(PackageMeta[string] ps) {
  auto json = Json.emptyObject();
  foreach (key, value; ps) {
    json[key] = value.toPackageDependencyInfo();
  }
  return json;
}

Json toPackageDependencyInfo(PackageMeta p) {
  import std.algorithm : map;
  import std.array : array;

  auto json = Json.emptyObject();
  json["versions"] = p.versions.map!(toPackageDependencyInfo).array();
  return json;
}

Json toPackageDependencyInfo(VersionedPackage p) {
  import std.string : stripLeft;

  auto json = p.recipe.toPackageDependencyInfo();
  json["commitID"] = p.commitId;

  if (p.ref_.parseVersion().isNull)
    json["version"] = "~" ~ p.ref_;
  else
    json["version"] = p.ref_[1 .. $];

  return json;
}

Json toPackageDependencyInfo(PackageRecipe p) {
  import std.algorithm : map;
  import std.array : array;

  auto json = Json.emptyObject();
  json["name"] = p.name;
  json["subPackages"] = p.subPackages.map!(s => s.recipe.toPackageDependencyInfo).array();
  // if (p.version_.length > 0)
  //   json["version"] = p.version_;
  json["dependencies"] = p.buildSettings.dependencies.toPackageDependencyInfo();
  json["configurations"] = p.configurations.map!(toPackageDependencyInfo).array();
  return json;
}

Json toPackageDependencyInfo(Dependency[string] deps) {
  auto json = Json.emptyObject();
  foreach (key, value; deps) {
    json[key] = value.versionSpec();
  }
  return json;
}

Json toPackageDependencyInfo(ConfigurationInfo c) {
  auto json = Json.emptyObject();
  json["name"] = c.name;
  json["dependencies"] = c.buildSettings.dependencies.toPackageDependencyInfo();
  return json;
}

struct PackageName {
  string base;
  string sub;
  static PackageName parse(string name) {
    import std.string : split;

    auto parts = name.split(":");
    if (parts.length == 1)
      return PackageName(parts[0]);
    return PackageName(parts[0], parts[1]);
  }
}

Nullable!Registry findRegistry(Registry[] registries, PackageName p) {
  import std.algorithm : filter, startsWith, find;
  import std.range : empty, front;

  auto byPrefix = registries.filter!(r => r.getPrefix().length > 0)
    .find!(reg => p.base.startsWith(reg.getPrefix()));
  if (!byPrefix.empty)
    return typeof(return)(byPrefix.front);

  auto byName = registries.find!(reg => reg.hasPackage(p.base));
  if (!byName.empty)
    return typeof(return)(byName.front);

  return typeof(return).init;
}

auto getDependencies(ref BuildSettingsTemplate bst) {
  import std.algorithm : map;

  return bst.dependencies.byKey.map!(PackageName.parse);
}

bool isReleaseVersion(string ver) {
  import std.algorithm : until, canFind;

  return !ver.until('+').canFind('-');
}

struct Version {
  int x, y, z;
  int opCmp(ref const Version o) {
    int dx = x - o.x, dy = y - o.y, dz = z - o.z;
    if (dx != 0)
      return dx;
    if (dy != 0)
      return dy;
    return dz;
  }
}

Nullable!Version parseVersion(string v) {
  import std.regex : ctRegex, matchFirst;
  import std.algorithm : map;
  import std.conv : to;
  import std.range : dropOne;

  enum reg = ctRegex!(`^v?([0-9]+)\.([0-9]+)\.([0-9]+)`);
  auto matches = v.matchFirst(reg);
  if (!matches)
    return typeof(return).init;
  return typeof(return)(Version(matches.dropOne.map!(to!int)
      .toTuple!3
      .expand));
}

auto highestReleaseVersion(VersionedPackage[] ps) {
  import std.algorithm : maxElement, map, filter;
  import std.typecons : tuple;
  import privatedub.util : andThen;

  return ps.filter!(p => p.ref_.isReleaseVersion)
    .map!(p => parseVersion(p.ref_).andThen!(v => tuple!("orderable","ref_")(v,p.ref_)))
    .filter!(t => !t.isNull)
    .maxElement!(t => t.orderable)
    .ref_;
}

template toTuple(size_t n) {
  auto toTuple(Range)(Range range) {
    import std.typecons : tuple;
    import std.range : iota;
    import std.algorithm : map, joiner;
    import std.conv : text;
    auto next(ref Range range) {
      auto r = range.front();
      range.popFront();
      return r;
    }
    enum code = iota(0, n-1).map!(i => "next(range)").joiner(",").text();
    mixin("return tuple("~code~", range.front);");
  }
}
