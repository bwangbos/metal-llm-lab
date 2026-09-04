#!/bin/zsh
set -euo pipefail

source_root=${0:A:h:h}
cli="$source_root/bin/metal-llm"
schema="$source_root/schemas/result.schema.json"
raw_result="$source_root/results/raw/2026-09-03-qwen38-m5-max.json"
summary="$source_root/results/summaries/qwen3.8-flash-next-m5-max.md"
dynamic_raw_result="$source_root/results/raw/2026-09-03-qwen38-dynamic-mtp.json"
correctness_raw_result="$source_root/results/raw/2026-09-03-qwen38-dynamic-mtp-correctness.json"
dynamic_summary="$source_root/results/summaries/qwen3.8-flash-next-dynamic-mtp.md"
correctness_harness="$source_root/tests/integration/test_dynamic_mtp.sh"

fail() {
    print -u2 -- "$1"
    exit 1
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] || fail "missing expected output: $needle"
}

for required_file in "$schema" "$raw_result" "$summary" "$dynamic_raw_result" \
  "$correctness_raw_result" "$dynamic_summary"; do
    [[ -f "$required_file" ]] || fail "missing ${required_file#$source_root/}"
    case "$required_file" in
        *.json) jq empty "$required_file" ;;
    esac
done
git -C "$source_root" ls-files --error-unmatch \
  'results/raw/2026-09-03-qwen38-dynamic-mtp-correctness.json' >/dev/null 2>&1 || \
    fail 'dynamic-MTP correctness evidence is not tracked for clean checkouts'

jq -e '
  .suite_id == "dynamic-mtp-performance" and
  .configuration.acceptance_variant == "multi-policy-endpoint" and
  .configuration.mtp_policies == ["on", "off", "dynamic"] and
  .configuration.dynamic_threshold == 32768 and
  .configuration.context_allocation == 262144 and
  .configuration.vision == true and
  .configuration.effective_prompt_lengths == [29000, 30000, 32767, 32768, 32769, 33868, 98304] and
  .configuration.warmups_per_cell == 1 and
  .configuration.samples_per_cell == 5 and
  .configuration.throughput_tolerance_percent == 5 and
  (.configuration.correctness_evidence | keys | sort) ==
    (["path", "sha256", "repository_revision", "repository_tree_sha", "harness_sha256"] | sort) and
  .configuration.correctness_evidence.path ==
    "results/raw/2026-09-03-qwen38-dynamic-mtp-correctness.json" and
  (.configuration.correctness_evidence.sha256 | test("^[0-9a-f]{64}$")) and
  (.configuration.correctness_evidence.repository_revision | test("^[0-9a-f]{40}$")) and
  (.configuration.correctness_evidence.repository_tree_sha | test("^[0-9a-f]{40}$")) and
  (.configuration.correctness_evidence.harness_sha256 | test("^[0-9a-f]{64}$")) and
  (.configuration.accepted_allocation_observation.evidence_sha256 |
    test("^[0-9a-f]{64}$")) and
  .configuration.accepted_allocation_observation.observation.context == 262144 and
  .configuration.accepted_allocation_observation.observation.profile_id == "auto" and
  .configuration.accepted_allocation_observation.observation.mtp_policy == "dynamic" and
  (.configuration.accepted_allocation_observation.observation.process.rss_bytes > 0) and
  (.configuration.accepted_allocation_observation.observation.system_memory_pressure.free_percent >= 0) and
  (.runs | length) == 105 and
  (.configuration.statistics | length) == 21 and
  (.configuration.dynamic_fixed_comparisons | length) == 7 and
  all(.configuration.dynamic_fixed_comparisons[]; .passed == true) and
  ([.runs[] | select(.mtp_policy == "on" and .mtp_selected == true)] | length) == 35 and
  ([.runs[] | select(.mtp_policy == "off" and .mtp_selected == false)] | length) == 35 and
  ([.runs[] | select(.mtp_policy == "dynamic" and .mtp_selected == true)] | length) == 20 and
  ([.runs[] | select(.mtp_policy == "dynamic" and .mtp_selected == false)] | length) == 15 and
  .interpretation.performance_gate_passed == true
