module privatedub.zip;

import std.zip;

ZipArchive zipFolder(string path) {
  import std.path : relativePath, absolutePath;
  import std.file : read, dirEntries, SpanMode;
  auto archive = new ZipArchive();
  auto absPath = absolutePath(path);
  foreach(entry; dirEntries(absPath, "*", SpanMode.depth, false)) {
    auto member = new ArchiveMember();
    member.name = entry.name.relativePath(absPath);
    member.expandedData(cast(ubyte[])read(entry.name));
    member.compressionMethod = CompressionMethod.deflate;
    archive.addMember(member);
  }
  return archive;
}

void unzipFolder(string path, ZipArchive archive) {
  import std.path : relativePath, absolutePath, buildNormalizedPath, isDirSeparator;
  import std.file : mkdirRecurse, write;
  auto absPath = absolutePath(path);
  mkdirRecurse(absPath);
  foreach(member; archive.directory) {
    auto location = buildNormalizedPath(absPath, member.name);
    if (location[$ - 1].isDirSeparator) {
      mkdirRecurse(location);
    } else {
      write(location, archive.expand(member));
    }
  }
}
