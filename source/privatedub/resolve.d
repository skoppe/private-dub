module privatedub.resolve;

import privatedub.registry;
import dub.dependency;
import dub.recipe.packagerecipe : PackageRecipe, BuildSettingsTemplate, ConfigurationInfo;
import std.typecons : Nullable;
// import dub.recipe.json;
import dub.internal.vibecompat.data.json : Json;
import privatedub.semver : SemVer, parseSemVer;

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
  import std.exception : enforce;

  auto json = p.recipe.toPackageDependencyInfo();
  json["commitID"] = p.commitId;

  enforce(p.ref_.length > 0, "p.ref_ is length 0");
  if (p.ref_[0] == 'v' && !parseVersion(p.ref_).isNull)
    json["version"] = p.ref_[1 .. $]; // strip the leading 'v'
  else
    json["version"] = "~" ~ p.ref_; // else it must be a branch

  return json;
}

unittest {
  import unit_threaded;
  VersionedPackage("v1.0.0").toPackageDependencyInfo.toString.shouldEqual(`{"subPackages":[],"dependencies":{},"configurations":[],"commitID":"","version":"1.0.0","name":""}`);
  VersionedPackage("1.0.0").toPackageDependencyInfo.toString.shouldEqual(`{"subPackages":[],"dependencies":{},"configurations":[],"commitID":"","version":"~1.0.0","name":""}`);
  VersionedPackage("vibeTask").toPackageDependencyInfo.toString.shouldEqual(`{"subPackages":[],"dependencies":{},"configurations":[],"commitID":"","version":"~vibeTask","name":""}`);
}

Json toPackageDependencyInfo(PackageRecipe p) {
  import std.algorithm : map;
  import std.array : array;

  auto json = p.toSubPackageDependencyInfo;
  json["subPackages"] = p.subPackages.map!(s => s.recipe.toSubPackageDependencyInfo).array();
  return json;
}

Json toSubPackageDependencyInfo(PackageRecipe p) {
  import std.algorithm : map;
  import std.array : array;

  auto json = Json.emptyObject();
  json["name"] = p.name;
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
  string input;
  SemVer semver;
  int opCmp(ref const Version o) {
    return semver.opCmp(o.semver);
  }
  string toString() {
    return input;
  }
}

Nullable!Version parseVersion(string v) {
  import privatedub.semver : parseSemVer;
  import std.regex : ctRegex, matchFirst;
  import std.algorithm : map;
  import std.conv : to;
  import std.range : dropOne;

  try {
    return typeof(return)(Version(v, parseSemVer(v)));
  } catch (Exception e) {
    return typeof(return).init;
  }
}

auto highestVersion(VersionedPackage[] ps) {
  import std.algorithm : maxElement, map, filter;
  import std.typecons : tuple;
  import privatedub.util : andThen;

  return ps.map!(p => parseVersion(p.ref_).andThen!(v => tuple!("orderable","ref_")(v,p.ref_)))
    .filter!(t => !t.isNull)
    .maxElement!(t => t.orderable)
    .ref_;
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

unittest {
  import unit_threaded;

  auto set1 = [VersionedPackage("0.0.3"), VersionedPackage("0.0.1"), VersionedPackage("0.0.2")];
  auto set2 = [VersionedPackage("0.0.3-beta.1"), VersionedPackage("0.0.3-beta.2"), VersionedPackage("0.0.3-beta.4"), VersionedPackage("0.0.2")];

  highestReleaseVersion(set1).shouldEqual("0.0.3");
  highestVersion(set1).shouldEqual("0.0.3");

  highestReleaseVersion(set2).shouldEqual("0.0.2");
  highestVersion(set2).shouldEqual("0.0.3-beta.4");
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
