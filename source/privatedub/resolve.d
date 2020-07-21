module privatedub.resolve;

import privatedub.registry;
import dub.dependency;
import dub.recipe.packagerecipe : PackageRecipe, BuildSettingsTemplate, ConfigurationInfo;

// import dub.recipe.json;
import dub.internal.vibecompat.data.json : Json;

PackageMeta[string] resolve(Registry[] registries, string name) {
  import std.array : Appender, array;
  import std.algorithm : joiner, sort, uniq, each, filter, find, map;
  import std.range : chain;

  PackageMeta[string] packages;

  Appender!(PackageName[]) queue;
  queue.put(PackageName.parse(name));

  while (queue.data.length) {
    auto current = queue.data[$ - 1];
    queue.shrinkTo(queue.data.length - 1);
    if (current.base in packages)
      continue;

    auto reg = registries.findRegistry(current);
    auto meta = reg.getPackageMeta(current.base);
    packages[current.base] = meta;

    meta.versions.each!((v) {
      auto deps = chain(v.recipe.buildSettings.getDependencies(),
        v.recipe.buildTypes.byValue.map!(t => getDependencies(t)).joiner,
        v.recipe.configurations.map!(c => c.buildSettings.getDependencies).joiner// v.recipe.subPackages.map!(s => chain(
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
  auto json = p.recipe.toPackageDependencyInfo();
  json["commitID"] = p.commitId;
  return json;
}

Json toPackageDependencyInfo(PackageRecipe p) {
  import std.algorithm : map;
  import std.array : array;

  auto json = Json.emptyObject();
  json["name"] = p.name;
  json["subPackages"] = p.subPackages.map!(s => s.recipe.toPackageDependencyInfo).array();
  if (p.version_.length > 0)
    json["version"] = p.version_;
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

Registry findRegistry(Registry[] registries, PackageName p) {
  import std.algorithm : filter, startsWith, find;
  import std.range : empty, front;

  auto byPrefix = registries.filter!(r => r.getPrefix().length > 0)
    .find!(reg => p.base.startsWith(reg.getPrefix()));
  if (!byPrefix.empty)
    return byPrefix.front;

  auto byName = registries.find!(reg => reg.hasPackage(p.base));
  if (!byName.empty)
    return byName.front;

  throw new Exception("Cannot find package " ~ p.base);
}

auto getDependencies(ref BuildSettingsTemplate bst) {
  import std.algorithm : map;

  return bst.dependencies.byKey.map!(PackageName.parse);
}
