# Private Dub Registry

Want to keep all your precious projects for yourself but still use dub?

Tired of workarounds with submodules or git trees?

# Run a registry yourself

Just point it to your VCS, put a `dub.json`/`dub.sdl` in a repository and tag a commit.

No need to publish anything. Projects and versions are discovered automatically.

Tell dub about your registry and be happy ever after. `dub build --registry=https://gitlab.example.com`.

## Settings registry via settings.json

Better yet, put the following in `~/.dub/settings.json` or `/%APPDATA%\dub\settings.json`, and just `dub` like a boss:

```json
{
	"registryUrls": ["https://gitlab.example.com"]
}
```

> NOTE: Look in the official dub documentation for other places where this file can be located.

## code.dlang.org

Yes, it will also resolve packages from [code.dlang.org](https://code.dlang.org).

To avoid name clashes you should prefix your packages with your hostname, like so:

```sdl
name "gitlab.example.com.my-project"
dependency "gitlab.example.com.another-project" version="~>1.2.3"
dependency "vibe-d" version="~>3.4.5"
```

> NOTE: Even though the documentation on [code.dlang.org](https://code.dlang.org) states that only alphanumerics and '-' are allowed, since there is no enforcement, we decided to take this approach.

# Install

See <a href="config-example.ini">config-example.ini</a> for configuration.

~There is a dockerfile somewhere, run it. The whole app keeps a cache (in memory and on disk) for speed but is otherwise stateless. No database, no nothing. Just run it.~

~At first startup it might take a few moments to crawl you VCS system. Subsequent restarts only need to load the cache from disk.~

Instructions are coming...

> NOTE: The application provides no SSL. It is recommended to run it behind a reverse proxy that provides SSL termination (e.g. nginx).

## Credendials

If you have repositories on your VCS that have limited access, you need pass credentials.

Currently the access token is passed as part of the registry's uri. E.g. `dub --registry=https://gitlab.example.com/token/<access-token>` or in your `settings.json`.

> NOTE: The application itself performs no checks on the token, it simply passes it along in the redirect to your VCS archive when dub requests a download uri. (This means that the api itself is open, and anyone can make api requests and retrieve metadata about your packages. (I would accept PR that check the token on each api request (with optional cache))).

> NOTE: I haven't found the best way to pass credentials. I really prefer to keep this a stateless application. I am considering adding OAuth2 support, which will add the benefit of token expiry (whereas access tokens are mostly set to never expire).

## VCS's

### Gitlab

Initially it crawls all projects and looks for `dub.json`/`dub.sdl` files. Once a local registry is build, it keeps itself in sync by calling the gitlab event api every minute.

### Dlang

Initially the dlang registry is fetched by cloning the https://github.com/skoppe/dub-packages-index repository (which itself is updated every 15 minutes and also drives the `dub.bytecraft.nl` registry mirror). Afterwards a git pull is executed every minute.
