# 04 — Alerts, dismissal and undo

Threshold breaches raised as an alert lifecycle, shown on their own screen and
on the vehicle they belong to, dismissed with a reason, undoable for five
seconds.

Covers the brief's §3 C.

## Files

```
lib/db/alert_sql.dart      the lifecycle: condition, resolve, rescore, raise,
                           dismiss, restore — plus evaluateAlerts()
lib/features/alerts/
  domain/entities/         fleet_alert (+ alert_type · dismiss_reason)
  domain/repositories/     alert_repository
  domain/usecases/         get_open_alerts · dismiss_alert · undo_dismissal
  data/models/             alert_model
  data/datasources/        alert_local_data_source (interface + DuckDB impl)
  data/repositories/       alert_repository_impl
  presentation/            alerts_controller · alerts_binding · alerts_page
  presentation/widgets/    alert_card · dismiss_reason_sheet
```

The SQL lives in `lib/db/` beside the status ladder because it has three
callers in two features: the evaluator runs on the writer isolate (ingest), the
badge is read by the fleet query, and the list by the alerts screen.

## An alert is an episode, not a flag

The `alert` table stores *episodes*. One row is one continuous period during
which a rule was breached on a vehicle:

| Column | Meaning |
|---|---|
| `raised_at` | when the episode opened |
| `severity` | how bad it is **right now** — this moves |
| `escalated_at` | when it first went critical, kept even after it eases back |
| `severity` escalating | also clears `dismissed_at` — see below |
| `resolved_at` | when the condition cleared. Non-null ends the episode |
| `dismissed_at`, `dismiss_reason` | when a human waved it away, and what they said |

Open means `resolved_at IS NULL AND dismissed_at IS NULL` — one predicate,
`openAlertPredicate`, shared by the fleet badge and the list so they cannot
disagree about what "open" is.

This shape is what makes the brief's escalation rule fall out for free. SOC
18 % → 8 % is *the same row* turning critical, not a second alert; recovering
to 15 % walks the same row back down. Two alert types would have meant
suppressing one while the other is open, and a rule about which one wins.

## The evaluator

Four statements, in a fixed order, after every ingest batch — inside the same
transaction as the watermark, so derived state and the position it was derived
from commit together.

```
1. read     what we can currently see, fresh readings only   (staging table)
2. resolve  every open episode we watched come back inside
3. rescore  those still breached, escalating in place
4. raise    an episode for any breach that has none
```

The scratch table holds one row per (vehicle, alert type) **for which there is
a fresh reading**, and that row says one of three things:

| Row | Meaning | Effect |
|---|---|---|
| `severity` non-null | breached now | rescore or raise |
| `cleared` true | back inside by more than the band | resolve |
| neither | fresh, but inside the hysteresis band | left alone |
| *no row* | no fresh reading at all | left alone |

The condition set comes from `vehicle_signal_latest ⋈ signal_spec`, with each
reading nulled out if it is older than its own `max_age_sec`:

```sql
max(l.value) FILTER (
  WHERE l.signal = 'soc' AND l.event_ts >= $1 - to_seconds(s.soc_age)
) AS soc
```

That single `FILTER` is where "thresholds apply to fresh readings only" lives.
It is a property of the data the rules read, not a condition each rule
remembers to add.

**Resolve runs before raise.** A condition that clears and re-triggers inside
one batch closes the old episode and opens a new one, rather than silently
extending the old one across a gap.

**The pass is fleet-wide**, not limited to the vehicles in the batch: scoping
it to the batch would mean a vehicle whose reading has not moved never gets
re-examined. At 500 vehicles × 6 signals that is a few thousand rows.

**It is idempotent.** `raise` is guarded by `NOT EXISTS` over open episodes, so
running it twice on the same state raises nothing the second time. That is what
lets it run after every batch with no bookkeeping about what it has seen, and
it is what will let a replay of a late suffix work when geofences and trips
need one.

Alert ids are derived — `vehicle|type|epoch_ms(raised_at)` — not random, so a
replay produces the same row rather than a duplicate.

### An episode ends when we watch it end, not when we stop looking

This one was built backwards first, and the correction is the interesting part.

The first version resolved an alert whenever its reading went stale — reading
"thresholds apply to fresh readings only" as a rule about resolving as well as
raising. It is not. The brief scopes *firing*, and staleness is not recovery: a
truck that went flat at 5 % and then stopped reporting is exactly the truck you
want to still be told about. Auto-resolving deletes the only prompt to act, at
the moment it matters most.

So resolution needs **evidence**: a fresh reading that is back inside the
threshold. A quiet signal leaves the episode open, and the card carries the
caveat the readings register would — *no fresh reading for 20m · last known
5 %*. The cost, stated plainly: a vehicle that never reports again keeps its
alert forever. That is the same call as a trip whose vehicle never returns
(ARCHITECTURE.md §10, ambiguity 12), and the fleet list showing it OFFLINE is
the other half of the picture.

