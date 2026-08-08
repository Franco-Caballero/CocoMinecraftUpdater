# Future design ideas

This document is a parking lot for ideas that are intentionally not implemented.
Existing experiences keep their current contracts unless a future change explicitly
updates their catalog, tests, documentation, and live-installation plan.

## Roving host for a long-lived vanilla-plus world

**Status:** theoretical idea only; no implementation or live-world migration is
authorized by this note.

### The idea

For a future long-standing, mostly vanilla experience, the first eligible player
to open the experience becomes the temporary LAN host. Other players who open it
while that session is active automatically prepare the same pack and join the
advertised host. When the host leaves cleanly, the world is saved, a new eligible
player acquires the host lease, and the group reconnects to that player.

The intended user experience is:

1. No one waits for one particular person to start Minecraft.
2. The first person who is ready can start the world.
3. A later player joins the existing session instead of starting a second one.
4. Hosting can move between trusted players over the life of the world.

This should be a capability of a specifically designed future experience, not a
global change to Backrooms, DREAD, Zombie Apocalypse, COBBLEVERSE, or Coco
original.

### What ZeroTier can and cannot do

ZeroTier membership and Minecraft hosting are separate concepts. The ZeroTier
controller authorizes a device into the private network; each device then has its
own ZeroTier identity and managed address. An authorized device can, in principle,
listen for Minecraft traffic on its own ZeroTier address. It does not need to be
the network controller, and the controller's `identity.secret` must never be
copied to friends or embedded in Coco.

The current Coco design is more restrictive than ZeroTier itself:

- `10.77.37.1` is hard-coded as the discovery and Minecraft endpoint.
- The session service only binds to `10.77.37.1:25564`.
- The host is identified by a local `config\coco-host.json` marker.
- Host-only networking and LAN-adapter files are not installed on ordinary
  clients.
- Client firewall rules are not currently prepared for inbound Minecraft and
  voice traffic.
- The current session service is a single-host announcement service, not an
  election or lock service.

Therefore, **yes, all trusted players could become possible Minecraft hosts on
the same ZeroTier network**, but Coco would need a separate dynamic-host design.
They would need to be authorized network members, have a healthy ZeroTier
interface and a unique managed address, have the exact host-capable pack, and
open narrowly scoped TCP/UDP firewall rules while hosting. Network membership
alone must not grant permission to claim the world.

### Controller availability and passive prefetch

The current Coco network uses a local ZeroTier controller on the designated
machine. That machine also runs Coco's automatic authorizer, which uses the
local controller API to approve pending members. The consequences are:

- A device that was already authorized and has a working ZeroTier membership
  should be able to communicate with other already-authorized devices while the
  controller machine is offline; the controller is not the Minecraft data path.
- A new device cannot rely on automatic authorization while that controller is
  offline. It would need to be pre-authorized in advance, or the controller
  would need to move to an always-on machine/service with its state kept safe.
- Even if ZeroTier connectivity survives, the current Coco launcher still looks
  for the fixed `10.77.37.1` session endpoint. Dynamic hosting therefore also
  needs dynamic discovery and a lease independent of the current controller.

For a future world, the active Minecraft host should be the sole authoritative
source of world state. Non-host players may maintain a **read-only prefetch
cache**, but that cache must not be treated as a second world or merged with the
authoritative copy.

The safe shape is checkpoint-based prefetch:

1. The host reaches a coordinated save/checkpoint and creates an immutable,
   versioned snapshot or delta in a staging area.
2. The host publishes a manifest containing the world generation, file sizes,
   hashes, and required pack identity.
3. Clients download missing snapshot pieces over ZeroTier at low priority while
   they play. They store them outside the active `saves` directory.
4. On clean handoff, the host creates a final checkpoint. The next host verifies
   its cached checkpoint, downloads only missing deltas, closes Minecraft, and
   restores the complete snapshot before becoming authoritative.

The system must not continuously copy files directly out of a live `saves`
directory. Region files, `level.dat`, player data, and mod state can be changing
at different times; a partial copy could look complete while representing no
valid moment in the world. A crash can therefore leave the next host with only
the last complete checkpoint, and recent progress may be lost.

