# Staging a Spaces-Capable Node

The production bundle pins `ghcr.io/bluesky-social/pds:0.4`. On 2026-10-22 that tag resolved to `0.4.5046`, whose service depends on `@atproto/pds` 0.5.46. The `atproto` `main` branch at 0.5.46 has no `com.atproto.space.*` or `com.atproto.simplespace.*` endpoints and no space Lexicons, so the production image cannot create a space.

The Spaces work is still an open pull request against `bluesky-social/atproto`, on the `permissioned-data` branch. The lab pins that branch at `3a0b8c6`, where `@atproto/pds` is 0.5.32. A staging PDS runs that branch through the TypeScript dev environment. It is not a production image, and this repository's `compose.yaml` is unchanged.

## What Is Pinned

| Layer | Version |     |
| --- | --- | --- |
| Production PDS image | `ghcr.io/bluesky-social/pds:0.4`, resolving to `0.4.5046` |     |
| Production `@atproto/pds` | 0.5.46, with no space endpoints or Lexicons |     |
| Staging `@atproto/pds` | 0.5.32, at `permissioned-data@3a0b8c6` |     |
| App AT Protocol client | `@atproto/api` 0.20.42, without generated space types |     |
| App scope validation | `@atproto/syntax` 0.7.5 |     |
| App space transport | the narrow `SpaceClient` in `apps/api/src/services/atproto-space.ts` |     |
|  |  |     |

## The Staging Proof

The app's `scripts/atproto-space-smoke.ts` drives the `SpaceClient` against the lab's running PDS. It creates a disposable account, creates a user space, writes a record at a known key, reads it back, and checks the commit, the oplog, `listSpaces`, `listMembers`, and `getSpace`. The run on 2026-10-22 passed all fourteen checks.

The smoke needs no production credentials, writes nothing to a real network, and creates a new account each time. The lab's network is the source of the PDS; it is not part of this deployment.

## The Unblock

The production pin waits on the upstream pull request merging and an official image shipping with the Spaces endpoints and Lexicons. When that happens, the work is to pin the new tag or digest here, run the lab's space scenarios and the app's smoke against it, publish the app's space permission sets after their review, and then move the staging result into production. Until then, the staging PDS is the branch, and the production node stays on `0.4.5046`.

The app's published permission sets are also unchanged. The production authorization server does not know the `space` resource, so adding a space permission to an `include:` set now would make it reject the whole scope. The proposed shape and the open names are in the app's Spaces review task.
