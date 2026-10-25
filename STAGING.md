# Staging a Spaces-Capable Node

The bundle pins the reference distribution, `ghcr.io/bluesky-social/pds:0.4`, and keeps pinning it: a creator running a node for themselves should not be on alpha software. Anthers' own node runs the alpha deliberately, from a second compose file that has to be named explicitly.

Bluesky publishes a spaces-capable image of the reference implementation at `ghcr.io/bluesky-social/atproto:pds-spaces-alpha`, built from the `permissioned-data-alpha` branch and pushed every Thursday by the `build-and-push-pds-ghcr` workflow. The tag moves with each build, so the node pins a digest.

## What Is Pinned

| Layer | Version |     |
| --- | --- | --- |
| Bundle PDS image | `ghcr.io/bluesky-social/pds:0.4`, the reference distribution, unchanged |     |
| Anthers' node | `ghcr.io/bluesky-social/atproto:pds-spaces-alpha@sha256:69f2da2d853d7fe74e78f619b478047c94eadbd28bd5b80d2f51ec5599df1c64` |     |
| That image's revision | `ac0c9f15`, the 2026-10-22 build of `permissioned-data-alpha` |     |
| The `@atproto/pds` inside it | the alpha snapshot published as `0.0.0-spaces-alpha-20261022141228` |     |
| App AT Protocol client | `@atproto/api` 0.20.42, without generated space types |     |
| App scope validation | `@atproto/syntax` 0.7.5 |     |
| App space transport | the narrow `SpaceClient` in `apps/api/src/services/atproto-space.ts` |     |
|  |  |     |

## The Alpha Override

The image is applied by naming a second compose file, so the bundle's default is untouched:

```sh
docker compose -f compose.yaml -f compose.spaces-alpha.yaml up -d
```

`compose.spaces-alpha.yaml` carries the digest and the reasoning. A bump changes that one line, and re-runs the lab scenarios and the app's smoke against the new build.

**The image lives in `bluesky-social/atproto`, not `bluesky-social/pds`.** The `pds` repository is the distribution this bundle is built from; the `atproto` repository is the reference implementation. Looking only at `pds` finds 281 tags and none of them spaces-capable, which is how the pin was missed once already.

⚠️ **One thing it does need: `/pds` owned by uid 1000.** The alpha image runs as `node`, where the reference distribution sets no user and runs as root. A `/pds` created by `scripts/setup.sh` is root-owned, so the server cannot create its data directory until the ownership changes.

That ownership is where upstream is heading rather than a workaround to unwind: the spaces image already runs unprivileged, and the reference distribution will need the same ownership when it adopts the same hardening. The reverse drift is the one to remember — a stretch on the root-run image leaves root-owned files behind, and the ownership change is repeated before returning to this one.

**The blanket chown takes more than the data directory, so hand the secrets back afterwards.** `setup.sh` writes `pds.env` with the PLC rotation key and the admin password at `0600`, and the Caddy directory holds the ACME account key. None of it needs to belong to 1000, and the server never reads `pds.env` itself — Docker parses it as the compose env file:

```sh
chown -R 1000:1000 /pds
chown root:root /pds/pds.env && chmod 0600 /pds/pds.env
chown -R root:root /pds/caddy
chown -R root:root /pds/heartbeat
```

⚠️ **uid 1000 on that machine belongs to the PDS's data now, not to a person.** The droplet has no such account today, which makes the owner unmapped and harmless; the first human user added to the box would be assigned 1000 and inherit both the data directory and, without the lines above, the rotation key. If a login user is ever wanted there, run the server under a dedicated uid instead — `user: "1001:1001"` in the override, with the tree owned by 1001 — so no assigned user can reach it.

What the change buys is the server not running as root inside its container. What it does not buy is network isolation: the service uses `network_mode: host`, so it still reaches anything listening on the loopback. The bundle's one remaining root-equivalent hole is the `docker.sock` mount on watchtower, which is not running because the `unattended` profile is omitted, and remains a hole if that profile is ever enabled.

## The Staging Proof

The app's `scripts/atproto-space-smoke.ts` drives the `SpaceClient` against a running PDS. It creates a disposable account, creates a user space, writes a record at a known key, reads it back, and checks the commit, the oplog, `listSpaces`, `listMembers`, and `getSpace`. The 2026-10-22 run against the lab's network at `3a0b8c6` passed all fourteen checks.

The smoke needs no production credentials, writes nothing to a real network, and creates a new account each time.

On 2026-10-25 the pinned image itself was the PDS: `sha256:69f2da2d…` running against a private PLC, reporting `@atproto/pds` 0.5.32. The smoke passed all fourteen checks, and `apps/api/src/__tests__/space-backup-staging.test.ts` passed both of its tests (36 assertions) — capture, delete, restore, and read back through the same client. A space under `org.anthers.userSpace` was created with that space type unpublished, which is the behaviour the vocabulary hold depends on.

The capture still stores the archive as `star.car` with `application/vnd.ipld.car`, and the alpha serves STAR-lite as `application/octet-stream`. Nothing breaks, because a restore replays the record list and the archive is carried opaquely, but the name and content type describe a format the image no longer sends.

## What the Alpha Changed Under Us

The 2026-10-22 build is not the branch state the lab pinned at `3a0b8c6`, and the differences are the app-side work this pin carries:

- `com.atproto.space.getRepo` serves STAR-lite rather than a two-root CAR, as `application/octet-stream`. The logical backup still writes the archive as `star.car` with `application/vnd.ipld.car`.
- `excludeValues` is gone from the record and oplog queries.
- A space record is capped at 1 MiB.
- `#atproto_space` and `#atproto_space_host` are retired from the DID document.
- `notifySpaceDeleted` retries until delivery.

## The Unblock

The pin returns to the reference distribution when the upstream pull request merges and `bluesky-social/pds` ships a tag that carries the spaces endpoints. At that point the override file is deleted, the digest is replaced by that tag, and the image's user model comes back to root, which is the only difference it needs.

The app's published permission sets are also unchanged, on purpose. The two space types and the `space` permission are ours and permanent once published, and both encode shapes the alpha still defines, so they stay unpublished until the merge or until those shapes settle. Every account Anthers hosts is reached with the credential Anthers already holds, so the app reads and writes a space without an OAuth `space:` scope; what the hold defers is a non-hosted identity reading its space through the app.