The authoritative handoff bundle would normally include the complete world
directory: terrain and all dimensions, `level.dat`, world data, player data,
advancements, statistics, maps, datapacks, and any world/server configuration
that a mod stores with the save. It should exclude transient locks such as
`session.lock` and normally exclude client-only caches, logs, screenshots,
shader caches, and visual databases such as Distant Horizons data unless a
specific experience proves they are required.

Traffic is proportional to missing data, not to the mere fact that Minecraft is
running. If a 2 GiB world snapshot is missing on three clients, the group needs
about 6 GiB of host upload in total. If all three already have a valid checkpoint
and only 150 MiB changed, the next handoff may need roughly 150 MiB per client
instead. Actual sizes depend on changed files, compression, and whether a
changed region file must be resent as a whole. Background transfer would need a
bandwidth/disk/CPU limit so it cannot compete with gameplay.

### The required session protocol

The phrase “whoever opens first” needs a precise meaning. Distributed computers
cannot prove an exact real-time first arrival when messages can be delayed. The
safe definition would be “the first eligible player to acquire an atomic lease.”

A future protocol would need a rendezvous/lease authority that is independent of
the Minecraft endpoint, or a carefully designed peer-election protocol. It would
roughly do this:

1. Each launcher validates the pack hash, loader, Java, host adapter, firewall,
   hardware policy, and locally available world state.
2. An eligible launcher requests a lease for the experience and world generation.
3. Exactly one candidate wins. The lease contains a session ID, owner's ZeroTier
   address, Minecraft port, pack identity, world-generation number, and a short
   renewal expiry.
4. The winner starts the integrated LAN server and publishes `preparing`, then
   `ready` only after the endpoint is actually listening.
5. Other launchers discover the active lease, verify that the pack and world
   generation match, prepare their client files, and connect to the advertised
   address rather than to `10.77.37.1`.
6. A clean host departure publishes `handoff`/`stopping`, saves and closes the
   world, transfers or exposes the latest world snapshot, and releases the lease.
7. A new eligible player acquires the next lease and resumes from the last
   complete snapshot. Clients retry the new endpoint after a visible disconnect.

The lease must prevent split-brain hosting. A timeout alone is not enough: a
host with a temporarily broken network might still be running while another
player starts an older copy. The protocol needs fencing, an authenticated owner,
and a conservative grace period. A small always-available rendezvous service is
the simplest robust option; a fully peer-to-peer election is possible in theory
but much harder to make safe.

### Handoff quality and failover latency

An integrated Minecraft server cannot be moved live to another computer while
preserving its process and TCP connections. The authoritative server owns
in-memory entity, tick, inventory, and mod state. When it stops, players must
eventually reconnect to a new server. Therefore “seamless” should mean no
manual file handling, automatic discovery, and automatic reconnect; it cannot
mean zero interruption with the ordinary integrated server.

A planned departure can be made relatively smooth:

1. The host announces `draining` and keeps its lease. No new host is allowed to
   start while the handoff is being prepared.
2. The launcher briefly freezes or pauses gameplay, creates a coordinated
   checkpoint, and transfers only the missing changed objects/regions to R2 or
   a nominated replacement. The replacement verifies the manifest and hashes.
3. The replacement starts from that checkpoint and publishes `ready` only after
   its Minecraft listener is actually accepting connections.
4. The coordinator transfers the lease and commits the new generation. Clients
   automatically close the old connection and retry the new endpoint.
5. The old host releases its lease only after the replacement is ready, so a
   slow upload or failed startup does not create an unnecessary election.

With a pre-fetched replacement and a small final delta, the interruption could
be on the order of several to tens of seconds. Without a prepared replacement,
world loading and transfer can take tens of seconds or minutes. A crash is
slower: the system must wait for the lease grace period, then the replacement
must start from the newest verified checkpoint. A conservative design might
take roughly 30--90 seconds after an abrupt failure, and work after the last
committed checkpoint can be lost.

