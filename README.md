# Anthers Node

A creator node is what you run if you want your identity on the AT Protocol to be yours
rather than Anthers'. This repository is the bundle that runs one: a Personal Data Server,
TLS in front of it, and continuous backup behind it.

**Anthers builds no server here, and that is the design.** The server is
[the reference Personal Data Server](https://github.com/bluesky-social/pds), which other
people maintain. The whole point of a node is that a creator who leaves Anthers is fine, and
a node running Anthers' own server software would mean leaving Anthers also meant leaving
Anthers' software — portability quietly degrading into *portable as far as our export
reaches*. So what is here is a compose file, configuration, and the operational pieces the
upstream installer leaves to you.

## What a node is, and which half this is

A node is two things sitting beside each other: a **Personal Data Server**, which holds your
identity and your records, and a **media origin**, which serves your large files.

This is the first half. The second is deliberately absent, because what the hub and a
creator's origin say to each other is still undesigned, and writing the daemon first would
produce exactly the implementation whose shape then argues for the protocol. The records
half stands alone and is useful alone, so it ships alone. One constraint on that future half
is already settled and worth stating so nobody designs against it: a creator's origin holds
an **outbound tunnel with no public address**, and the edge honors **only hub-signed URLs**.
Pointing a CDN straight at a creator's IP is the shape to refuse.

## The same bundle at two sizes

Anthers running an identity server for many people and a creator running one for themselves
are not two products. They are this bundle at two settings, and the difference is four
environment variables and one compose profile:

| Setting | A creator, for themselves | Anthers, for many people |     |
| --- | --- | --- | --- |
| `PDS_SERVICE_HANDLE_DOMAINS` | your own domain | `.anthers.social` |     |
| `PDS_INVITE_REQUIRED` | `false` — nobody to gate | `true` |     |
| Email block | unset — you are the only account | required |     |
| `--profile unattended` | yes — nobody is watching the box | no — updates are deliberate |     |
|  |  |  |     |

There is no second image and no second compose file.

## Standing one up

You need a machine running Docker with ports 80 and 443 free, a domain, and somewhere to put
backups. About 1 GB of memory and 20 GB of disk is enough for a handful of accounts; the
database does not grow with your audience, because reading traffic lands on the network's
index rather than on you. Media is the part that is genuinely large.

```sh
git clone https://github.com/anthers-inc/anthers-node
cd anthers-node
sudo ./scripts/setup.sh your-node.example.org
```

That lays out `/pds`, generates the secrets, and stops. It then wants three things from you,
and it will tell you so:

1. **Fill in the `NODE_BACKUP_*` block** in `/pds/pds.env`. A node holds the only copy of a
   repository, so a node without a backup target is a node with a countdown on it.
2. **Point DNS at the machine** — an `A` record for the hostname, and a wildcard `A` record
   for `*.hostname` so handles issued here can get certificates.
3. **Copy `/pds/pds.env` somewhere off the machine.** It holds the rotation key, which
   cannot be regenerated, and the backups deliberately do not contain it.

Then start it:

```sh
docker compose --profile unattended up -d
./scripts/verify-restore.sh          # do not skip this
```

## Backups, and the file that is easy to miss

Three things need backing up and they want three different mechanisms, which is the part the
upstream installer leaves entirely to the operator.

The **databases** are replicated continuously by Litestream. The server keeps three shared
ones and then **one more per account**, created the moment somebody signs up, so the config
watches the directory rather than listing files — a static list would be complete only until
the next signup, and would fail silently.

The **blobs** are large and immutable once written, so they are synced rather than
replicated.

The **signing keys** are the ones to know about. Beside every account's database is a
32-byte file called `key`, which is the key that account signs its repository with.
Litestream replicates databases, so it will never carry it, and **a restore that brings back
every database without the keys produces a repository that reads perfectly and can never be
written to again.** That is not a guess: with the keys deleted and nothing else changed, a
restored server answered `describeRepo` with a 200 and failed `putRecord` with an opaque
500. `scripts/backup-files.sh` carries them, `scripts/restore.sh` refuses to finish without
them, and the key backup doubles as the manifest of which accounts existed — which is also
the only thing that makes a restore possible, since Litestream can discover databases while
writing and offers nothing that enumerates them while reading.

Put the file backup on a timer; the replication runs continuously as part of the bundle.

```sh
0 * * * * /path/to/anthers-node/scripts/backup-files.sh
```

**A backup that has never been restored is not a backup.** `scripts/verify-restore.sh`
restores the live backups into a scratch directory, boots a second server against them, and
checks that every account resolves. Run it after standing the node up and after any change
to the replication config.

## The keys, and who holds them

An identity carries an ordered list of rotation keys, and a key ranked higher can undo what
a lower one signed — within 72 hours of it happening, which is worth knowing before you need
it. A server creating an account sets **one** key by default: its own. That is the whole of
it unless somebody arranges otherwise, and it means a hosted account is an account its host
holds the only key to.

This bundle expects up to three, in this order:

| Rank | Key | Held by |     |
| --- | --- | --- | --- |
| 1 | `recoveryKey`, passed at account creation | the account holder |     |
| 2 | `PDS_RECOVERY_DID_KEY` | the operator, **offline** |     |
| 3 | `PDS_PLC_ROTATION_KEY_…` in `pds.env` | this machine |     |
|  |  |  |     |

The third has to be online, because the server signs with it. The second exists precisely
because the third is online: if this machine is compromised, an offline key ranked above it
is what lets you clobber whatever was signed. `setup.sh` will not generate it for you,
because a key this machine generated is a key this machine has held — so generate it
elsewhere and paste only the `did:key:` public half into `pds.env`:

```sh
./scripts/generate-recovery-key.sh          # on your laptop, not on the node
```

It prints both halves and writes nothing. It also checks its own encoding against a known
answer before generating anything, because a `did:key:` that is subtly wrong does not fail —
it goes into the config looking correct and is discovered on the day you need it.

Put the private half somewhere you can reach **within 72 hours**, since that is the window
in which this key can undo what a lower one signed. A password manager is the usual right
answer. A safe you visit twice a year is not.

The first is the one that matters if you are running this for other people. It is theirs,
it outranks yours, and it means they can leave without your cooperation. Note what it does
and does not do: it moves an **identity**. It does not move a repository, because fetching
that means asking the server being left. Anyone hosting identities for other people owes
them an export as well as a key, or the exit only works when everybody is being agreeable.

## Being on the network is a separate, deliberate act

`PDS_CRAWLERS` is empty here, and that is the one place this bundle disagrees with the
upstream installer, which ships a value. That variable is the act of asking the network to
come and read this server. Until it is set, accounts work perfectly well and nothing else on
the network knows they exist; setting it puts every account on the machine onto the public
network at once, on the same footing as making a source repository public. It is a decision
made once and announced, not a line filled in while copying a config.

## Why this is promised at all

Managed hosting should be a convenience, never a requirement. A creator-first platform that
cannot be left is not creator-first — it is a landlord with good manners. The
[AGPL](https://www.gnu.org/licenses/agpl-3.0.html) that covers
[the platform](https://github.com/anthers-inc/anthers) is one half of that promise; being
able to actually run your own is the other, and a license alone does not deliver it.

Anthers has not yet started hosting identities, and will not offer to hold anybody's keys
until moving an identity out demonstrably works. What Anthers is building and when is at
[anthers.org/roadmap](https://anthers.org/roadmap).

Anthers is a Colorado nonprofit corporation. The platform is free software under the GNU
Affero General Public License v3.0 or later, and so is this.