' "$dynamic_raw_result" >/dev/null || fail 'dynamic-MTP raw acceptance evidence is incomplete'
correctness_harness_sha=$(shasum -a 256 "$correctness_harness" | awk '{print $1}')
[[ "$(jq -r '.configuration.correctness_evidence.harness_sha256' "$dynamic_raw_result")" == \
   "$correctness_harness_sha" ]] || fail 'dynamic-MTP result is not bound to the current correctness harness'
correctness_evidence_sha=$(shasum -a 256 "$correctness_raw_result" | awk '{print $1}')
[[ "$(jq -r '.configuration.correctness_evidence.sha256' "$dynamic_raw_result")" == \
   "$correctness_evidence_sha" ]] || fail 'dynamic-MTP result is not bound to the tracked correctness evidence'

allocation_timestamp=$(jq -r '.configuration.accepted_allocation_observation.observation.captured_at' \
  "$dynamic_raw_result")
allocation_rss=$(jq -r '.configuration.accepted_allocation_observation.observation.process.rss_bytes' \
  "$dynamic_raw_result")
allocation_free=$(jq -r \
  '.configuration.accepted_allocation_observation.observation.system_memory_pressure.free_percent' \
  "$dynamic_raw_result")
for allocation_doc in \
  "$source_root/docs/hardware/apple-m5-max-128gb.md" \
  "$source_root/docs/experiments/2026-09-03-dynamic-mtp-acceptance.md"; do
    grep -Fq "$allocation_timestamp" "$allocation_doc" && \
    grep -Fq "$allocation_rss bytes" "$allocation_doc" && \
    grep -Fq "$allocation_free% system-wide effective free memory" "$allocation_doc" || \
        fail "memory observation in ${allocation_doc#$source_root/} differs from validated raw evidence"
done

jq -e '
  (.configuration.dynamic_fixed_comparisons[] | select(.effective_prompt_tokens == 32767) |
    .fixed_policy == "on" and .percent_delta == 1.2630904893804473) and
  (.configuration.dynamic_fixed_comparisons[] | select(.effective_prompt_tokens == 32769) |
    .fixed_policy == "off" and .percent_delta == 4.909370120449208) and
  (.configuration.dynamic_fixed_comparisons[] | select(.effective_prompt_tokens == 98304) |
    .fixed_policy == "off" and .percent_delta == 2.1573777541598282)
' "$dynamic_raw_result" >/dev/null || fail 'dynamic-MTP boundary comparisons changed'

jq -e '
    .["$defs"].run.required as $required |
    (.required | index("provenance") != null) and
    ([
      "timestamp", "repository_revision", "hardware_id", "runtime_id",
      "runtime_revision", "profile", "profile_id", "runtime_alias", "context", "vision",
      "mtp_policy", "mtp_selected", "mtp_threshold", "prompt_tokens", "effective_prompt_tokens",
      "generated_tokens", "prompt_tokens_per_second",
      "generation_tokens_per_second", "generation_settings", "command", "notes"
    ] - $required | length == 0)
' "$schema" >/dev/null || fail 'result schema does not require route-aware benchmark provenance'

jq -e '
    .schema_version == 1 and
    (.experiment_id | type == "string" and length > 0) and
    (.runs | type == "array" and length > 0) and
    all(.runs[];
      (.timestamp | fromdateiso8601) and
      (.repository_revision | test("^[0-9a-f]{40}$")) and
      ([.hardware_id, .runtime_id, .runtime_revision, .notes] |
        all(type == "string" and length > 0)) and
      (.profile == null) and
      (.profile_id == null) and (.runtime_alias == null) and (.context == null) and
      (.mtp_policy == null) and (.mtp_selected == null) and (.mtp_threshold == null) and
      (.prompt_tokens == null) and
      (has("vision")) and ((.vision == null) or (.vision | type == "boolean")) and
      (.runtime_revision | test("^[0-9a-f]{40}$")) and
      (.effective_prompt_tokens | type == "number" and . >= 0 and floor == .) and
      ((.generated_tokens == null) or (.generated_tokens | type == "number" and . >= 0 and floor == .)) and
      ((.prompt_tokens_per_second == null) or (.prompt_tokens_per_second | type == "number" and . >= 0)) and
      ((.generation_tokens_per_second == null) or (.generation_tokens_per_second | type == "number" and . >= 0)) and
      (.generation_settings | type == "object") and
      ((has("output_sha256") | not) or
        (.output_sha256 | type == "string" and test("^[0-9a-f]{64}$")))
    )