### The hysteresis band

Found by measurement rather than reasoning. A real simulator run — 40 trucks,
114 seconds — produced **seven `battery_overheat` episodes on one vehicle**,
because its temperature sat on 45 °C and wobbled across the line. Three of
eight (vehicle, type) pairs had more than one episode.

That is not resolution, it is flapping, and it makes the record useless: the
card reads "raised 2s ago" about a truck that has been hot for two minutes.

So resolution requires the value back inside by `alertClearBand` — 2 percentage
points of SOC, 2 degrees of temperature. **Severity inside an open episode has
no band**: the episode exists either way, so there are no rows to churn, and a
live readout should track the reading.

One constant rather than a `signal_spec` column, because the two signals happen
to want the same number in different units. The moment a third wants a
different one, it belongs in the table beside the thresholds it modifies.

### It does not need an idle timer

A consequence worth stating, because the first version did have one. Under
these rules nothing in the lifecycle — raise, escalate, de-escalate, resolve —
moves without a fresh reading. Time alone is not evidence. So the evaluator
runs exactly when data arrives and never on a schedule; the 30-second sweep
that the resolve-on-stale version needed was deleted along with the rule that
required it.

## Dismissal

The sheet offers three answers in the order the brief specifies, read straight
off `DismissReason.values` so the screen cannot drift from the enum:

> I am on it · Wrong alert · Something else…