Useful optimizations include a designated **warm standby** whose pack, Java,
launcher state, and latest verified checkpoint are already prepared; frequent
small checkpoints or region-level deltas; automatic client reconnect; and a
direct final transfer from the old host to the nominated replacement. A standby
must not run a second writable copy of the same world: two active servers would
diverge and could corrupt the authority. It can stage and validate an isolated
copy, but true hot standby requires difficult application-level replication of
Minecraft and mod state.

More radical options exist. A proxy or stable logical endpoint can hide the new
ZeroTier address, but it cannot preserve a dead Minecraft connection or recover
uncommitted in-memory state. A replicated operation journal might reduce the
amount of lost work, but it would need mod-specific support. An always-on
dedicated server or a VM with shared storage/live migration gives the closest
thing to continuous hosting, at the cost of abandoning the “whoever opens
first” model or adding substantial infrastructure.

### Host versus coordinator

The **host** is the computer running the integrated Minecraft server and the
current authoritative world. Other players connect to its current ZeroTier
address. The host needs the pack, the world, enough resources, and the local
firewall/network configuration; it does not need controller-admin privileges.

The **coordinator** is a small, separate service. It does not render Minecraft,
relay gameplay, or need to contain the whole world. Its responsibilities are to:

- record the active lease and session owner;
- serialize competing host claims;
- track the world generation and pack identity;
- record which snapshot manifests and replicas are complete;
- reject stale owners after a newer lease/generation exists; and
- provide rendezvous information when the current host's address changes.

The coordinator could also provide durable snapshot storage, but that is an
optional combination rather than the definition of a coordinator. Putting both
roles on an always-on VPS, NAS, or small home server is convenient. Putting the
coordinator on the temporary Minecraft host defeats the purpose of failover.
The ZeroTier controller is also not automatically the coordinator: it handles
network membership and configuration, while the coordinator handles world
ownership.

### Connection loss and uncommitted local work

Checking “is the internet up?” is not enough. A host should check the actual
coordination path, its ZeroTier path, its lease renewal, and the availability of
at least one destination that acknowledged the latest checkpoint.

There should be three different kinds of save state:

1. **Local autosave:** Minecraft's normal local writes. This protects the host's
   disk but is not available to another host.
2. **Prepared checkpoint:** a consistent, hashed snapshot staged locally and
   ready to transfer.
3. **Committed checkpoint:** a prepared checkpoint stored and acknowledged by a
   coordinator, peer, or durable replica. This is the state that failover may
   safely use.

If the host temporarily loses the coordination/replication path, it can enter a
short `degraded` grace period. After that, there are two possible policies:

- **Strict mode:** save and close Minecraft, so no divergent world can continue
  accumulating.
- **Branch mode:** allow local play, but mark all new work as uncommitted. It
  must never be advertised as canonical until it is reconciled with the lease.

When connectivity returns, the host may commit its local branch only if its lease
and world generation are still valid and no other host acquired a newer lease. If
another host already took over, the old branch cannot be merged automatically:
it should be preserved in a quarantine/backup location and the host should
restore the last committed checkpoint. “Discard” should mean “stop using this
branch as the world,” not silently delete the user's data.

The safest initial policy is strict mode. A temporary network hiccup then causes
a visible pause or shutdown, but it does not create a second authoritative world.

### Checkpoints while the host is playing

A complete transferable snapshot can be generated while the host is playing, but
it is not the same as copying the live `saves` folder every few seconds. The host
needs a coordinated save/flush point, a staged copy or copy-on-write mechanism,
and a manifest that identifies the exact generation. Full snapshots can be
periodic; later checkpoints can be incremental over changed files or regions.

The active world may therefore be slightly ahead of the latest committed
checkpoint. If the host crashes, only the committed checkpoint is guaranteed to
be recoverable. If the host shuts down cleanly, it should create one final
checkpoint and wait for the required replica acknowledgement before releasing
the lease.

### Candidate cloud architecture: Worker, Durable Object, and R2

Cloudflare could provide the always-available pieces without keeping a personal
computer powered on:

- A **Worker** would expose the authenticated API for acquiring leases,
  host heartbeats, manifests, and short-lived upload/download authorization. It
  is a request handler, not a process that should hold the world in memory.
