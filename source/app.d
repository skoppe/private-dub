import privatedub.registry;
import concurrency.stoptoken;

void main() {
	import privatedub.api;
	import concurrency.nursery;
	import concurrency;
	import std.algorithm : each;
	import std.stdio : writeln;

	auto registries = getRegistries();
	registries.each!(r => r.validate());
	writeln("Running with registries: ", registries);
	shared nursery = new shared Nursery();

	nursery.run(api(registries));
	nursery.run(periodicSync(nursery.getStopToken, registries));
	nursery.run(periodicGC());

	nursery.syncWait();
}

auto periodicGC() @safe {
	import concurrency.stream;
	import core.time : seconds;
	import core.memory : GC;

	return intervalStream(30.seconds).collect(() shared @trusted {
			GC.collect();
			GC.minimize();
		});
}

auto periodicSync(StopToken stopToken, Registry[] registries) {
	import concurrency.utils;
	import concurrency.thread;
	import concurrency.operations;
	import concurrency.stream : intervalStream;
	import core.time : dur;

	return intervalStream(dur!"seconds"(60), true)
		.collect(closure((StopToken stopToken, Registry[] registries) @safe {
					import std.algorithm : each;
					import privatedub.util : CircuitBreaker, SuccessiveFailures;
					CircuitBreaker!(SuccessiveFailures!3) breaker;
					breaker.run({registries.each!(r => r.sync(stopToken));});
				}, stopToken, registries))
		.via(ThreadSender());
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
	import std.file : thisExePath;
	import std.path : buildPath, dirName;

	auto ini = Ini.Parse(buildPath(dirName(thisExePath()), "config.ini"));
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
