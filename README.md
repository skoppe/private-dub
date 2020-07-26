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

Just point dub to your registry and be happy ever after. `dub build --registry=https://private-dub.example.com`.

NOTE: Because this side-steps the official registry, package stats on code.dlang.org obviously won't be incremented.

## Settings registry via settings.json

Alternatively you can create a `settings.json` with the following:

{
	"registryUrls": ["https://private-dub.example.com"],
}

The file settings.json can be located in different locations. Last item in list has highest priority.

#### Windows

- %ProgramData%\dub\settings.json
- <dub executable folder>\..\etc\dub\settings.json
- %APPDATA%\dub\settings.json
- %ROOT_PACKAGE_DIR%\dub.settings.json

#### Posix

- /var/lib/dub/settings.json
- <dub executable folder>/../etc/dub/settings.json
- ~/.dub/settings.json
- $ROOT_PACKAGE_DIR/dub.settings.json


## Credendials

If you have repositories on your SCM that have limited access, you need pass credentials.

Currently the access token is passed as part of the registry's uri. E.g. `dub --registry=https://private-dub.example.com/token/<access-token>` or in your `settings.json`.

The advantage is that it reuses your SCM permissions you already have. The downside is that the application currently only supports one private SCM with credentials, and that your access_token is either stored in plain-text in a file or entered via the command line.

The application itself performs no checks on the token, it simply passes it along in the redirect to your SCM when dub requests a download uri. (This means that the api itself is open, and anyone can make api requests and retrieve metadata about your packages. (I would accept PR that check the token on each api request (with optional cache))).

NOTE: I haven't found the best way to pass credentials. I really prefer to keep this a stateless application. I am considering adding OAuth2 support, but it is yak-shaving at this point.

## Gitlab

Initially it crawls all projects and looks for dub.json/dub.sdl files. Once a local registry is build up it keeps itself in sync by calling the gitlab event api every minute.

## Dlang

Initially the dlang registry is fetched by cloning the https://github.com/skoppe/dub-packages-index repository (which itself is updated every 15 minutes and also drives the dub.bytecraft.nl registry mirror). Afterwards a git pull is executed every minute.

# Install

There is a dockerfile somewhere, run it. The whole app keeps a cache (in memory and on disk) for speed but is otherwise stateless. No database, no nothing. Just run it.

At first startup it might take a few moments to crawl you SCM system. Subsequent restarts only need to load the cache from disk.

# Config

See <a href="config-example.ini">config-example.ini</a> for configuration.
