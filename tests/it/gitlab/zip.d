module it.gitlab.zip;

import privatedub.zip;
import unit_threaded;

unittest {
  import std.file : rmdirRecurse, dirEntries, SpanMode, exists;
  import std.zip : ZipArchive;
  import std.string : replace;

  rmdirRecurse("./tests/it/files/unzip").ignoreException();

  auto archive = zipFolder("./tests/it/files/zip");
  unzipFolder("./tests/it/files/unzip", new ZipArchive(archive.build));

  foreach(entry; dirEntries("./tests/it/files/zip", "*", SpanMode.depth)) {
    entry.name.replace("zip", "unzip").exists.should == true;
  }
}

void ignoreException(B)(lazy B block) {
  try { block(); } catch (Exception e) {}
}
