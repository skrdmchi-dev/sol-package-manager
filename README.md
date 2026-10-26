sol is a simple package manager for custom Linux builds. It tracks upstream versions, downloads source, builds from scratch, and installs the result.

It was written for an LFS-style system but can work anywhere you give it a package database and build scripts.

## How it works

You define packages in a simple TSV file:

```
name    version    tier    probe    arg            url-template    aux-templates    scripts
curl    8.12.0    leaf    http:    https://curl.se/download/    -             build.sh
```

sol checks upstream (GitHub tags, GitLab tags, HTTP headers), downloads the tarball, runs the build script, and installs.

## Installing

Clone the repo and symlink sol somewhere in your PATH:

```bash
git clone https://github.com/skrdmchi-dev/sol-package-manager.git
cd sol-package-manager
sudo cp sol /usr/local/bin/
sudo cp -r lib /usr/local/lib/sol
```

Or just run it in place.

## Setting up a package database

Create ~/.sol/packages.db with your packages. The format is tab-separated:

- name: package name
- version: current installed version (or 0 if new)
- tier: leaf, lib, critical, or manual
- probe: how to check for updates (github:owner/repo, gh-tags:owner/repo, gl-tags:host/path, http:url)
- arg: any extra argument the prober needs
- url-template: download URL with @V@ as version placeholder
- aux-templates: comma-separated extra files to download (patches, etc.)
- scripts: comma-separated build scripts to run

Example:

```
curl    8.12.0    leaf    http:    https://curl.se/download/curl-@V@.tar.xz    -     build.sh
vim    9.1.0    lib    github:vim/vim    -    https://github.com/vim/vim/archive/v@V@.tar.gz    -     build.sh
```

The lib/probe.sh file has the built-in probers. Add your own there if you need something custom.

## Usage

Check what would update:

```bash
sol upgrade
```

Do the update:

```bash
sudo sol update
```

Show all packages in the database:

```bash
sol --list
```

Only update specific packages:

```bash
sudo sol update --only curl,vim
```

Skip a package:

```bash
sudo sol update --skip vim
```

Force rebuild even if the version is the same:

```bash
sudo sol update --force vim
```

Hold a package (it won't be updated):

```bash
sol hold vim
```

Unhold it:

```bash
sol unhold vim
```

Full update (includes critical tier):

```bash
sudo sol update --full
```

## Build scripts

Put your build scripts in ~/.sol/recipes/package-name.sh. They should define:

- `installed_version` - prints current version (check package manager or file)
- `latest_version` - prints latest available version
- `build $version` - downloads, configures, compiles, installs

sol calls these automatically for any package with a matching recipe file.

## Tiers

- leaf: safe apps/tools, auto-updates by default
- lib: libraries, auto-updates by default
- critical: system-critical stuff, only updates with --full
- manual: ignored by update, for manual handling only

## Directories

Everything lives in ~/.sol by default (set SOL_HOME if you want it somewhere else):

- packages.db: your package database
- recipes/: build script overrides
- lib/: probe and guard functions
- build/: build work directory
- logs/: per-package build logs
- state/: runtime state

## Logs

sol logs to ~/.sol/sol.log and ~/.sol/logs/package-name.log for each build.

## Requirements

- bash
- curl
- tar
- python3 (for zip extraction)
- gcc/make/etc for actual builds

## Why this exists

Most package managers are distro-specific or heavyweight. sol is just a small shell script that checks upstream, downloads, and runs your build scripts. If you build software from source, you can use sol to keep it updated without fighting the distro package manager or maintaining it by hand.
