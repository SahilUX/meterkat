# Future sync options

Status: exploration. No sync service is implemented or chosen.

The iPhone currently polls each paired companion directly. `SharedStore.clients` keeps the pairings and cached readings on that device, while `ClientMerge` combines results for the dashboard and widgets. Local and remote addresses are fallback routes to one companion. A second iPhone needs its own pairings, and an offline companion cannot send new readings.

## CloudKit

Use the user's [private CloudKit database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase) to sync client names, preferences, and cached readings across Apple devices on the same iCloud account. [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5) can manage record changes, but its automatic schedule is not immediate.

The Linux companion still needs a way to publish readings. A bridge through an Apple device is one route. A [CloudKit web integration](https://developer.apple.com/documentation/cloudkitjs) would need the user's authentication to write to their private database; a server-to-server key is for the public database. Decide how pairing tokens are protected before syncing them, since the current tokens grant access to a companion.

## Self-hosted service

Have each companion send usage snapshots and history to an always-on service. The iPhone reads the combined data from that service. Keep provider login credentials on each companion, and give the service separate, limited credentials for uploads and reads.

A small API with SQLite could store the latest result and bounded history per client and account. [Tailscale Serve](https://tailscale.com/docs/reference/examples/serve) could expose it privately over HTTPS. This works with both Mac and Linux companions, but the service needs updates, backups, and an availability plan. The phone should keep its local cache when the service is down.

## Questions to settle before building either option

- Should sync cover only readings and history, or also client names, preferences, and pairings?
- How will companions identify accounts for providers that do not currently report an account ID? Without one, two sign-ins cannot be separated reliably.
- How fresh must widgets and alerts be? [iOS schedules background refresh](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate) at its discretion, even when a server has newer data.
- What data retention, encryption, and authentication rules should apply to stored usage and pairing credentials?

For cross-platform reading sync, the self-hosted service is the more direct fit. CloudKit remains an option for Apple-device preferences and cached data. Neither option changes the current direct pairing until a sync design is chosen.
