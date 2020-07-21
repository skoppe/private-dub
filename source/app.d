import privatedub.api;
import privatedub.registry;
import privatedub.nursery;

void main() {
	import std.algorithm : each;

	auto registries = getRegistries();
	registries.each!(r => r.sync());

	Nursery nursery = new Nursery();
	runApi(nursery, registries);

	nursery.sync_wait();
}

Registry[] getRegistries() {
	import privatedub.gitlab.config;
	import privatedub.gitlab.registry;
	import privatedub.dlang.registry;
	import sumtype;
	import std.algorithm : map, filter, joiner, sort;
	import std.array : array;

	alias Config = SumType!(GitlabConfig, DlangRegistryConfig);

	return loadConfig!Config().map!(config => config.match!((GitlabConfig config) => cast(
			Registry) new GitlabRegistry(config),
			(DlangRegistryConfig config) => cast(Registry) new DlangRegistry(config))).array()
		.sort!((a, b) => a.priority < b.priority).release();
}

auto loadConfig(Config)() {
	import dini;
	import std.string : split;
	import std.array : appender;

	auto ini = Ini.Parse("config.ini");
	auto app = appender!(Config[]);

	foreach (section; ini.sections) {
		auto parts = section.name.split("@");
		try {
			static foreach (C; Config.Types) {
				if (C.type == parts[0])
					app.put(Config(C.loadConfig(section)));
			}
		}
		catch (Exception e) {
			throw new Exception("Error in config, section [" ~ section.name ~ "]: " ~ e.msg);
    }
  }
  return app.data;
}
