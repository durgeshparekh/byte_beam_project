# Git log

```
commit 3375e32920decd2214135505598a9d444a116f78
Author: Durgesh Parekh <durgeshparekh381@gmail.com>
Date:   2026-09-13 10:38:01 +0530

    feat: initialize project structure and implement fleet, vehicle detail, and telemetry ingest features

 .gitignore                                         |  108 +
 .metadata                                          |   33 +
 ARCHITECTURE.md                                    |  463 ++
 README.md                                          |   95 +
 ai-logs/2026-09-12-48c1003e.md                     | 1954 ++++++++
 ai-logs/2026-09-12-9b44d578.md                     | 4926 ++++++++++++++++++++
 analysis_options.yaml                              |    1 +
 android/.gitignore                                 |   14 +
 android/app/build.gradle.kts                       |   44 +
 android/app/src/debug/AndroidManifest.xml          |    7 +
 android/app/src/main/AndroidManifest.xml           |   45 +
 .../com/bytebeam/byte_beam_project/MainActivity.kt |    5 +
 .../main/res/drawable-v21/launch_background.xml    |   12 +
 .../src/main/res/drawable/launch_background.xml    |   12 +
 .../app/src/main/res/mipmap-hdpi/ic_launcher.png   |  Bin 0 -> 544 bytes
 .../app/src/main/res/mipmap-mdpi/ic_launcher.png   |  Bin 0 -> 442 bytes
 .../app/src/main/res/mipmap-xhdpi/ic_launcher.png  |  Bin 0 -> 721 bytes
 .../app/src/main/res/mipmap-xxhdpi/ic_launcher.png |  Bin 0 -> 1031 bytes
 .../src/main/res/mipmap-xxxhdpi/ic_launcher.png    |  Bin 0 -> 1443 bytes
 android/app/src/main/res/values-night/styles.xml   |   18 +
 android/app/src/main/res/values/styles.xml         |   18 +
 android/app/src/profile/AndroidManifest.xml        |    7 +
 android/build.gradle.kts                           |   24 +
 android/gradle.properties                          |    3 +
 android/gradle/wrapper/gradle-wrapper.properties   |    5 +
 android/settings.gradle.kts                        |   26 +
 docs/01-telemetry-ingest.md                        |  160 +
 docs/02-fleet-home.md                              |  145 +
 docs/03-vehicle-detail.md                          |  165 +
 docs/README.md                                     |   40 +
 lib/core/db/database_pulse.dart                    |   19 +
 lib/core/error/exceptions.dart                     |   25 +
 lib/core/error/failures.dart                       |   21 +
 lib/core/usecases/usecase.dart                     |   22 +
 lib/core/utils/clock.dart                          |   32 +
 lib/core/utils/result.dart                         |   35 +
 lib/db/fleet_db.dart                               |   78 +
 lib/db/schema.dart                                 |  121 +
 lib/db/vehicle_status_sql.dart                     |  117 +
 .../data/datasources/fleet_local_data_source.dart  |  103 +
 .../data/models/fleet_vehicle_summary_model.dart   |   35 +
 .../data/repositories/fleet_repository_impl.dart   |   27 +
 .../fleet/domain/entities/fleet_filter.dart        |   32 +
 .../fleet/domain/entities/fleet_overview.dart      |   40 +
 .../domain/entities/fleet_vehicle_summary.dart     |   47 +
 .../fleet/domain/entities/vehicle_status.dart      |   64 +
 .../domain/repositories/fleet_repository.dart      |   12 +
 .../fleet/domain/usecases/get_fleet_overview.dart  |   26 +
 .../fleet/presentation/bindings/fleet_binding.dart |   41 +
 .../presentation/controllers/fleet_controller.dart |   75 +
 .../fleet/presentation/pages/fleet_page.dart       |   74 +
 .../presentation/widgets/fleet_empty_state.dart    |   63 +
 .../presentation/widgets/fleet_filter_bar.dart     |   41 +
 .../fleet/presentation/widgets/status_chip.dart    |   84 +
 .../fleet/presentation/widgets/vehicle_tile.dart   |   45 +
 .../data/datasources/simulated_packet_source.dart  |  342 ++
 .../data/datasources/simulator_config.dart         |   46 +
 .../datasources/telemetry_local_data_source.dart   |   88 +
 .../data/datasources/telemetry_packet_source.dart  |   20 +
 .../data/datasources/telemetry_writer_isolate.dart |  432 ++
 .../data/models/telemetry_packet_model.dart        |   58 +
 .../repositories/telemetry_repository_impl.dart    |   65 +
 .../domain/entities/fleet_vehicle.dart             |   15 +
 .../domain/entities/ingest_receipt.dart            |   60 +
 .../domain/entities/ingest_snapshot.dart           |   32 +
 .../domain/entities/telemetry_packet.dart          |   55 +
 .../domain/repositories/telemetry_repository.dart  |   30 +
 .../domain/usecases/get_ingest_snapshot.dart       |   18 +
 .../domain/usecases/ingest_packet_batch.dart       |   25 +
 .../domain/usecases/observe_telemetry.dart         |   18 +
 .../domain/usecases/seed_fleet.dart                |   20 +
 .../presentation/bindings/ingest_binding.dart      |   74 +
 .../controllers/ingest_controller.dart             |  144 +
 .../presentation/pages/ingest_page.dart            |  129 +
 .../vehicle_detail_local_data_source.dart          |  202 +
 .../data/models/signal_reading_row_model.dart      |   28 +
 .../vehicle_detail_repository_impl.dart            |   22 +
 .../domain/entities/reading_verdict.dart           |   32 +
 .../domain/entities/signal_reading_row.dart        |   42 +
 .../domain/entities/soc_history.dart               |   49 +
 .../domain/entities/vehicle_detail.dart            |   35 +
 .../repositories/vehicle_detail_repository.dart    |   12 +
 .../domain/usecases/get_vehicle_detail.dart        |   27 +
 .../bindings/vehicle_detail_binding.dart           |   38 +
 .../controllers/vehicle_detail_controller.dart     |   94 +
 .../presentation/pages/vehicle_detail_page.dart    |  162 +
 .../presentation/widgets/reading_row_tile.dart     |   87 +
 .../presentation/widgets/soc_sparkline.dart        |  121 +
 .../presentation/widgets/verdict_pill.dart         |   47 +
 lib/main.dart                                      |   54 +
 macos/.gitignore                                   |    7 +
 macos/Flutter/Flutter-Debug.xcconfig               |    2 +
 macos/Flutter/Flutter-Release.xcconfig             |    2 +
 macos/Flutter/GeneratedPluginRegistrant.swift      |   14 +
 macos/Podfile                                      |   42 +
 macos/Podfile.lock                                 |   29 +
 macos/Runner.xcodeproj/project.pbxproj             |  801 ++++
 .../xcshareddata/IDEWorkspaceChecks.plist          |    8 +
 .../xcshareddata/xcschemes/Runner.xcscheme         |   99 +
 macos/Runner.xcworkspace/contents.xcworkspacedata  |   10 +
 .../xcshareddata/IDEWorkspaceChecks.plist          |    8 +
 macos/Runner/AppDelegate.swift                     |   13 +
 .../AppIcon.appiconset/Contents.json               |   68 +
 .../AppIcon.appiconset/app_icon_1024.png           |  Bin 0 -> 102994 bytes
 .../AppIcon.appiconset/app_icon_128.png            |  Bin 0 -> 5680 bytes
 .../AppIcon.appiconset/app_icon_16.png             |  Bin 0 -> 520 bytes
 .../AppIcon.appiconset/app_icon_256.png            |  Bin 0 -> 14142 bytes
 .../AppIcon.appiconset/app_icon_32.png             |  Bin 0 -> 1066 bytes
 .../AppIcon.appiconset/app_icon_512.png            |  Bin 0 -> 36406 bytes
 .../AppIcon.appiconset/app_icon_64.png             |  Bin 0 -> 2218 bytes
 macos/Runner/Base.lproj/MainMenu.xib               |  343 ++
 macos/Runner/Configs/AppInfo.xcconfig              |   14 +
 macos/Runner/Configs/Debug.xcconfig                |    2 +
 macos/Runner/Configs/Release.xcconfig              |    2 +
 macos/Runner/Configs/Warnings.xcconfig             |   13 +
 macos/Runner/DebugProfile.entitlements             |   12 +
 macos/Runner/Info.plist                            |   32 +
 macos/Runner/MainFlutterWindow.swift               |   15 +
 macos/Runner/Release.entitlements                  |    8 +
 macos/RunnerTests/RunnerTests.swift                |   12 +
 pubspec.lock                                       |  413 ++
 pubspec.yaml                                       |   23 +
 test/db/duckdb_features_test.dart                  |  124 +
 test/db/fleet_db_test.dart                         |   81 +
 test/duckdb_support.dart                           |   23 +
 test/features/fleet/fleet_controller_test.dart     |  132 +
 test/features/fleet/fleet_end_to_end_test.dart     |  168 +
 test/features/fleet/fleet_page_test.dart           |  183 +
 test/features/fleet/fleet_query_test.dart          |  307 ++
 .../telemetry_ingest/ingest_binding_test.dart      |   69 +
 .../telemetry_ingest/ingest_controller_test.dart   |  205 +
 .../telemetry_ingest/ingest_pipeline_test.dart     |  229 +
 .../simulated_packet_source_test.dart              |  125 +
 .../vehicle_detail_controller_test.dart            |  145 +
 .../vehicle_detail/vehicle_detail_page_test.dart   |  239 +
 .../vehicle_detail/vehicle_detail_query_test.dart  |  220 +
 tool/export_ai_logs.sh                             |   95 +
 tool/fetch_duckdb_lib.sh                           |   18 +
 138 files changed, 16687 insertions(+)

commit 1099e7e0abc68ce3ea904c9f21f855ba76f60dec
Author: Durgesh Parekh <durgeshparekh381@gmail.com>
Date:   2026-09-13 11:14:23 +0530

    feat: implement alerts feature with local-first data layer, domain logic, presentation UI, and tests

 ARCHITECTURE.md                                    |   61 +-
 README.md                                          |   12 +-
 ai-logs/2026-09-12-9b44d578.md                     | 3821 ++++++++++++++++++++
 docs/04-alerts.md                                  |  296 ++
 docs/README.md                                     |    2 +-
 lib/core/utils/format_age.dart                     |   14 +
 lib/db/alert_sql.dart                              |  277 ++
 lib/db/vehicle_status_sql.dart                     |   66 +-
 .../data/datasources/alert_local_data_source.dart  |   67 +
 lib/features/alerts/data/models/alert_model.dart   |   38 +
 .../data/repositories/alert_repository_impl.dart   |   47 +
 .../alerts/domain/entities/fleet_alert.dart        |  119 +
 .../domain/repositories/alert_repository.dart      |   23 +
 .../alerts/domain/usecases/dismiss_alert.dart      |   36 +
 .../alerts/domain/usecases/get_open_alerts.dart    |   19 +
 .../alerts/domain/usecases/undo_dismissal.dart     |   19 +
 .../presentation/bindings/alerts_binding.dart      |   47 +
 .../controllers/alerts_controller.dart             |  130 +
 .../alerts/presentation/pages/alerts_page.dart     |  114 +
 .../alerts/presentation/widgets/alert_card.dart    |  125 +
 .../presentation/widgets/dismiss_reason_sheet.dart |   86 +
 .../fleet/presentation/pages/fleet_page.dart       |   33 +
 .../datasources/telemetry_local_data_source.dart   |   21 +-
 .../data/datasources/telemetry_writer_isolate.dart |  110 +-
 .../repositories/telemetry_repository_impl.dart    |   12 +-
 .../presentation/bindings/ingest_binding.dart      |    6 +-
 .../presentation/pages/vehicle_detail_page.dart    |   41 +
 .../presentation/widgets/reading_row_tile.dart     |    9 +-
 lib/main.dart                                      |    3 +
 test/features/alerts/alert_controller_test.dart    |  136 +
 test/features/alerts/alert_doubles.dart            |   99 +
 test/features/alerts/alert_evaluator_test.dart     |  346 ++
 test/features/alerts/alert_page_test.dart          |  182 +
 test/features/alerts/alert_store_test.dart         |  199 +
 test/features/fleet/fleet_end_to_end_test.dart     |   38 +-
 test/features/fleet/fleet_page_test.dart           |   43 +-
 test/features/fleet/fleet_query_test.dart          |   69 +-
 .../telemetry_ingest/ingest_pipeline_test.dart     |   28 +-
 .../vehicle_detail/vehicle_detail_page_test.dart   |   43 +-
 39 files changed, 6720 insertions(+), 117 deletions(-)

commit 2757aed4509db2876b519d6e0e211b854a196d32
Author: Durgesh Parekh <durgeshparekh381@gmail.com>
Date:   2026-09-13 11:44:48 +0530

    feat: implement geofence feature with circular zone management and SQL-based crossing detection

 ARCHITECTURE.md                                    |   17 +-
 README.md                                          |   12 +-
 ai-logs/2026-09-12-9b44d578.md                     | 1465 ++++++++++++++++++++
 docs/05-geofences.md                               |  222 +++
 docs/README.md                                     |    2 +-
 lib/db/alert_sql.dart                              |   26 +-
 lib/db/fleet_db.dart                               |   19 +
 lib/db/geofence_sql.dart                           |  337 +++++
 lib/db/schema.dart                                 |   50 +-
 .../fleet/presentation/pages/fleet_page.dart       |    6 +
 .../datasources/geofence_local_data_source.dart    |   71 +
 .../geofence/data/models/geofence_model.dart       |   39 +
 .../repositories/geofence_repository_impl.dart     |   51 +
 .../geofence/domain/entities/geofence.dart         |   84 ++
 .../domain/repositories/geofence_repository.dart   |   21 +
 .../geofence/domain/usecases/get_geofences.dart    |   15 +
 .../geofence/domain/usecases/save_geofence.dart    |   26 +
 .../domain/usecases/set_geofence_active.dart       |   31 +
 .../presentation/bindings/geofence_binding.dart    |   47 +
 .../controllers/geofence_controller.dart           |  128 ++
 .../presentation/pages/geofence_editor_page.dart   |  134 ++
 .../presentation/pages/geofences_page.dart         |  111 ++
 .../presentation/widgets/geofence_tile.dart        |  102 ++
 .../geofence/presentation/widgets/zone_panel.dart  |  111 ++
 .../data/datasources/simulated_packet_source.dart  |   10 +-
 .../data/datasources/simulator_config.dart         |   19 +
 .../data/datasources/telemetry_writer_isolate.dart |   75 +-
 .../vehicle_detail_local_data_source.dart          |   36 +
 .../domain/entities/vehicle_detail.dart            |   15 +
 .../presentation/pages/vehicle_detail_page.dart    |   10 +
 lib/main.dart                                      |    2 +
 test/db/fleet_db_test.dart                         |    9 +-
 test/features/alerts/alert_evaluator_test.dart     |    6 +-
 .../geofence/geofence_controller_test.dart         |   94 ++
 test/features/geofence/geofence_detector_test.dart |  408 ++++++
 test/features/geofence/geofence_doubles.dart       |   92 ++
 .../geofence/geofence_end_to_end_test.dart         |  147 ++
 test/features/geofence/geofence_page_test.dart     |  211 +++
 test/features/geofence/geofence_store_test.dart    |  269 ++++
 .../vehicle_detail_controller_test.dart            |    1 +
 .../vehicle_detail/vehicle_detail_page_test.dart   |   70 +
 41 files changed, 4561 insertions(+), 40 deletions(-)

commit d3cf12f97f780b8f67535dcf8121cd0948bc7bd3
Author: Durgesh Parekh <durgeshparekh381@gmail.com>
Date:   2026-09-13 23:38:23 +0530

    feat: implement trips feature and scale performance benchmarking tools

 ARCHITECTURE.md                                    |   21 +-
 README.md                                          |   78 +-
 ai-logs/2026-09-12-9b44d578.md                     | 9771 ++++++++++++++++++++
 docs/06-trips.md                                   |  171 +
 docs/07-scale.md                                   |  243 +
 docs/README.md                                     |    4 +-
 docs/data/fleet-query-bench-macos.csv              |  101 +
 lib/core/utils/cold_start.dart                     |   38 +
 lib/db/backfill_sql.dart                           |  173 +
 lib/db/retention_sql.dart                          |  174 +
 lib/db/schema.dart                                 |   29 +-
 lib/db/trip_sql.dart                               |  209 +
 lib/db/vehicle_status_sql.dart                     |   17 +
 .../data/datasources/fleet_local_data_source.dart  |   14 +-
 .../fleet/presentation/pages/fleet_page.dart       |   29 +
 .../presentation/controllers/scale_controller.dart |  248 +
 .../scale/presentation/pages/scale_page.dart       |  160 +
 .../data/datasources/telemetry_writer_isolate.dart |  167 +-
 .../presentation/bindings/ingest_binding.dart      |   15 +
 .../presentation/pages/ingest_page.dart            |    6 +
 .../data/datasources/trip_local_data_source.dart   |   49 +
 lib/features/trips/data/models/trip_model.dart     |   32 +
 .../data/repositories/trip_repository_impl.dart    |   34 +
 lib/features/trips/domain/entities/trip.dart       |   51 +
 .../trips/domain/repositories/trip_repository.dart |   13 +
 .../trips/domain/usecases/get_recent_trips.dart    |   23 +
 .../trips/presentation/bindings/trips_binding.dart |   41 +
 .../presentation/controllers/trips_controller.dart |   70 +
 .../trips/presentation/pages/trips_page.dart       |   58 +
 .../trips/presentation/widgets/trip_tile.dart      |   90 +
 .../vehicle_detail_local_data_source.dart          |   19 +
 .../domain/entities/vehicle_detail.dart            |    9 +
 .../presentation/pages/vehicle_detail_page.dart    |   16 +
 lib/main.dart                                      |    4 +
 test/features/scale/backfill_test.dart             |  124 +
 test/features/scale/retention_test.dart            |  139 +
 test/features/trips/trip_controller_test.dart      |   54 +
 test/features/trips/trip_derivation_test.dart      |  256 +
 test/features/trips/trip_doubles.dart              |   82 +
 test/features/trips/trip_page_test.dart            |   60 +
 test/features/trips/trip_store_test.dart           |  147 +
 .../vehicle_detail_controller_test.dart            |    1 +
 .../vehicle_detail/vehicle_detail_page_test.dart   |   36 +
 43 files changed, 13046 insertions(+), 30 deletions(-)

commit 1d5ed5787398394d6ece9dc22b7ef4dc1b2b85bb
Author: Durgesh Parekh <durgeshparekh381@gmail.com>
Date:   2026-09-14 08:02:08 +0530

    refactor: remove unused forVehicle trip methods and add Terabyte unit support for database size parsing

 lib/db/retention_sql.dart                          | 28 +++++++++++++++-------
 .../presentation/controllers/scale_controller.dart | 16 ++++++-------
 .../scale/presentation/pages/scale_page.dart       |  4 ++--
 .../data/datasources/trip_local_data_source.dart   | 19 ---------------
 .../data/repositories/trip_repository_impl.dart    | 12 ----------
 .../trips/domain/repositories/trip_repository.dart |  7 +++---
 .../trips/presentation/widgets/trip_tile.dart      |  5 +++-
 test/features/trips/trip_doubles.dart              |  9 -------
 test/features/trips/trip_store_test.dart           | 13 ++++++----
 9 files changed, 47 insertions(+), 66 deletions(-)

commit 1667c1e5c3a0169fca716b8fbc7e6ad196ee1bed
Author: Durgesh Parekh <durgeshparekh381@gmail.com>
Date:   2026-09-14 10:46:19 +0530

    feat: drop and track orphan telemetry rows during ingest

 lib/db/schema.dart                                 | 14 ++++++++
 .../data/datasources/telemetry_writer_isolate.dart | 24 +++++++++++++
 .../data/models/telemetry_packet_model.dart        |  1 +
 .../domain/entities/ingest_receipt.dart            |  8 ++++-
 .../controllers/ingest_controller.dart             |  2 ++
 .../presentation/pages/ingest_page.dart            |  1 +
 .../telemetry_ingest/ingest_controller_test.dart   |  4 +++
 .../telemetry_ingest/ingest_pipeline_test.dart     | 39 +++++++++++++++++++---
 8 files changed, 88 insertions(+), 5 deletions(-)

commit b43906e70d115dd98bc79d664d9343323ee8e709
Author: Durgesh Parekh <durgeshparekh381@gmail.com>
Date:   2026-09-14 10:49:54 +0530

    docs: update README with run instructions and scale exercise details

 ai-logs/2026-09-12-9b44d578.md | 16071 +++++++++++++++++++++++++++++++++++++++
 1 file changed, 16071 insertions(+)

commit 00750021e122a9a1b3da91d609d1859b84342cea
Author: Durgesh Parekh <durgeshparekh381@gmail.com>
Date:   2026-09-14 10:56:09 +0530

    chore: add SHA-256 verification and secure protocol options to DuckDB library fetch script

 README.md                      |   3 +-
 ai-logs/2026-09-12-9b44d578.md | 993 +++++++++++++++++++++++++++++++++++++++++
 ai-logs/git-log.md             | 338 ++++++++++++++
 tool/export_ai_logs.sh         |  41 +-
 tool/fetch_duckdb_lib.sh       |  36 +-
 5 files changed, 1401 insertions(+), 10 deletions(-)
```