- A **Durable Object** would represent the one world/experience coordinator. Its
  serialized, persistent state could record the current lease epoch, owner,
  expiry, world generation, and snapshot commit status. An alarm could notice an
  expired lease even when no new heartbeat arrives.
- **R2** would be the durable object store for snapshot bundles, manifests, and
  deltas. The host should upload large objects directly with scoped, short-lived
  presigned URLs and resumable multipart upload rather than sending a multi-GB
  world through the Worker.

A possible object layout is:

```text
worlds/<experienceId>/<worldId>/<generation>/manifest.json
worlds/<experienceId>/<worldId>/<generation>/parts/...
```

The local client caches would remain useful: clients prefetch objects from R2
while playing, and the next host only downloads missing generations or parts.
R2 would be the durable fallback when no client is online to receive the final
handoff. Storage retention, private access, encryption policy, quotas, and
cleanup still need explicit decisions; cloud storage is not automatically a
backup policy.

Only the current host needs a lease heartbeat. It renews ownership so the
coordinator can distinguish an active host from a failed one. Ordinary clients
do not need to heartbeat merely because they are connected, and their gameplay
traffic does not pass through the coordinator. Clients may poll or subscribe to
session status for discovery, reconnect UX, or a handoff prompt, but those are
separate optional presence/discovery operations and should use a much lower
rate than the host lease heartbeat.

The heartbeat and snapshot state should be separate. For example:

1. The host obtains lease epoch `E` and sends a heartbeat periodically.
2. It creates a coordinated checkpoint, uploads all objects, and publishes a
   manifest with sizes and hashes.
3. The coordinator verifies that the upload is complete and marks generation
   `G` as `prepared` or `committed` according to the protocol.
4. If the host disappears before the next heartbeat, the lease may expire, but a
   complete, verified generation `G` remains usable. The missing heartbeat means
   “the host may have died”; it does **not** by itself mean “the uploaded snapshot
   is corrupt.”
5. The next host may recover the newest verified generation. Any world changes
   made after `G` and before the failure are uncommitted and may be lost.

An upload that ended halfway, has a failed hash, or was copied from an
inconsistent live save must remain unusable regardless of heartbeat status. A
clean shutdown can still send an explicit `stopping` message and final commit,
but the recovery path must work when that message never arrives.

The heartbeat interval should not equal the failure cutoff. A 10–15 second
heartbeat may be reasonable, but the lease needs a longer expiry and grace period
to tolerate packet loss, a busy host, or a brief Cloudflare/ZeroTier outage. A
Durable Object can serialize claims and schedule expiration, but it cannot
physically stop an old Minecraft process that is isolated from the network; the
launcher must enforce the local degraded/strict-mode shutdown policy as well.

### Planning estimates (not measured)

The useful unit is the **changed payload**, not the total size of the world.
The first checkpoint may need the whole baseline, but later generations should
reference immutable content-addressed parts and transfer only new or changed
regions and authoritative files. A checkpoint is not recoverable until its
staged objects have been hashed, uploaded, and referenced by a committed
manifest.

The following rough transfer times assume about 80% of the nominal connection
speed, one upload from the host to R2, and clients downloading in parallel. They
are planning estimates, not an R2 speed guarantee:

| Changed payload | 10 Mbps | 20 Mbps | 50 Mbps | 100 Mbps |
| --- | ---: | ---: | ---: | ---: |
| 25 MiB | 26 s | 13 s | 5 s | 3 s |
| 50 MiB | 52 s | 26 s | 11 s | 5 s |
| 100 MiB | 1 m 45 s | 52 s | 21 s | 11 s |
| 250 MiB | 4 m 22 s | 2 m 11 s | 52 s | 26 s |
| 500 MiB | 8 m 44 s | 4 m 22 s | 1 m 45 s | 52 s |
| 1 GiB | 17 m 54 s | 8 m 57 s | 3 m 35 s | 1 m 47 s |

For example, a 100 MiB generation every five minutes is sustainable with a
20 Mbps upload: the host spends roughly 52 seconds uploading it, leaving time
for gameplay and overhead. At 10 Mbps the same generation takes nearly two
minutes, still possible but with less margin. A 500 MiB generation every five
minutes is not sustainable at 10 Mbps; at 50 Mbps it is plausible. A client must
also download the generation, but R2 can serve several clients concurrently.

