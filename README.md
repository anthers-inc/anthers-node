# Anthers Node

**Nothing is here yet, and that is the honest state of it.** This repository exists so that the work can start in the open rather than arrive already finished.

## What a node will be

Anthers is a centralized platform today: one hub holds identity, records, money, access resolution, discovery, and the media itself. A **creator node** is the answer to the obvious question about that arrangement — what happens to a creator who no longer wants to trust it.

Two separable pieces, and they are worth keeping distinct because they solve different problems:

- **Creator-hosted delivery** moves the *bytes*. A creator stores and serves their own media while the hub continues to hold identity, records, money, access resolution and discovery. Cloud and on-premises are the same artifact here; the only difference is who pays the bill.
- **A sovereign node** moves the *records* too — a creator running their own instance of the thing, federating with the hub rather than living inside it.

## Where this actually stands

**Neither is being built.** Not started, not scheduled, and not on a date. Both are deliberate commitments that we intend to keep, and stating them as intentions rather than as work-in-progress is the only accurate way to describe them right now.

Being straight about why they were deprioritized is more useful than a roadmap square:

- Creator-hosted delivery was originally justified on **cost** — moving bandwidth off the platform. That argument evaporated when Anthers moved to object storage with no egress charge. Delivery costs nothing now, so the feature has to earn its place on sovereignty alone, which it does, just less urgently.
- A sovereign node was never on the path to the first creators, whose work lands on the hub regardless.

## Why it is promised anyway

Managed hosting should be a convenience, never a requirement. A creator-first platform that cannot be left is not creator-first — it is a landlord with good manners. The [AGPL](https://www.gnu.org/licenses/agpl-3.0.html) that covers [the platform](https://github.com/anthers-inc/anthers) is one half of that promise; being able to actually run your own is the other, and a license alone does not deliver it.

One design constraint is already settled, because it is the part that is easy to get wrong: a creator's origin holds an **outbound tunnel with no public address**, and the edge honours **only hub-signed URLs**. Pointing a CDN straight at a creator's IP is the shape to refuse — it would trade one dependency for a worse one and put a creator's home connection on the public internet.

## Following along

A public roadmap is coming, and it will be a better place to track this than a repository with no code in it. Until then: [anthers.org](https://anthers.org).

Anthers is a Colorado nonprofit corporation. The platform is free software under the GNU Affero General Public License v3.0 or later, and this will be too.
