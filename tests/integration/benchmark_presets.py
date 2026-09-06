#!/usr/bin/env python3
"""Measure actual preset context curves; retain every response for resumption."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import statistics
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
MODEL = "qwen3.8-flash-next"
GENERATED = 128
SAMPLES = 3
PROFILES = {"fast": 32768, "stable": 32768, "long": 262144, "auto": 262144}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    data = json.dumps(value, indent=2) + "\n"
    temp = path.with_suffix(path.suffix + ".part")
    with temp.open("w") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    temp.replace(path)


def targets(context):
    return [128, *range(32768, context, 32768), context - 2 * GENERATED]


def api(port, endpoint, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/{endpoint}", data=data,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=1800) as response:
        return json.load(response)


def payload(token, count):
    return dict(prompt=[token] * count, n_predict=GENERATED, temperature=0,
                seed=1234, ignore_eos=True, cache_prompt=False, id_slot=0, stream=False)


def validate(response, profile, target):
    if "error" in response:
        raise RuntimeError(response["error"])
    t = response["timings"]
    effective = t.get("effective_prompt_tokens", response.get("tokens_evaluated"))
    if effective != target or t["predicted_n"] != GENERATED:
        raise RuntimeError(f"wrong token counts: effective={effective}, target={target}, timings={t}")
    if t["prompt_n"] < target - 1:
        raise RuntimeError(f"cached prefix contaminated prefill: {t}")
    if response.get("truncated", False):
        raise RuntimeError("request was truncated")
    if profile != "stable":
        expected = profile == "fast" or (profile == "auto" and target <= 32768)
        if t.get("speculative") != expected:
            raise RuntimeError(f"unexpected MTP route: {t}")
    for key in ("prompt_per_second", "predicted_per_second"):
        if not t[key] > 0:
            raise RuntimeError(f"invalid throughput: {t}")
    return t


LAUNCH = '''set -euo pipefail
setopt extended_glob
unsetopt bg_nice
code_root=$1
export METAL_LLM_ROOT=$2
profile=$3
export METAL_LLM_PORT=$4
extended=$5
for module in common artifact-verification profile setup runtime-state managed-process serve; do
  source "$code_root/lib/$module.zsh"
done
if [[ "$extended" == yes ]]; then
  runtime=tuned
  mtp=on
  if [[ "$profile" == stable ]]; then
    runtime=upstream
    mtp=off
  fi
  metal_llm_serve qwen3.8-flash-next --profile custom --runtime "$runtime" --mtp "$mtp" --context 262144 --vision on --artifact-check cached
else
  metal_llm_serve qwen3.8-flash-next --profile "$profile" --vision on --artifact-check cached
fi
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--extended", action="store_true", help="fast/stable-equivalent custom configurations, both allocated 256K")
    args = parser.parse_args()
    profiles = {"fast": 262144, "stable": 262144} if args.extended else PROFILES
    state = args.state_root.resolve()
    run = args.run_dir.resolve()
    run.mkdir(parents=True, exist_ok=True)
    for relative in [Path("manifests/models") / (MODEL + ".json"),
                     *[p.relative_to(ROOT) for p in (ROOT / "manifests/runtimes").glob("*.json")]]:
        if (ROOT / relative).read_bytes() != (state / relative).read_bytes():
            raise RuntimeError(f"state manifest mismatch: {relative}")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    identity = dict(repository_revision=revision, harness_sha256=digest(Path(__file__).read_bytes()),
                    model_manifest_sha256=digest((ROOT / "manifests/models" / (MODEL + ".json")).read_bytes()),
                    profiles=profiles, samples=SAMPLES, generated_tokens=GENERATED,
                    extended=args.extended,
                    vision=True, warmups=1, os=platform.platform(),
                    method="repeated token ID, uncached /completion, 128 output tokens; " +
                    ("custom fast/stable equivalents at 256K allocation" if args.extended else "exact preset allocations"))
    identity_path = run / "experiment.json"
    if identity_path.exists() and json.loads(identity_path.read_text()) != identity:
        raise RuntimeError("experiment identity changed; use a new run directory")
    save(identity_path, identity)
    lease = Path(os.environ.get("TMPDIR", "/tmp")) / "metal-llm-lab/full-model.lease/identity.json"
    for profile, context in profiles.items():
        if all((run / f"{profile}-{n}-s{sample}.json").exists()
               for n in targets(context) for sample in range(1, SAMPLES + 1)):
            print(f"SKIP completed {profile}", flush=True)
            continue
        with socket.socket() as sock:
            if sock.connect_ex(("127.0.0.1", args.port)) == 0:
                raise RuntimeError("port already occupied; refusing to benchmark an unrelated server")
        session = f"{profile}-{time.time_ns()}"
        log_path = run / (session + ".log")
        print(f"START {profile}: context={context}, log={log_path.name}", flush=True)
        with log_path.open("w") as log:
            process = subprocess.Popen(["zsh", "-c", LAUNCH, "preset-benchmark", str(ROOT),
                                        str(state), profile, str(args.port), "yes" if args.extended else "no"], stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 3600
                last_update = 0
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(f"{profile} exited: {log_path.read_text()[-6000:]}")
                    try:
                        if api(args.port, "health").get("status") == "ok":
                            break
                    except (OSError, ValueError):
                        pass
                    if time.monotonic() > deadline:
                        raise RuntimeError("server startup timed out")
                    if time.monotonic() - last_update > 30:
                        print(f"WAIT {profile}: verification/loading ({log_path.stat().st_size} log bytes)", flush=True)
                        last_update = time.monotonic()
                    time.sleep(2)
                managed = json.loads(lease.read_text())
                expected_profile = "custom" if args.extended else profile
                expected_runtime = "upstream" if profile == "stable" else "tuned"
                expected_mtp = {"fast": "on", "stable": "off", "long": "off", "auto": "dynamic"}[profile]
                if (managed["pid"] != process.pid or managed["profile_id"] != expected_profile
                        or managed["context"] != context or managed["runtime_alias"] != expected_runtime
                        or managed["mtp_policy"] != expected_mtp or managed["vision"] is not True):
                    raise RuntimeError("managed server identity mismatch")
                save(run / (session + "-identity.json"), managed)
                token = api(args.port, "tokenize", dict(content=" x", add_special=False))["tokens"][-1]
                calibration = api(args.port, "completion", payload(token, 32))
                save(run / (session + "-calibration.json"), calibration)
                t = calibration["timings"]
                offset = t.get("effective_prompt_tokens", calibration.get("tokens_evaluated")) - 32
                if not 0 <= offset < 64:
                    raise RuntimeError(f"invalid tokenizer offset: {offset}")
                print(f"HEALTHY {profile}: token={token}, offset={offset}", flush=True)
                for target in targets(context):
                    pending = [s for s in range(1, SAMPLES + 1) if not (run / f"{profile}-{target}-s{s}.json").exists()]
                    if not pending:
                        continue
                    request = payload(token, target - offset)
                    for sample in [0, *pending]:
                        name = f"{profile}-{target}-s{sample}" if sample else f"{session}-{target}-warmup"
                        print(f"RUN {name}", flush=True)
                        started = time.time()
                        response = api(args.port, "completion", request)
                        raw = run / (name + "-response.json")
                        save(raw, response)
                        timing = validate(response, profile, target)
                        record = dict(profile=profile, context=context, prompt_tokens=target,
                                      sample=sample, session=session, started_at=started,
                                      elapsed_seconds=time.time() - started, timings=timing,
                                      request_sha256=digest(json.dumps(request).encode()),
                                      response_sha256=digest(raw.read_bytes()),
                                      output_sha256=digest(response.get("content", "").encode()))
                        save(run / (name + ".json"), record)
                        print(f"DONE {name}: prefill={timing['prompt_per_second']:.2f}, generation={timing['predicted_per_second']:.2f}", flush=True)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=90)
                    except subprocess.TimeoutExpired:
                        raise RuntimeError("owned server did not stop; refusing to launch another")
        print(f"STOPPED {profile}", flush=True)
    rows = []
    for profile, context in profiles.items():
        for target in targets(context):
            records = [json.loads((run / f"{profile}-{target}-s{s}.json").read_text()) for s in range(1, SAMPLES + 1)]
            row = dict(profile=profile, context=context, prompt_tokens=target, samples=SAMPLES)
            for name, key in [("prefill", "prompt_per_second"), ("generation", "predicted_per_second")]:
                values = [r["timings"][key] for r in records]
                row[name + "_mean"] = statistics.mean(values)
                row[name + "_sd"] = statistics.stdev(values)
            rows.append(row)
    save(run / "summary.json", rows)
    print(json.dumps(rows, indent=2), flush=True)


if __name__ == "__main__":
    main()