The sustainable changed-data budget is approximately 60/120/300/600 MiB per
minute at 10/20/50/100 Mbps respectively under these assumptions. A safer
target is around half of those values because the connection also carries
Minecraft, voice, uploads, retries, and other household traffic. If a client
cannot download each generation before the next one arrives, its cache backlog
grows instead of remaining current.

A practical first cadence would be:

- host lease heartbeat every 10--15 seconds;
- local coordinated checkpoint every 30--60 seconds if the save pause is
  acceptable;
- changed objects uploaded in the background as soon as a valid checkpoint is
  available;
- a committed cloud generation every 2--5 minutes during normal play; and
- a mandatory final committed generation before a planned handoff.

If measurements show small deltas and adequate bandwidth, a one-minute
committed generation is reasonable. Thirty-second commits are technically
possible, but they are not automatically useful: packaging, hashing, disk
reads, R2 object count, storage retention, and checkpoint pauses can become the
real bottlenecks. The implementation should measure save time, bytes changed,
staging time, upload time, manifest commit time, and client catch-up time before
choosing the interval.

For a healthy client whose download keeps pace, expected cache staleness is
roughly the checkpoint interval plus upload and download time. With 100 MiB
every five minutes and 20 Mbps in both directions, a newly committed generation
could be available to the client roughly 1--2 minutes after the checkpoint;
with 50 Mbps, it could be under a minute. This is a bounded cache lag, not a
mirror of every live block change.

The measured Coco original baseline is about 7.28 GiB, including about 4.82 GiB
of Distant Horizons data. A first upload of that entire baseline would take
roughly 130/65/26/13 minutes at 10/20/50/100 Mbps using the same assumptions.
Excluding the measured Distant Horizons data leaves about 2.46 GiB, or roughly
44/22/9/4 minutes. Those are one-time seed transfers; recurring generations
should be much smaller if visual caches are excluded and content-addressed
parts are reused.

The free-tier request budget is not the main constraint if bulk data goes
directly to R2. With one host heartbeat every 15 seconds and two or three Worker
control calls per committed generation, an eight-hour session is approximately:

| Commit interval | Worker requests for host + snapshot control |
| --- | ---: |
| 5 minutes | 2,100--2,200/day |
| 1 minute | 2,900--3,400/day |
| 30 seconds | 3,800--4,800/day |

A host running continuously would use about 6,300--6,600, 8,600--10,100, or
11,500--14,400 requests/day respectively. These estimates exclude optional
client polling. They fit below the Workers Free account limit of 100,000/day,
but Brevet's 5,000--10,000 daily requests and any other Worker traffic still
consume the same account budget.

R2 has separate limits and accounting: Standard storage includes 10 GB-month,
1 million Class A operations, 10 million Class B operations, and free egress.
Frequent uploads can therefore be request-cheap but storage-expensive. For
example, 100 MiB of unique changes every five minutes for eight hours creates
about 9.6 GiB of new data per day if every generation is retained. Retention
should keep only the latest few committed generations plus an intentional
longer-term backup, with mark-and-sweep cleanup after active downloads finish.
Multipart parts also count as write operations, so the actual object layout must
be included in the budget.

Cloud storage adds operational risks of its own:

- The bucket must remain private. Presigned URLs are bearer credentials and need
  short expirations, narrow object paths, and no secrets in launcher logs.
- Snapshot object keys should be immutable and generation/content-hash based.
  Mutable manifests behind a cache can expose stale or partially replaced state;
  a new generation should be published by a final commit record after every part
  is verified.
- Garbage collection must be manifest-aware. An object shared by generations
  must not be deleted merely because one older snapshot was removed.
- R2/Worker/Durable Object outages, account suspension, lost billing access, or
  a provider migration must have a degraded path. The launcher should retain a
  usable local checkpoint and the group should periodically export an independent
  backup if the world matters.
- A failed upload or a large retry storm can create cost and load spikes. Upload
  concurrency, snapshot frequency, object counts, retention, and account spend
  alerts need limits.