' "$raw_result" >/dev/null || fail 'historical result lacks explicit null compatibility provenance'
jq -e '
  ([.runs[] | select(.vision == true)] | length) == 26 and
  ([.runs[] | select(.vision == false)] | length) == 22 and
  ([.runs[] | select(.vision == null)] | length) == 14 and
  ([.runs[] | select(.mtp? == true)] | length) == 26 and
  ([.runs[] | select(.mtp? == false)] | length) == 26 and
  ([.runs[] | select(has("mtp") | not)] | length) == 10
' "$raw_result" >/dev/null || fail 'historical boolean/null provenance was rewritten'
jq -e '
  all(.runs[] | select(.experiment == "matched-mtp-ab" or
    .experiment == "attached-image-crossover" or
    .experiment == "text-boundary-mean" or
    .experiment == "text-boundary-single");
    .prompt_tokens_per_second == null) and
  all(.runs[] | select(.experiment == "attached-image-crossover" or
    .experiment == "text-boundary-mean" or
    .experiment == "text-boundary-single");
    .generated_tokens == null) and
  (first(.runs[] | select(.id == "retrieval-28k")) |
    .generated_tokens == null and .generation_tokens_per_second == null) and
  (first(.runs[] | select(.id == "retrieval-96k-mtp")) | .generated_tokens == null)
' "$raw_result" >/dev/null

private_path_pattern='/''Users/[A-Za-z0-9._-]+/'
if unsafe_match=$(rg -n "$private_path_pattern|(^|[\"_])(api[_-]?key|token|password|secret)[\"_ ]*:" \
    "$schema" "$raw_result" "$summary" "$dynamic_raw_result" "$correctness_raw_result" "$dynamic_summary" \
    "$source_root/docs" 2>/dev/null); then
    fail "committed result or documentation contains a private path or secret-like key:\n$unsafe_match"
fi

