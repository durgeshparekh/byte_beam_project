# Feature documentation

One document per feature that exists in the code. [ARCHITECTURE.md](../ARCHITECTURE.md)
covers the system: the event-log model, the offline-first ownership split, the
ingest contract, the scale plan, and the ambiguity table. These documents cover
what was actually built and why it looks the way it does.

| # | Feature | Brief | Status |
|---|---------|-------|--------|
| 01 | [Telemetry ingest](01-telemetry-ingest.md) | §2 local-first over DuckDB | Built |
| 02 | [Fleet home](02-fleet-home.md) | §3 A | Built |
| 03 | [Vehicle detail](03-vehicle-detail.md) | §3 B | Built |
| — | Alerts, dismissal, undo | §3 C | Not built |
| — | Geofences | §3 D | Not built |
| — | Automatic trips | §3 E | Not built |
| — | Scale exercise | §4 | Not built |

Every document follows the same shape: what it does, the files, the data flow,
the mechanics, the decisions with their rejected alternatives, the tests that
pin each claim, and what is knowingly left undone.

## Conventions used throughout

**Clean architecture per feature.** `domain` holds entities, repository
interfaces and use cases and imports nothing outward. `data` holds models, data
sources and repository implementations. `presentation` holds a GetX controller,
a binding and widgets. The concrete classes are named in exactly one place per
feature — its `Bindings`.

**GetX for state and injection.** Controllers receive use cases through their
constructors rather than calling `Get.find` internally, so every controller is
directly constructible in a unit test with fakes.

**Event time, never arrival time.** Every rule in the app compares `event_ts`
— when the vehicle measured something — against an injected clock. `ingest_ts`
exists for audit and drives nothing.

**Failures, not exceptions, above the data layer.** Data sources throw
`LocalDatabaseException`; repositories catch it and return `Err(Failure)`.
Nothing in `domain` or `presentation` catches anything.