- A real restore test is required. It is not enough to see successful uploads;
  a clean machine must be able to download a manifest, reconstruct a world,
  validate it, and reach the Minecraft menu/world without the original host.
- Snapshot staging needs free disk space in addition to the live world. Atomic
  promotion may temporarily require more than one copy of the changed data.

### Incremental snapshot model

A snapshot should be treated as a logical state, not necessarily as one large
ZIP file. A manifest can map each authoritative path or content-addressed part
to a hash:

```text
generation 120
  level.dat                 -> hash-a
  region/r.0.0.mca          -> hash-b
  DIM-1/region/r.0.-1.mca   -> hash-c
  playerdata/alice.dat      -> hash-d
```

The client in generation 115 sends its known hashes. The coordinator/storage
returns only the objects whose hashes are absent or different. It can therefore
jump directly from 115 to 120 without downloading five complete snapshots, as
long as the referenced objects and manifests have been retained. A client in
generation 117 may need fewer objects, but the number of version labels itself
does not determine the transfer size.

Periodic full baselines are still useful to prevent an endless delta chain. A
changed region may still require re-uploading that region-sized object unless a
smaller, content-defined chunking strategy is introduced. The first practical
version should prefer correctness and simple immutable parts over block-level
Minecraft diffs.

### Snapshot granularity

Frequency and granularity are related but different. A generation can be
published every few seconds while still containing a relatively large changed
region, and a very small change can be delayed if the next consistent checkpoint
has not been created yet.

| Level | Smallest useful unit | Feasibility |
| --- | --- | --- |
| Full baseline | Whole world | Safe but only suitable for initial seeds or rare compaction |
| File/region | Save file or `.mca` region | Best first implementation; simple and reliable |
| Chunk | Individual compressed Minecraft chunk | Smaller transfers, but needs format-aware dirty tracking |
| Event journal | Block/entity/inventory/mod operations | Most granular, but requires server/mod instrumentation and replay |

Minecraft region files group 32 by 32 chunks. A single block edit may rewrite a
compressed chunk inside a region, and a simple file copier may therefore resend
the whole region. Parsing region files can reduce that unit to individual
chunks, but it does not capture every authoritative change: player data, maps,
POI, entities, `level.dat`, mod databases, and other files may change alongside
the region. A generic launcher cannot safely infer all of those changes from
file timestamps alone.

The most aggressive practical design would maintain a dirty-object queue:

1. After a coordinated save boundary, identify changed chunks/files and bundle
   them into small immutable delta objects.
2. Upload those objects continuously, for example every 5--15 seconds or when a
   1--5 MiB threshold is reached.
3. Publish a committed manifest every 30--60 seconds, or sooner when the delta
   is small and the previous upload has finished.
4. Periodically compact the committed generations into a fresh baseline.

At that cadence, 1 MiB every 10 seconds is only about 0.8 Mbps of average
traffic; 5 MiB every 10 seconds is about 4.2 Mbps; and 10 MiB every 10 seconds
is about 8.4 Mbps. These rates are sustainable only if they remain below the
host upload, client download, disk, and staging limits. Tiny objects should be
batched because excessive object counts and metadata overhead can outweigh the
benefit of finer granularity.

An event journal could be even more current by recording individual block,
inventory, entity, and mod-state operations. It would need authoritative hooks
inside the server and relevant mods, crash-safe ordering, authentication, and a
periodic full checkpoint to compact the log. Network packets or filesystem
timestamps are not sufficient: they do not describe every server-side tick or
mod mutation, and replay may not be deterministic. This is an advanced future
option, not a safe generic snapshot mechanism.

For recovery, the newest **committed** manifest remains the source of truth.
Objects uploaded in the last few seconds can be marked `prepared` and prefetched
by clients, but they must not become authoritative until all required pieces
and related metadata have passed consistency and hash checks. This gives a
client a near-current cache without confusing an incomplete upload with a
recoverable world.

### Observed sizing reference

These are read-only measurements from the current machine on 2026-08-02. They
are references for capacity and transfer planning, not contracts for a future
catalog entry:

