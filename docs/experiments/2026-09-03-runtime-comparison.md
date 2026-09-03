# Runtime comparison — 2026-09-03

## Question and method

This experiment compared pinned upstream llama.cpp, the Qwen-specific Metal
revision, and the locally composed hybrid runtime on the recorded Apple M5 Max.
`llama-bench` measured 512-token prompt processing and 128-token generation with
three repetitions at cache depths 0, 32,768, 131,072, and 250,000 where captured.

```text
llama-bench -m MODEL -ngl 999 -p 512 -n 128 -d DEPTH \
  -b 512 -ub 512 -r 3 -fa on -lm mmap -lzm on
```

The raw record labels these rows `three_run_mean`. Sample standard deviations
were not retained for this earlier comparison, so none are implied. The hybrid
rows were captured later after Metal shader caches had warmed. Prompt processing
is more sensitive than generation to cache and residency state; generation is
the safer branch-comparison signal.

## Result and interpretation

The exact table is generated from the
[raw JSON](../../results/raw/2026-09-03-qwen38-m5-max.json) into the
[summary](../../results/summaries/qwen3.8-flash-next-m5-max.md). At zero cache
depth, generation measured 37.03 tok/s upstream, 43.50 tok/s on the Qwen Metal
revision, and 51.21 tok/s on the hybrid. At cache depth 32,768, those values were
26.87, 35.30, and 43.60 tok/s. The Qwen Metal revision retained a larger measured
advantage at the captured long cache depths, but this single-machine result does
not establish universal scaling.

The upstream stable revision was
`de8656bd94f1163188125542534e4bcbc9f9fb1f`; the Qwen Metal source point was
`67d777b61c1169d9f7a8cf00f4abc1e731e6fa75`; and the tested hybrid was
`831e5d6f6e0d7b6c8d5757b1da41480ab33a0528`. The first is stable provenance;
the latter two represent experimental work in this study.
