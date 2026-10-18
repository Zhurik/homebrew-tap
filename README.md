# homebrew-tap

Homebrew formulae for my own tools.

```sh
brew install Zhurik/tap/sshrek
```

| Formula | What it is |
|---|---|
| [`sshrek`](https://github.com/Zhurik/sshrek) | `ssh` with connection history and a one-keystroke jump back to the last host |

## How it works

Formulae here are binary formulae: they download the archive a project attaches
to its GitHub release and drop the executable into the prefix. Nothing is built
from source.

Everything under `Formula/` is generated — `scripts/bump-formula.sh <owner/repo>
<tag>` reads the release's `SHA256SUMS`, renders the formula and leaves it
unchanged when it is already current. The `bump` workflow runs that script and
commits the result; each project's release workflow triggers it on a new tag.

## Adding a project

1. The project's release must attach `<name>-<tag>-<rust target>.tar.gz` archives
   and one `SHA256SUMS` file covering them.
2. Add `meta/<name>.json` here:

   ```json
   {
     "class": "Sshrek",
     "desc": "Wrapper around ssh with connection history",
     "homepage": "https://github.com/Zhurik/sshrek",
     "license": "MIT",
     "bin": "sshrek",
     "completions": { "subcommand": "completions" },
     "test": { "args": "--version", "match": "version" },
     "platforms": {
       "macos_arm": "aarch64-apple-darwin",
       "linux_intel": "x86_64-unknown-linux-musl",
       "linux_arm": "aarch64-unknown-linux-musl"
     }
   }
   ```

   `class` is the Ruby class name Homebrew expects for the file name. Drop
   `completions` when the tool has no completion subcommand. Platform slots are
   `macos_arm`, `macos_intel`, `linux_arm`, `linux_intel` — list only the ones the
   release actually ships; a platform covering a single architecture gets a
   `depends_on arch:` guard, so the other one fails with a clear message.
   `test.match` of `"version"` asserts the formula's version appears in the
   output; any other value is matched literally.

3. Give the project a `TAP_DISPATCH_TOKEN` secret (see below) and a job that
   triggers this tap at the end of its release workflow:

   ```yaml
   bump-tap:
     needs: release
     if: ${{ !contains(github.ref_name, '-') }}
     runs-on: ubuntu-latest
     steps:
       - run: |
           gh workflow run bump.yml --repo Zhurik/homebrew-tap \
             --field repo="$GITHUB_REPOSITORY" --field tag="$GITHUB_REF_NAME"
         env:
           GH_TOKEN: ${{ secrets.TAP_DISPATCH_TOKEN }}
   ```

4. Run `scripts/bump-formula.sh <owner/repo> <tag>` once locally (or trigger the
   workflow by hand) to create the formula.

## The token

`TAP_DISPATCH_TOKEN` is a fine-grained personal access token scoped to this
repository alone, with `Actions: write` and `Metadata: read`. It only starts the
`bump` workflow — the commit itself is made by that workflow's own
`GITHUB_TOKEN`, so the token needs no write access to the contents.