- Coco original, `%APPDATA%\.minecraft\saves\coco`: about 7.28 GiB.
- Distant Horizons databases inside that world: about 4.82 GiB.
- The same Coco original world excluding those Distant Horizons databases: about
  2.46 GiB, still including other world files and caches that require an audit.
- First managed Backrooms world, `New World`: about 174 MiB.

The Distant Horizons databases are visual caches, not automatically disposable
files. A future snapshot policy may exclude them after testing that they can be
regenerated; doing so would reduce transfer size but could make the first visual
load slower. No current world was changed or cleaned during this measurement.

### The real obstacle: the evolving world

Coco already synchronizes the reproducible parts of an experience—mods,
configuration, resource packs, shaders, runtime, and launcher metadata. It
deliberately does **not** replace or merge `saves`, `playerdata`, advancements,
statistics, or other live-world state. Those files are different from the pack
and change continuously.

Consequently, a friend can host the same *pack* today, but cannot safely host the
latest *world* merely because their installation is otherwise identical. A
roving-host design needs one explicit world-authority model:

| Model | Feasibility | Main tradeoff |
| --- | --- | --- |
| Dedicated server on a stable machine | Best for a genuinely long-lived world | It removes the need for host election; someone still has to operate the server machine |
| Graceful snapshot handoff | Feasible future MVP | The current host must close cleanly; the world is transferred and players experience downtime |
| Continuous live replication | Not an initial target | Minecraft region files, player data, mod state, and crashes make conflict-free replication very difficult |

The most realistic “anyone can host” version is graceful handoff. The current
host performs a normal save and shutdown, creates a versioned, checksummed world
bundle, and the next host restores it only while Minecraft is closed. The bundle
must include the complete authoritative save state, not just terrain. It needs
authenticated transfer, retention of the previous good snapshot, resumable
downloads, and a clear policy for progress made after the last checkpoint.

An abrupt crash would not provide seamless failover. The next host could recover
the last complete snapshot, with an explicitly documented possible loss of recent
progress. Copying a live `saves` directory while Minecraft is running would be
unsafe and would violate the current world-preservation rules.

### Other requirements

- Every potential host needs the exact same client and host-capable runtime, or a
  safe, verified promotion step before it can win the lease.
- The future catalog entry needs a capability such as `roving-lan` and a world
  identity/generation, rather than reusing the current fixed-host fields.
- Discovery must advertise a dynamic ZeroTier address and validate the pack hash,
  runtime, session ID, lease, and world generation.
- The network must pre-authorize trusted devices or provide a safe enrollment
  flow. Friends need ZeroTier membership, not controller-admin access.
- Windows firewall rules must be temporary or tightly scoped to the ZeroTier
  subnet for TCP 25565 and, where applicable, UDP voice traffic.
- Offline usernames are not authentication. A future long-lived world should
  use a trusted-player roster/whitelist and authenticated session messages so a
  network member cannot impersonate another player or seize the lease.
- A host eligibility policy may be needed: minimum memory/CPU, power state,
  connection quality, and an opt-in “available to host” setting. Otherwise the
  first laptop opened may become the worst possible server.
- Host migration must handle voice chat, automatic reconnect, player identity,
  backups, world-locking, and the case where the old host disappears without
  releasing the lease.

### Holes to close before implementation

The following failure modes need explicit answers before this becomes a real
feature:

