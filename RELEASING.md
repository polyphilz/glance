# Releasing glance

glance uses semantic versioning.

- `PATCH` for backward-compatible fixes
- `MINOR` for backward-compatible features
- `MAJOR` for breaking changes

While the project is still in `0.x`, treat `MINOR` bumps as the place to put breaking changes.

## Release flow

1. Bump the version:

   ```bash
   ./scripts/release.sh patch
   ./scripts/release.sh minor
   ./scripts/release.sh major
   ./scripts/release.sh 0.2.0
   ```

2. Review the diff and commit it:

   ```bash
   git add VERSION
   git commit -m "Release vX.Y.Z"
   ```

3. Push the release commit:

   ```bash
   git push origin main
   ```

4. Create and push an annotated tag:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

5. Publish a GitHub release so the bootstrap installer can resolve the latest stable version:

   ```bash
   gh release create vX.Y.Z --generate-notes
   ```

## Install behavior

- `install.sh` installs the latest GitHub release by default when run via `curl`.
- Set `GLANCE_REF=vX.Y.Z` to pin a specific release.
- Set `GLANCE_REF=main` to install the unreleased branch head.
- Running `./install.sh` from a local checkout keeps the symlink-based dev install behavior.
