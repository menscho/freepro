# Transport reliability review

Reviewed on 2026-09-05. This review covers transport health and diagnostics. A public proxy passing a check does not establish model quota, sustained throughput, or future availability.

| Repository | Relevant observation | Decision for freepro |
| --- | --- | --- |
| [jhao104/proxy_pool](https://github.com/jhao104/proxy_pool) | Separates scheduled collection, validation of stored proxies, and API access. | Keep validation off the request path; correct health-result accounting rather than deleting routes based on misleading counters. |
| [1837620622/proxypool](https://github.com/1837620622/proxypool/blob/main/server.js) | Tracks checking progress and the last check time; persists checker results. | Diagnostics should distinguish a checker result from a real request result. No server code or persistence subsystem imported. |
| [fog-forest/free-proxy-pool](https://github.com/fog-forest/free-proxy-pool) | Provides scheduled collection and multithreaded validation with JSON output. | Those basic mechanisms already exist locally. Another collection loop would not fix stale feedback races. |
| [monosans/proxy-list](https://github.com/monosans/proxy-list) | Describes complete-response checks and separate response-time and exit-IP metadata. | A probe duration measures that probe, not model generation time. Already an existing source; no duplicate source added. |
| [proxifly/free-proxy-list](https://github.com/proxifly/free-proxy-list) | Publishes periodically checked lists in several formats. | Already an existing source. Periodic publication is not evidence that every listed route is currently usable. |
| [CelestialBrain/worldpool](https://github.com/CelestialBrain/worldpool) | Documents collection, validation, and merge stages with bounded checks and several health signals. | Separate observations from guarantees. No distributed fleet, target-access probes, or expanded source lists imported. |

## Bugs corrected

- A pending neutral check could finish after a real request and mutate newer health state. Leases, request feedback, cooldown changes, and insertion now advance a health revision. A stale probe is discarded, including after removal and reinsertion of the same endpoint.
- Neutral retirement used a score shared with transport failures, while the log called it consecutive probe failures. An independent streak now counts accepted failed neutral checks and resets after an accepted neutral success or successful request transport. Existing transport scores and cooldowns still apply.
- The earlier probe regression held a live lease while injecting failures, so those failures were ignored. It now exercises actual idle checks and recovery.

## Reading a stalled request

Logs use a process-local request ID, such as `[r42]`, and an attempt number, such as `[r42 a2]`. Match that ID across acceptance, retries, transport failures, and the final request line. Response-header and transport-failure lines include elapsed time in that phase. Malformed inbound HTTP logs its parser/read error separately and states that no upstream request was sent; request bodies and credentials are not logged.

The default total upstream budget remains 120 seconds. Existing phase caps can allow 60 seconds waiting for response headers, plus other phases and retries within the total budget. An interval with no completed request is not by itself evidence that the local listener stopped. Shortening the budget would change which slow model requests are allowed to finish.

The regression suite uses local fixtures. It establishes stale-feedback safety, counter behavior, correlation, and bounded transport recovery. It does not measure public-proxy lifetime or demonstrate 100 real coding agents running continuously. Provider quotas and required capacity must be addressed through authorized service capacity, rather than IP rotation around rate limits.