| Hole | Why it matters | Required rule or decision |
| --- | --- | --- |
| The final snapshot exists only on the departing host | The next host cannot download a file from a powered-off computer | The host must replicate a complete checkpoint to at least one other peer, or to always-on storage, and wait for an acknowledgement before it may shut down |
| No clients are online during the final save | Peer replication has nowhere to send the newest state | Keep an always-on backup, or accept that failover can only restore the last already-replicated checkpoint |
| Split-brain after a network partition | The old host may still be running when a new host believes its lease expired | Require fencing or a conservative manual takeover; a timeout by itself is unsafe |
| The rendezvous/lease service is offline | Nobody can safely decide who owns the world or discover the current host | Separate the coordination service from the Minecraft host and define degraded behavior |
| A ZeroTier address or endpoint changes | Clients may connect to a stale address | Advertise the current address in an authenticated session record and never use a fixed host IP for a roving experience |
| A weak or unwilling machine wins | “First” may select a laptop with poor CPU, RAM, battery, disk, or upload | Validate minimum resources and offer an opt-out/eligibility policy before lease acquisition |
| Pack or runtime drift | A different mod, loader, Java, config, or server adapter can corrupt or reject the world | Pin pack/runtime identity to the world generation and block hosting until exact validation passes |
| A mod stores state outside `saves` | The transferred world may appear valid while silently losing progression or server state | Audit each mod and declare every authoritative file path, including external databases and server configs |
| Snapshot is copied while files are changing | The bundle may contain a mixture of different moments and be corrupt | Create a coordinated, immutable checkpoint; never mirror the live save directory directly |
| Transfer ends halfway or storage is damaged | A bad copy can become the next authority | Use manifests, hashes, resumable transfer, temporary staging, atomic promotion, and retain the previous good generation |
| Host exits while players are connected | Integrated LAN stops immediately and clients may reconnect to an old session | Treat handoff as a visible disconnect/reconnect operation with a session ID and generation check |
| Offline names are not authentication | A trusted ZeroTier member could impersonate a player or claim the lease | Use a trusted-player roster and authenticated lease/session messages; do not rely on `online-mode=false` names |
| Background sync harms gameplay | Snapshot compression, disk reads, and fan-out uploads can cause lag or saturate the host | Throttle by bandwidth, CPU, disk, and latency; pause prefetch when the session is unhealthy |
| Snapshot storage grows forever | Repeated worlds and deltas can fill every player's disk | Define retention, quotas, garbage collection, and at least one recoverable backup generation |
| A pack update arrives mid-world | One host may migrate the world while another still has the old runtime | Freeze the world to a pack version during a session and require a deliberate, backed-up world upgrade |
| Multiple experiences share the same network | A session or file could be delivered to the wrong pack/world | Namespace leases and snapshots by experience, world identity, pack hash, and generation |
| Cloudflare or the account is unavailable | The coordinator or durable snapshot store may be unreachable even though players' PCs are healthy | Keep a degraded local checkpoint, define no-election behavior, and maintain an independently recoverable export |
| A presigned URL or API credential leaks | A third party could read, replace, or delete private world objects | Use short-lived, path-scoped access, client-side authentication/encryption, and never log bearer URLs |
| Mutable objects are cached or overwritten | A client may receive an old manifest or mixed generations | Use immutable generation/hash keys and publish a small final commit record only after all parts verify |
| Garbage collection races with a download | Cleanup may remove a shared object still needed by a live client or snapshot | Mark-and-sweep from retained manifests with a grace period and download leases |
| No one tests a real restore | Upload success does not prove that the world can be reconstructed | Periodically restore on a clean instance and reach a real menu/world before trusting the backup |
| Staging needs more disk than expected | A host may run out of space while creating or promoting a checkpoint | Reserve and validate temporary space before starting the snapshot |

### Provisional conclusion

The idea is technically plausible and not crazy. ZeroTier can provide the
private transport for multiple possible hosts; it is not the fundamental
blocker. The hard part is making one world authoritative and transferring it
without corruption or split-brain ownership.

The likely future shape is either:

1. a proper dedicated server for the long-lived world; or
2. an opt-in `roving-lan` experience with a lease service, host-capable installs,
   graceful snapshot handoff, visible reconnect downtime, and limited crash
   recovery.

The idea should remain theoretical until the world model, lease authority,
authentication, and failure behavior are agreed upon. No current experience
should be converted just to test the concept.

### External reference

- [ZeroTier networks and member authorization](https://docs.zerotier.com/networks/)
- [ZeroTier protocol and per-device identities](https://docs.zerotier.com/protocol/)
- [Cloudflare Durable Objects](https://developers.cloudflare.com/durable-objects/)
- [Cloudflare Durable Object alarms](https://developers.cloudflare.com/durable-objects/api/alarms/)
- [Cloudflare R2 uploads and multipart objects](https://developers.cloudflare.com/r2/objects/upload-objects/)
- [Cloudflare R2 consistency and caching](https://developers.cloudflare.com/r2/reference/consistency/)
- [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/)
