# Appcircle npm Mirror

This step points the JavaScript tooling of a React Native build at your artifact proxy (for example a Sonatype Nexus or JFrog Artifactory), so the build works on runners without internet access:

- npm, Yarn 1, Yarn 2 and later, pnpm, and Corepack (which downloads Yarn 2+ and pnpm) use your npm repository;
- the Install Node step downloads Node.js from your Node.js mirror;
- React Native 0.81 and later download Hermes and their prebuilt iOS frameworks from your Maven repository.

Place it **after Git Clone** and before Install Node and the npm/Yarn Commands step. It sets environment variables for the later steps of the build and checks the project's lockfiles (see [What You Configure in the Project](#what-you-configure-in-the-project)). If all three URLs are empty, the step does nothing.

For the Android part of a React Native build, add the Gradle Mirror step too. For the iOS part, add the CocoaPods Mirror and Git Mirror steps. When a dependency comes from git (see [Limits](#limits)), add the Git Mirror step on Android too: npm clones git dependencies with their submodules.

## Optional Input Variables

- `$AC_MIRROR_NPM`: URL of an npm repository on your artifact proxy, a proxy of `https://registry.npmjs.org`.
- Lockfile (`update`, `fail` or `warn`, default `fail`): what the step does when a lockfile of the project still downloads from the public registry. Set it on the step, not in the group: it depends on the project.
- `$AC_MIRROR_NODE`: URL of a raw (generic) repository on your artifact proxy that proxies `https://nodejs.org/dist`.
- `$AC_MIRROR_REACT_NATIVE_MAVEN` (default `$AC_MIRROR_GRADLE`): URL of a Maven repository on your artifact proxy that serves Maven Central, usually the same group as the Gradle Mirror.

Set the values once in an Environment Variable Group and add the group to the configurations that use the step.

## What the Step Does

Passes these settings to the later steps of the same build only:

| Variable | Read by |
| --- | --- |
| `npm_config_registry` | npm, pnpm, Yarn 1 (for packages that are not in `yarn.lock`) |
| `YARN_REGISTRY` | Yarn 1 |
| `YARN_NPM_REGISTRY_SERVER` | Yarn 2 and later |
| `COREPACK_NPM_REGISTRY` | Corepack |
| `N_NODE_MIRROR` | `n`, which the Install Node step runs |
| `ENTERPRISE_REPOSITORY` | React Native 0.81 and later (Hermes, `ReactNativeDependencies`, `React-Core-prebuilt`) |

Nothing is written to `~/.npmrc` or to the project's configuration.

Install Node runs `n` with `sudo` on macOS, and `sudo` drops environment variables. When `AC_MIRROR_NODE` is set, the step therefore adds one rule to `/etc/sudoers.d/appcircle-npm-mirror`:

```text
Defaults env_keep += "N_NODE_MIRROR"
```

The file is checked with `visudo` before it is installed, is the same on every run, and holds no URL. Builds without `N_NODE_MIRROR` are not affected.

## What You Configure in the Project

The step checks the lockfiles of the cloned project (`node_modules` excluded):

- `package-lock.json` and `npm-shrinkwrap.json`: npm replaces `registry.npmjs.org` with your registry by itself. A lockfile with `registry.yarnpkg.com` URLs is reported.
- Yarn 1 `yarn.lock`: Yarn 1 downloads from the URLs in the lockfile as they are, whatever registry is configured. A lockfile with `registry.yarnpkg.com` or `registry.npmjs.org` URLs is reported.
- Yarn 2+ `yarn.lock` and `pnpm-lock.yaml` hold no registry URLs and need nothing.

A lockfile that still downloads from the public registry depends on the Lockfile input:

- `update`: the step points the URLs at `AC_MIRROR_NPM` in the cloned copy and logs the change. Nothing is pushed back to your repository.
- `fail` (default): the build stops at once and names the file.
- `warn`: the step prints a warning and the build continues.

## React Native Versions

React Native 0.80 and earlier download Hermes for iOS from `repo1.maven.org` with no setting to change it. The step warns when it finds such a version. Use React Native 0.81 or later for air-gapped iOS builds.

## Artifact Proxy Setup

| Repository | Type | Remote URL |
| --- | --- | --- |
| npm | npm proxy | `https://registry.npmjs.org` |
| Node.js | raw (generic) proxy | `https://nodejs.org` (use `<repository>/dist` as `AC_MIRROR_NODE`) |
| Maven | the Maven group of the Gradle Mirror, with Maven Central | `https://repo1.maven.org/maven2/` |

The repositories must allow anonymous read: the step has no credential inputs, and React Native downloads its Maven artifacts with `curl` without credentials.

## Limits

- GitHub dependencies in `package.json` (`github:owner/repo`, `owner/repo`, or a `github.com` git URL) are downloaded by npm as tarballs from `codeload.github.com`, not with git, and npm has no setting to change that host. Neither this step nor the Git Mirror step covers them. Change the dependency in the project, in one of two ways:
  - Recommended: a tarball through a raw (generic) proxy of `https://github.com` on your artifact proxy, for example `"https://nexus.example.com/repository/github/owner/repo/archive/refs/tags/v1.2.3.tar.gz"`. Nothing has to be mirrored, and the lockfile records the tarball's integrity. The proxy must follow redirects (`github.com` -> `codeload.github.com`). Not for packages that build themselves in a `prepare` script (for example `bob build` or `tsc` into `lib/` or `dist/`): npm runs `prepare` only for git dependencies, so the tarball has no build output. Use the git URL for those.
  - A git URL on your git server, for example `"git+https://git.example.com/github/owner/repo.git#v1.2.3"`, if you mirror the repository there. npm then clones it with git, with its submodules, and runs `prepare`. Mirror the submodules too and add the Git Mirror step, which points their `github.com` URLs at your git server.
  - A GitHub dependency of a dependency appears only in the lockfile. Redirect it with npm `overrides` in `package.json`, for example `"overrides": { "some-package": "https://nexus.example.com/repository/github/owner/repo/archive/<commit>.tar.gz" }`.
- Git URLs on hosts other than GitHub are cloned with git, which the Git Mirror step can redirect.
- Android SDK packages that the project needs and the runner image lacks (for example the NDK of React Native's new architecture) are not covered: install them in the runner image.