generated=$($cli report)
assert_contains "$generated" '| 99,405 | 34.4737 | 21.2468 | 160/188 |'
assert_contains "$generated" '| 28,705 | 40.755 | 0.567 | 41.279 | 3.082 | +1.29% |'
assert_contains "$generated" '23.80 tok/s'
assert_contains "$generated" 'approximately 33.6K'
assert_contains "$(<"$dynamic_summary")" '| 32,767 | on | 44.778118828762345 | 44.2195854504937 | +1.2630904893804473% | Pass |'
assert_contains "$(<"$dynamic_summary")" '| 32,769 | off | 43.14954799180947 | 41.1303088964011 | +4.909370120449208% | Pass |'
assert_contains "$(<"$dynamic_summary")" '| 98,304 | off | 40.313009802029555 | 39.461672458980104 | +2.1573777541598282% | Pass |'
$cli report --check >/dev/null

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-results.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
fixture_root="$temporary_root/repository"
mkdir -p "$fixture_root"/{bin,lib,schemas,results/raw,results/summaries,manifests/hardware,manifests/runtimes,tests/integration}
cp "$source_root/bin/metal-llm" "$fixture_root/bin/metal-llm"
cp "$source_root/lib"/*.zsh "$fixture_root/lib/"
cp "$schema" "$fixture_root/schemas/result.schema.json"
cp "$source_root/manifests/hardware"/*.json "$fixture_root/manifests/hardware/"
cp "$source_root/manifests/runtimes"/*.json "$fixture_root/manifests/runtimes/"
cp "$raw_result" "$fixture_root/results/raw/result.json"
cp "$correctness_raw_result" "$fixture_root/results/raw/2026-09-03-qwen38-dynamic-mtp-correctness.json"
cp "$summary" "$fixture_root/results/summaries/qwen3.8-flash-next-m5-max.md"
cp "$correctness_harness" "$fixture_root/tests/integration/test_dynamic_mtp.sh"
fixture_cli="$fixture_root/bin/metal-llm"
chmod +x "$fixture_cli"

assert_schema_invalid() {
    local filter=$1
    local description=$2
    jq "$filter" "$raw_result" > "$fixture_root/results/raw/result.json"
    if schema_output=$($fixture_cli report --check 2>&1); then
        fail "report accepted schema-invalid result: $description"
    fi
    assert_contains "$schema_output" 'invalid result document'
}

assert_schema_invalid '.runs[0].mtp = "not-a-boolean"' 'wrong optional boolean type'
assert_schema_invalid '.runs[0].unknown_field = true' 'unknown run property'
assert_schema_invalid '.unexpected = true' 'unknown top-level property'
assert_schema_invalid '.summary.unexpected = true' 'unknown summary property'
assert_schema_invalid '.runs[0].generation_settings.unexpected = true' 'unknown nested property'
assert_schema_invalid '.runs[0].generation_settings.temperature = "zero"' 'wrong nested type'
assert_schema_invalid '.runs[0].measurement_kind = "median"' 'invalid enum'
assert_schema_invalid '.runs[0].effective_prompt_tokens = -1' 'value below minimum'
assert_schema_invalid 'del(.runs[0].mtp_selected)' 'missing selected-route field'
assert_schema_invalid '.runs[0].runtime_alias = "other"' 'invalid runtime alias'
assert_schema_invalid '.runs[0].mtp_policy = "sometimes"' 'invalid MTP policy'
assert_schema_invalid '.runs[0].mtp_selected = "yes"' 'wrong selected-route type'
assert_schema_invalid '.runs[0].id = "INVALID ID"' 'pattern mismatch'
assert_schema_invalid '.runs[0].output_sha256 = "bad"' 'checksum pattern mismatch'
assert_schema_invalid '.date = "not-a-date"' 'date format mismatch'
assert_schema_invalid '.date = "2026-02-30"' 'invalid calendar date'
assert_schema_invalid '.runs[0].timestamp = "2026-02-30T00:00:00Z"' 'invalid calendar timestamp'
assert_schema_invalid '.runs = []' 'array below minimum size'
assert_schema_invalid 'del(.runs[0].notes)' 'missing required field'

route_result="$temporary_root/route-result.json"
jq '
  del(.summary) |
  .benchmark_mode = "endpoint" | .suite_id = "qwen3.8-smoke" |
  .runs = [(.runs[0] |
    .id = "dynamic-short" | .request_kind = "text" |
    .profile_id = "auto" | .runtime_alias = "tuned" |
    .context = 262144 | .vision = true | .mtp_policy = "dynamic" |
    .mtp_selected = true | .mtp_threshold = 32768 | .prompt_tokens = 3 |
    .effective_prompt_tokens = 32768)] |
  .provenance = {
    repository: {
      revision: .runs[0].repository_revision,
      tree_sha: .runs[0].repository_revision,
      clean: true
    },
    hardware: {id: .runs[0].hardware_id, chip: "Fixture Chip", unified_memory_bytes: 1},
    system: {
      operating_system: "macOS", operating_system_version: null, compiler: null,
      sdk: null, power_source: null, low_power_mode: null
    },
    profile_id: "auto", runtime_alias: "tuned", context: 262144, vision: true,
    mtp_policy: "dynamic", mtp_threshold: 32768,
    runtime: {
      id: .runs[0].runtime_id, tested_revision: .runs[0].runtime_revision,
      tested_tree_sha: .runs[0].runtime_revision,
      manifest_sha256: ("0" * 64), build_receipt_sha256: ("0" * 64),
      executable: {name: "llama-server", sha256: ("0" * 64)}
    },
    model_manifest_sha256: ("0" * 64),
    artifacts: [{id: "model", bytes: 1, sha256: ("0" * 64)}],
    suite: {id: "qwen3.8-smoke", sha256: ("0" * 64), fixtures: []}
  }
' "$raw_result" > "$route_result"
cp "$route_result" "$fixture_root/results/raw/result.json"
route_output=$($fixture_cli report)
assert_contains "$route_output" '| Run | Experiment | Prompt tokens | Effective prompt tokens | MTP policy | Selected route | Generated tokens | Prompt tok/s | Generation tok/s |'
assert_contains "$route_output" '| dynamic-short | runtime-comparison | 3 | 32,768 | dynamic | on | 128 | 513.38 | 37.03 |'

assert_route_invalid() {
    local filter=$1
    local description=$2
    jq "$filter" "$route_result" > "$fixture_root/results/raw/result.json"
    if route_validation_output=$($fixture_cli report 2>&1); then
        fail "report accepted invalid benchmark route provenance: $description"
    fi
    assert_contains "$route_validation_output" 'invalid benchmark route provenance'
}

assert_route_invalid '.runs[0].mtp_threshold = null' 'dynamic route without threshold'
assert_route_invalid '.provenance = null' 'new endpoint harness without provenance'
assert_route_invalid 'del(.benchmark_mode, .suite_id) | .provenance = null' \
  'route-enriched row disguised as provenance-null history'
assert_route_invalid '.provenance.repository.revision = ("f" * 40)' \
  'run repository revision differs from provenance'
assert_route_invalid '.provenance.hardware.id = "invented-hardware"' \
  'run hardware differs from provenance'
assert_route_invalid '.provenance.suite.id = "other-suite"' \
  'top-level suite differs from provenance'
assert_route_invalid 'del(.suite_id)' 'new endpoint harness without top-level suite identity'
assert_route_invalid 'del(.runs[0].request_kind)' 'new endpoint row without typed request kind'
assert_route_invalid '.runs[0].mtp_selected = false' 'dynamic route disabled at threshold'
assert_route_invalid '.runs[0].effective_prompt_tokens = 32769' 'dynamic route enabled above threshold'
assert_route_invalid '.runs[0].request_kind = "vision" | .runs[0].prompt_tokens = 32769 |
  .runs[0].effective_prompt_tokens = 32768 | .runs[0].mtp_selected = true' \
  'vision route used substituted text-only timing count'
assert_route_invalid '.runs[0].effective_prompt_tokens = 262145 | .runs[0].mtp_selected = false' \
  'effective prompt count exceeds configured context'
assert_route_invalid '.runs[0].mtp_policy = "on" | .runs[0].mtp_selected = false | .runs[0].mtp_threshold = null' \
  'fixed-on route disabled'
assert_route_invalid '.runs[0].mtp_policy = "off" | .runs[0].mtp_selected = true | .runs[0].mtp_threshold = null' \
  'fixed-off route enabled'
assert_route_invalid '.runs[0].mtp_policy = "on" | .runs[0].mtp_threshold = 32768' \
  'fixed policy retained a threshold'
assert_route_invalid '.benchmark_mode = "local" | .runs[0].profile_id = null | .runs[0].context = null | .runs[0].vision = null' \
  'standalone llama-bench labeled as dynamic MTP'

multi_policy_result="$temporary_root/multi-policy-result.json"
cp "$dynamic_raw_result" "$multi_policy_result"
cp "$multi_policy_result" "$fixture_root/results/raw/result.json"
$fixture_cli report >/dev/null

assert_multi_policy_invalid() {
    local filter=$1
    local description=$2
    jq "$filter" "$multi_policy_result" > "$fixture_root/results/raw/result.json"
    if multi_policy_validation_output=$($fixture_cli report 2>&1); then
        fail "report accepted invalid multi-policy endpoint provenance: $description"
    fi
    assert_contains "$multi_policy_validation_output" 'invalid benchmark route provenance'
}

assert_multi_policy_invalid 'del(.configuration.acceptance_variant)' 'missing explicit acceptance variant'
assert_multi_policy_invalid '.provenance.profile_id = "auto"' 'non-custom common profile'
assert_multi_policy_invalid '.provenance.runtime_alias = "upstream"' 'non-tuned common runtime'
assert_multi_policy_invalid '.provenance.mtp_policy = "dynamic"' 'top-level policy hides mixed rows'
assert_multi_policy_invalid '.provenance.mtp_threshold = 32768' 'top-level threshold hides mixed rows'
assert_multi_policy_invalid '.configuration.mtp_policies = ["on", "dynamic"]' 'declared policies omit fixed off'
assert_multi_policy_invalid '.runs |= map(select(.mtp_policy != "off"))' 'measured rows omit fixed off'
assert_multi_policy_invalid '.runs[0].vision = false' 'run vision differs from common provenance'
assert_multi_policy_invalid '.runs[1].runtime_alias = "upstream"' 'run runtime differs from common provenance'
assert_multi_policy_invalid '(.runs[] | select(.mtp_policy == "dynamic") | .mtp_selected) = false' \
  'dynamic route disabled at threshold'
assert_multi_policy_invalid '(.runs[] | select(.mtp_policy == "dynamic") | .mtp_threshold) = 30000' \
  'dynamic row threshold differs from acceptance threshold'
assert_multi_policy_invalid '.runs[0].mtp_threshold = 32768' 'fixed row carries a threshold'

jq '.suite_id = "renamed-dynamic-suite" |
    .provenance.suite.id = "renamed-dynamic-suite"' \
  "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
if renamed_dynamic_output=$($fixture_cli report 2>&1); then
    fail 'report accepted dynamic-MTP acceptance evidence under a renamed suite'
fi
assert_contains "$renamed_dynamic_output" 'invalid benchmark route provenance'

cp "$dynamic_raw_result" "$fixture_root/results/raw/result.json"
$fixture_cli report >/dev/null
$fixture_cli report --check >/dev/null

fixture_correctness="$fixture_root/results/raw/2026-09-03-qwen38-dynamic-mtp-correctness.json"
restore_correctness_fixture() {
    cp "$correctness_raw_result" "$fixture_correctness"
    cp "$dynamic_raw_result" "$fixture_root/results/raw/result.json"
}

assert_correctness_rejected() {
    local description=$1
    local expected_error=$2
    if correctness_output=$($fixture_cli report --check 2>&1); then
        fail "report --check accepted $description"
    fi
    assert_contains "$correctness_output" "$expected_error"
}

rm -f -- "$fixture_correctness"
assert_correctness_rejected 'missing tracked correctness evidence' \
  'invalid dynamic-MTP correctness evidence'

restore_correctness_fixture
jq '.runs[0].notes += " changed"' "$correctness_raw_result" > "$fixture_correctness.part"
mv "$fixture_correctness.part" "$fixture_correctness"
assert_correctness_rejected 'changed tracked correctness evidence' \
  'invalid dynamic-MTP correctness evidence'

restore_correctness_fixture
print -r -- '{malformed' > "$fixture_correctness"
malformed_sha=$(shasum -a 256 "$fixture_correctness" | awk '{print $1}')
jq --arg sha "$malformed_sha" '.configuration.correctness_evidence.sha256 = $sha' \
  "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
assert_correctness_rejected 'malformed tracked correctness evidence' 'invalid result document'

restore_correctness_fixture
jq 'del(.runs[-1])' "$correctness_raw_result" > "$fixture_correctness.part"
mv "$fixture_correctness.part" "$fixture_correctness"
wrong_case_sha=$(shasum -a 256 "$fixture_correctness" | awk '{print $1}')
jq --arg sha "$wrong_case_sha" '.configuration.correctness_evidence.sha256 = $sha' \
  "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
assert_correctness_rejected 'tracked correctness evidence with the wrong case set' \
  'invalid dynamic-MTP correctness evidence'

restore_correctness_fixture
jq '.provenance.suite.sha256 = ("f" * 64)' \
  "$correctness_raw_result" > "$fixture_correctness.part"
mv "$fixture_correctness.part" "$fixture_correctness"
wrong_harness_sha=$(shasum -a 256 "$fixture_correctness" | awk '{print $1}')
jq --arg sha "$wrong_harness_sha" '.configuration.correctness_evidence.sha256 = $sha' \
  "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
assert_correctness_rejected 'tracked correctness evidence with the wrong harness identity' \
  'invalid dynamic-MTP correctness evidence'

restore_correctness_fixture
jq '.configuration.correctness_evidence.sha256 = ("f" * 64)' \
  "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
assert_correctness_rejected 'tracked correctness evidence with the wrong bound hash' \
  'invalid dynamic-MTP correctness evidence'

restore_correctness_fixture
jq '.provenance.repository.revision = ("f" * 40) |
    (.runs[].repository_revision = ("f" * 40))' \
  "$correctness_raw_result" > "$fixture_correctness.part"
mv "$fixture_correctness.part" "$fixture_correctness"
wrong_provenance_sha=$(shasum -a 256 "$fixture_correctness" | awk '{print $1}')
jq --arg sha "$wrong_provenance_sha" '.configuration.correctness_evidence.sha256 = $sha' \
  "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
assert_correctness_rejected 'tracked correctness evidence with changed immutable provenance' \
  'invalid dynamic-MTP correctness evidence'

restore_correctness_fixture
jq '.runs[0].generation_tokens_per_second += 1' \
    "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
if dynamic_drift_output=$($fixture_cli report --check 2>&1); then
    fail 'report --check accepted a changed retained throughput sample with stale aggregates'
fi
assert_contains "$dynamic_drift_output" 'invalid dynamic-MTP derived data'

jq '.runs[0].output_sha256 = ("f" * 64)' \
    "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
if dynamic_output_drift=$($fixture_cli report --check 2>&1); then
    fail 'report --check accepted a changed retained output hash with stale aggregates'
fi
assert_contains "$dynamic_output_drift" 'invalid dynamic-MTP derived data'

jq '.configuration.accepted_allocation_observation.observation.process.rss_bytes = 0' \
    "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
if invalid_allocation_output=$($fixture_cli report --check 2>&1); then
    fail 'report --check accepted a zero-RSS allocation observation'
fi
assert_contains "$invalid_allocation_output" 'invalid dynamic-MTP derived data'

jq '.configuration.accepted_allocation_observation.evidence_sha256 = ("f" * 64)' \
    "$dynamic_raw_result" > "$fixture_root/results/raw/result.json"
if invalid_allocation_hash_output=$($fixture_cli report --check 2>&1); then
    fail 'report --check accepted an allocation observation with a mismatched evidence hash'
fi
assert_contains "$invalid_allocation_hash_output" 'invalid dynamic-MTP derived data'

jq '.runs[0].hardware_id = "unknown-hardware"' "$raw_result" > "$fixture_root/results/raw/result.json"
if invalid_output=$($fixture_cli report --check 2>&1); then
    fail 'report accepted an unknown hardware ID'
fi
assert_contains "$invalid_output" 'unknown hardware id: unknown-hardware'

jq '.runs[0].runtime_id = "unknown-runtime"' "$raw_result" > "$fixture_root/results/raw/result.json"
if invalid_runtime_output=$($fixture_cli report --check 2>&1); then
    fail 'report accepted an unknown runtime ID'
fi
assert_contains "$invalid_runtime_output" 'unknown runtime id: unknown-runtime'

jq '.runs[0].hardware_id = "apple-m5-max-128gb" | .runs[0].notes = ("/" + "Users" + "/example/private")' \
    "$raw_result" > "$fixture_root/results/raw/result.json"
if unsafe_output=$($fixture_cli report --check 2>&1); then
    fail 'report accepted a private absolute path'
fi
assert_contains "$unsafe_output" 'unsafe private path'

jq '.runs[0].notes = ("diagnostic text embeds /" + "Users" + "/example/private within a longer value")' \
    "$raw_result" > "$fixture_root/results/raw/result.json"
if embedded_unsafe_output=$($fixture_cli report --check 2>&1); then
    fail 'report accepted an embedded private absolute path'
fi
assert_contains "$embedded_unsafe_output" 'unsafe private path'

jq '.runs[0].notes = "safe" | .environment.api_key = "not-a-real-key"' \
    "$raw_result" > "$fixture_root/results/raw/result.json"
if secret_output=$($fixture_cli report --check 2>&1); then
    fail 'report accepted a secret-like key'
fi
assert_contains "$secret_output" 'secret-like key'

cp "$raw_result" "$fixture_root/results/raw/result.json"
print -- 'drift' >> "$fixture_root/results/summaries/qwen3.8-flash-next-m5-max.md"
if drift_output=$($fixture_cli report --check 2>&1); then
    fail 'report --check accepted summary drift'
fi
assert_contains "$drift_output" 'summary differs from generated output'

jq 'del(.summary)' "$raw_result" > "$fixture_root/results/raw/result.json"
generic_output=$($fixture_cli report)
assert_contains "$generic_output" '| Run | Experiment | Prompt tokens | Effective prompt tokens | MTP policy | Selected route | Generated tokens | Prompt tok/s | Generation tok/s |'
assert_contains "$generic_output" '| image-99405-no-mtp | attached-image-crossover | n/a | 99,405 | n/a | n/a | n/a | n/a | 34.4737 |'

cp "$summary" "$fixture_root/results/summaries/qwen3.8-flash-next-m5-max.md"
jq '
  (.runs[] | select(.id == "matched-mtp")) |= (
    .profile_id = "auto" | .runtime_alias = "tuned" | .context = 262144 |
    .vision = true | .mtp_policy = "dynamic" | .mtp_selected = true |
    .mtp_threshold = 32768 | .prompt_tokens = 24)
' "$raw_result" > "$fixture_root/results/raw/result.json"
if historical_route_output=$($fixture_cli report 2>&1); then
    fail 'report accepted invented route provenance in imported history'
fi
assert_contains "$historical_route_output" 'invalid benchmark route provenance'

jq --slurpfile route "$route_result" '
  .benchmark_mode = "endpoint" | .suite_id = $route[0].suite_id |
  .provenance = $route[0].provenance |
  (.runs[] |= (
    .repository_revision = $route[0].provenance.repository.revision |
    .hardware_id = $route[0].provenance.hardware.id |
    .runtime_id = $route[0].provenance.runtime.id |
    .runtime_revision = $route[0].provenance.runtime.tested_revision |
    .profile_id = $route[0].provenance.profile_id |
    .runtime_alias = $route[0].provenance.runtime_alias |
    .context = $route[0].provenance.context |
    .vision = $route[0].provenance.vision |
    .request_kind = "text" |
    .mtp_policy = $route[0].provenance.mtp_policy |
    .mtp_selected = (.effective_prompt_tokens <= $route[0].provenance.mtp_threshold) |
    .mtp_threshold = $route[0].provenance.mtp_threshold |
    .prompt_tokens = null
  ))
' "$raw_result" > "$fixture_root/results/raw/result.json"
route_summary_output=$($fixture_cli report)
assert_contains "$route_summary_output" '## MTP route provenance'
assert_contains "$route_summary_output" '| matched-mtp | dynamic | on | 24 | 32,768 |'
cp "$summary" "$fixture_root/results/summaries/qwen3.8-flash-next-m5-max.md"
if route_drift_output=$($fixture_cli report --check 2>&1); then
    fail 'report --check accepted generated MTP route statement drift'
fi
assert_contains "$route_drift_output" 'summary differs from generated output'

jq '.summary.output = "../../escaped.md"' "$raw_result" > "$fixture_root/results/raw/result.json"
if traversal_output=$($fixture_cli report 2>&1); then
    fail 'report accepted a summary path traversal'
fi
assert_contains "$traversal_output" 'invalid result document'
[[ ! -e "$fixture_root/escaped.md" ]] || fail 'report wrote a summary outside results/summaries'

jq '
  .date = "2026-09-04" |
  .interpretation.general_purpose_gray_zone_tokens_approximate = [31000, 32000] |
  (.runs[] | select(.id == "matched-mtp") | .generation_tokens_per_second) = 102.18 |
  (.runs[] | select(.id == "matched-mtp") | .generation_tokens_per_second_display) = "102.18" |
  (.runs[] | select(.id == "matched-mtp") | .output_equivalence) = "diverged" |
  (.runs[] | select(.id == "image-99405-no-mtp") | .generation_tokens_per_second) = 35.1234 |
  (.runs[] | select(.id == "image-99405-no-mtp") | .generation_tokens_per_second_display) = "35.1234"
' "$raw_result" > "$fixture_root/results/raw/result.json"
mutation_output=$($fixture_cli report)
assert_contains "$mutation_output" '2026-09-04'
assert_contains "$mutation_output" '+100%'
assert_contains "$mutation_output" 'improved from 51.09 to 102.18 tok/s (+100%)'
assert_contains "$mutation_output" 'and the outputs diverged.'
assert_contains "$mutation_output" '31,000–32,000 effective tokens'
assert_contains "$mutation_output" '35.1234 tok/s'
cp "$summary" "$fixture_root/results/summaries/qwen3.8-flash-next-m5-max.md"
if mutation_check=$($fixture_cli report --check 2>&1); then
    fail 'report --check accepted a summary after raw source values changed'
fi
assert_contains "$mutation_check" 'summary differs from generated output'

jq '
  (.runs[] | select(.id == "matched-mtp") | .generation_tokens_per_second) = 25.545 |
  (.runs[] | select(.id == "matched-mtp") | .generation_tokens_per_second_display) = "25.545"
' "$raw_result" > "$fixture_root/results/raw/result.json"
negative_output=$($fixture_cli report)
assert_contains "$negative_output" 'declined from 51.09 to 25.545 tok/s (-50%)'

jq '
  (.runs[] | select(.id == "matched-mtp") | .generation_tokens_per_second) = 51.09 |
  (.runs[] | select(.id == "matched-mtp") | .generation_tokens_per_second_display) = "51.09"
' "$raw_result" > "$fixture_root/results/raw/result.json"
equal_output=$($fixture_cli report)
assert_contains "$equal_output" 'was unchanged at 51.09 tok/s (0%)'

print -- 'result checks: PASS'
