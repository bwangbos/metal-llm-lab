#!/usr/bin/env python3
"""Audit a completed preset sweep and export portable evidence and a table."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics

from benchmark_presets import PROFILES, SAMPLES, targets, validate, save


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(run):
    experiment = json.loads((run / "experiment.json").read_text())
    records, cells, sessions = [], [], {}
    for profile, context in experiment["profiles"].items():
        for target in targets(context):
            samples = []
            for index in range(1, SAMPLES + 1):
                stem = f"{profile}-{target}-s{index}"
                record = json.loads((run / (stem + ".json")).read_text())
                response_path = run / (stem + "-response.json")
                response = json.loads(response_path.read_text())
                assert sha(response_path) == record["response_sha256"], stem
                assert validate(response, profile, target) == record["timings"], stem
                assert record["context"] == context and record["sample"] == index, stem
                assert record["profile"] == profile and record["prompt_tokens"] == target, stem
                assert hashlib.sha256(response.get("content", "").encode()).hexdigest() == record["output_sha256"], stem
                session = record["session"]
                if session not in sessions:
                    identity = json.loads((run / (session + "-identity.json")).read_text())
                    for key in ("pid", "process_started_at", "owner_token", "host", "port"):
                        identity.pop(key, None)
                    sessions[session] = dict(identity=identity, server_log_sha256=sha(run / (session + ".log")))
                samples.append(record)
            row = dict(profile=profile, allocation=context, effective_prompt_tokens=target,
                       samples=SAMPLES, selected_mtp=samples[0]["timings"].get("speculative", False))
            for label, key in (("prefill", "prompt_per_second"), ("generation", "predicted_per_second")):
                values = [s["timings"][key] for s in samples]
                row[label + "_mean"] = statistics.mean(values)
                row[label + "_sample_sd"] = statistics.stdev(values)
            cells.append(row)
            records.extend(samples)
    return dict(experiment=experiment, sessions=sessions, measurements=records, statistics=cells)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    evidence = collect(args.run_dir)
    extended = evidence["experiment"].get("extended", False)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    save(args.output_dir / "measurements.json", evidence)
    lines = ["# " + ("Extended fast/stable" if extended else "Preset") + " context sweep on Apple M5 Max 128 GB", "",
             "Vision on, text-only repeated-token prompts; one warm-up and three retained samples per cell.",
             "Each response generates 128 tokens. Ceiling prompts leave 256 tokens of space.",
             "Values are mean ± sample standard deviation in tokens/s. All retained responses passed count, truncation, and uncached-prefill checks. MTP routing was checked where exposed; stable's MTP-off configuration is recorded in its managed session identity.", "",
             "| Profile | Prompt tokens | Prefill tok/s | Generation tok/s | MTP selected |",
             "| --- | ---: | ---: | ---: | :---: |"]
    for row in evidence["statistics"]:
        label = row['profile'] + ("-equivalent (256K custom)" if extended else "")
        lines.append(f"| {label} | {row['effective_prompt_tokens']:,} | "
                     f"{row['prefill_mean']:.2f} ± {row['prefill_sample_sd']:.2f} | "
                     f"{row['generation_mean']:.2f} ± {row['generation_sample_sd']:.2f} | "
                     f"{'on' if row['selected_mtp'] else 'off'} |")
    if not extended:
        lines.extend(["", "Concurrent virtualization load was observed during the auto run, following its slower third 160K sample. All samples are retained; small between-profile differences are not isolated causal effects."])
    notes = "2026-09-06-extended-context-sweep" if extended else "2026-09-06-preset-context-sweep"
    lines.extend(["", "Evidence: [measurements.json](measurements.json).",
                  f"Protocol and limitations: [experiment notes](../../../docs/experiments/{notes}.md).", ""])
    (args.output_dir / "summary.md").write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
