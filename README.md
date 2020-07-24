# Private Dub Registry

Want to keep all your precious project for yourself but still use dub?

Tired of workarounds with submodules, git trees?

# How it works

It crawls your source code management system. Just put a `dub.json`/`dub.sdl` in a repo and tag a commit.

Projects referenced in the `dub.json`/`dub.sdl` can have an optional hostname prefix to avoid clashes with the official registry.

NOTE: Even though the documentation on [code.dlang.org](https://code.dlang.org) states that only alphanumerics and '-' are allowed, since there is no enforcement and because we wanted namespaces, we decided to take this approach. Hopefully namespaces will become supported officially.

```sdl
name "gitlab.example.com/my-project"
dependency "gitlab.example.com/another-project" version="~>1.2.3"
dependency "vibe-d" version="~>3.4.5"
```

Just point dub to your registry and be happy ever after. `dub build --registry=https://private-dub.example.com`. Or look at the settings page on the code.dlang.org documentation section how to set the registry system-wide.

NOTE: Because this side-steps the official registry, package stats on code.dlang.org obviously won't be incremented.

## Gitlab

Initially it crawls all projects and looks for dub.json/dub.sdl files. Once a local registry is build up it keeps itself in sync by calling the gitlab event api every minute.

## Dlang

Initially the dlang registry is fetched by cloning the https://github.com/skoppe/dub-packages-index repository (which itself is updated every 15 minutes and also drives the dub.bytecraft.nl registry mirror). Afterwards a git pull is executed every minute.

# Install

There is a dockerfile somewhere, run it. The whole app keeps a cache (in memory and on disk) for speed but is otherwise stateless. No database, no nothing. Just run it.

At first startup it might take a few moments to crawl you SCM system. Subsequent restarts only need to load the cache from disk.

# Config

See <a href="config-example.ini">config-example.ini</a> for configuration.
