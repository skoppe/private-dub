module privatedub.gitlab.config;

import requests;

struct GitlabConfig {
  import dini : IniSection;

  enum type = "gitlab";
  string token;
  string hostname;
  string storage = "./storage";
  int priority = 1;
  string prefix;
  string mirror;
  Interceptor interceptor = null;

  string baseUrl() const {
    return "https://" ~ hostname ~ "/api/v4";
  }

  static GitlabConfig loadConfig(IniSection section) {
    import std.string : split;
    import std.conv : to;

    auto parts = section.name.split("@");
    return GitlabConfig(section.getKey("token"),
                        parts[1],
                        section.getKey("storage", GitlabConfig.init.storage),
                        section.getKey("priority", GitlabConfig.init.priority.to!string).to!int,
                        section.getKey("prefix", parts[1]),
                        section.getKey("mirror", ""));
  }
}
