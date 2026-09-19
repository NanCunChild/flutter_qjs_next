1.5.0 (87a7363) vs 75f5289 (1.4.0 + version bump, before the jsCall guard 9634345)

Host: Linux x64, flutter_tester (debug), 22 processors. Both trees load the
same native library (FLUTTER_QJS_NEXT_LIBRARY); only the Dart code differs.
Everything ran back to back in one user systemd unit, old/new alternating.

*_BENCH_RUNS16_run{1,2}.txt  test/benchmark_test.dart --dart-define=BENCH_RUNS=16
*_jscall.txt                 jscall_benchmark.dart.txt: one engine, no dispatch(),
                             median of 5 reps (1 M / 500 k / 200 k calls per rep),
                             3 runs per tree. RSS is the process after each case.
*_web_module_cost.txt        web_module_cost.dart.txt: heap after construction and
                             median construction time over 200 engines.
soak_10min_summary.txt       soak_stress_test, pool 32 / workers 32, web=none,
                             600 s each; slope = least-squares fit after 300 s.
                             all_old = 75f5289, everything else = 87a7363.