"Something else…" ends in an ellipsis, and an ellipsis promises a follow-up, so
it opens a note field. Backing out of *that* cancels the whole dismissal — a
user who opened the text field and changed their mind did not mean "dismiss
with no reason". The note is stored with its code in one column, `other: the
charger is broken`; a second column would need a migration to hold something
the first already can.

**The dismissal is written to DuckDB before the UNDO appears.** It is not held
in memory for five seconds. Local-first means the database is the truth, and if
the app dies during those five seconds the user's explicit action should
survive rather than evaporate. The trade is the honest one: the alternative
loses a deliberate action to a crash.

UNDO is a five-second `SnackBar` that clears `dismissed_at` and
`dismiss_reason`. A failed dismissal shows the error and offers no UNDO —
there is nothing to undo.

**Escalation un-dismisses.** A warning dismissed at 18 % that reaches 8 %
clears `dismissed_at` and `dismiss_reason` on the same row. "I am on it" was an
answer to a question about a warning, and this is no longer that warning
(ARCHITECTURE.md §10, ambiguity 7).

**Resolution is independent of dismissal.** The evaluator clears an alert when
its condition clears whether or not someone dismissed it, and a dismissed alert
whose condition persists is *not* raised again. Dismissal suppresses the
episode; resolution ends it; only an ended episode can be raised again. So
"I am on it" hides it until the truck is actually charged, and then the next
time it goes flat you hear about it.

## Writes go through the single writer

DuckDB takes one writer, and the evaluator updates these very rows on every
tick. Dismissing from the UI's read connection would race it, and losing an
optimistic-concurrency conflict looks to the user like a button that did
nothing. So the alerts data source reads on the UI connection and writes
through `TelemetryWriter` — the process's single writer, which lives in the
ingest feature because that is where it was born, not because it is
ingest-specific.

## Where alerts appear

| Surface | What it shows |
|---|---|
| Fleet app bar | A badge with the **number of open alerts** — from this list, not from the fleet query, because one vehicle can have two. Red if anything is critical |
| Fleet list rows | The per-vehicle badge, now read from the `alert` table |
| Alerts screen | Every open alert, critical first then newest first, each with fault, registration, current reading, age and a Dismiss button |
| Vehicle detail | That vehicle's alerts above the readings register — filtered out of the list already in memory, so the two screens cannot disagree |

### The fleet badge changed

It used to recompute thresholds inside `scoredCte`. It now reads open,
undismissed alerts. The old version meant dismissing an alert left its red dot
on the fleet list, and it was a second implementation of the same rule waiting
to drift from the first. `vehicle_status_sql.dart` had a comment promising this
swap; this is it. The `spec` CTE and three pivoted columns went with it.

The cost is honest and documented: the badge is now derived state. It lags the
log by one derivation pass and can never lead it, which is the rule for every
class D table (ARCHITECTURE.md §3.4). In practice that is one tick.

## Decisions

| Decision | Why | Rejected |
|---|---|---|
| One escalating row, severity moves | The brief's rule, and it makes de-escalation free | Two alert types with a suppression rule between them |
| Evaluate fleet-wide every batch | A silent vehicle's alert must still age out | Evaluating only the vehicles in the batch |
| Idempotent raise via `NOT EXISTS` | Safe to run after every batch; ready for replay | A "last evaluated" cursor per vehicle |
| Resolve before raise | A gap must close one episode and open another | Raise first, extending across the gap |
| Resolution needs an observed fresh reading | Silence is not recovery; a truck that died at 5 % keeps its alert | Resolving on staleness — built first, then reversed |
| Hysteresis band on resolution only | Stops flapping without making severity lag the reading | Bare thresholds both ways (measured: 7 episodes in 114 s) |
| Escalation clears the dismissal | The user answered about a warning, not about this | Staying dismissed through escalation |
| Dismissal written immediately | A crash must not lose a deliberate action | Holding it in memory for the undo window |
| Undo clears the columns | Same row, same episode | A "undismissed" audit row |
| Resolution ignores dismissal | Dismissal hides an episode, it does not disable a rule | Dismissal resolving the alert |
| Writes via the ingest writer isolate | One writer; the evaluator touches these rows every tick | Writing from the UI connection with conflict retry |
| Badge reads the alert table | One rule, one place; dismissal actually hides the dot | Keeping the threshold `CASE` in `scoredCte` |
| Reason order read from the enum | The screen cannot drift from the specified order | Three hard-coded `ListTile`s |
| Note stored in the reason column | No migration for something the column can hold | A `dismiss_note` column |

## Tests

| Claim | Test |
|---|---|
| Warning at <20 %, critical at <10 %, overheat at >45 °C, nothing on a stale or healthy reading | `alert_evaluator_test.dart` |
| Two conditions on one vehicle are two alerts | same |
| Re-running on unchanged state changes nothing | same |
| 18 % → 8 % escalates the same row; 6 % → 15 % de-escalates in place and keeps `escalated_at` | same |
| Charging well clear resolves it; a reading going quiet does **not**; a returning condition opens a *new* episode | same |
| A reading wobbling back across the line stays in one episode; one clearly back inside resolves | same |
| A dismissed warning that goes critical un-dismisses itself | same |
| A reading inside the hysteresis band raises nothing | same |
| One condition clearing leaves the other open | same |
| A dismissed alert still resolves, is not re-raised while its condition persists, and comes back as a fresh episode after it clears and returns | same |
| The evaluator actually runs inside ingest, through the real writer isolate | `alert_store_test.dart` |
| A silent vehicle keeps its alert and is reported stale | same |
| Time passing on its own changes nothing | same |
| The list carries registration, reading, unit; critical sorts first; resolved and dismissed rows are hidden but not deleted | same |
| Dismissal and undo reach the disk through the single writer; a free-text reason is stored with its code | same |
| Badge counts alerts not vehicles; one critical colours it; `forVehicle` narrows | `alert_controller_test.dart` |
| A dismissal pulses the database so the fleet badge follows | same |
| A failed dismissal surfaces and changes nothing | same |
| The three reasons are offered in the specified order | same |
| The sheet renders them in that order; UNDO appears and lasts five seconds; UNDO restores | `alert_page_test.dart` |
| "Something else…" asks for a note; cancelling it cancels the dismissal; the note is stored | same |
| A failed dismissal offers no UNDO | same |
| The badge reflects the alert table, and a dismissed or resolved alert takes its badge with it | `fleet_query_test.dart` |
| An offline vehicle keeps the badge it was last known to need | `fleet_end_to_end_test.dart` |
| The app bar badges the open count; no alerts means no badge | `fleet_page_test.dart` |
| An alert whose signal has gone quiet says so on the card | `alert_page_test.dart` |
| A vehicle's own alerts appear above its register, and another vehicle's do not | `vehicle_detail_page_test.dart` |

## Known limits

* **Two alert types.** Both battery. Adding one means a row in the condition
  `UNION ALL` and a line in `alertSignalMap`; the lifecycle, the screen and the
  dismissal need no changes.
* **No alert history screen.** Resolved and dismissed episodes are kept
  forever and queryable, but nothing renders them. The data is there for it.
* **The register pill and the alert card can disagree inside the band.** A
  truck at 44.5 °C shows NORMAL on its readings register — the reading *is*
  inside its threshold — while its overheat card is still open, because the
  episode has not cleared the band yet. Both answers are right to different
  questions ("is this reading out of range" vs "is there an open episode"), but
  a green pill beside a red card reads as a bug. The card carries the number,
  so the user can see why. The fix is to give the register the episode rather
  than to give the pill a band; that is a vehicle-detail change, not an alerts
  one, and it is not made here.
* **An alert on a truck that never reports again is permanent.** Deliberate —
  see above — but nothing prunes it, so a decommissioned vehicle would need its
  roster row removed.
* **The clear band is one number for both signals.** Two points of SOC and two
  degrees of temperature happen to be sensible; a third signal would need it
  per-signal in `signal_spec`.
* **Dismissal is not yet in the sync outbox.** ARCHITECTURE.md §3 classes it as
  L — device-authored, push-on-sync — and there is no sync. The row carries
  everything an outbox would need.
* **No snooze.** "I am on it" hides the episode until it resolves, which is
  the closest thing; a timed re-raise would be a different feature.
