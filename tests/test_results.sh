#!/bin/zsh
set -euo pipefail

source_root=${0:A:h:h}
cli="$source_root/bin/metal-llm"
schema="$source_root/schemas/result.schema.json"
raw_result="$source_root/results/raw/2026-09-03-qwen38-m5-max.json"
summary="$source_root/results/summaries/qwen3.8-flash-next-m5-max.md"

fail() {
    print -u2 -- "$1"
    exit 1
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] || fail "missing expected output: $needle"
}

for required_file in "$schema" "$raw_result" "$summary"; do
    [[ -f "$required_file" ]] || fail "missing ${required_file#$source_root/}"
    case "$required_file" in
        *.json) jq empty "$required_file" ;;
    esac
done

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
    "$schema" "$raw_result" "$summary" "$source_root/docs" 2>/dev/null); then
    fail "committed result or documentation contains a private path or secret-like key:\n$unsafe_match"
fi

generated=$($cli report)
assert_contains "$generated" '| 99,405 | 34.4737 | 21.2468 | 160/188 |'
assert_contains "$generated" '| 28,705 | 40.755 | 0.567 | 41.279 | 3.082 | +1.29% |'
assert_contains "$generated" '23.80 tok/s'
assert_contains "$generated" 'approximately 33.6K'
cmp -s <(print -r -- "$generated") "$summary" || fail 'report output differs from committed summary'
$cli report --check >/dev/null

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-results.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
fixture_root="$temporary_root/repository"
mkdir -p "$fixture_root"/{bin,lib,schemas,results/raw,results/summaries,manifests/hardware,manifests/runtimes}
cp "$source_root/bin/metal-llm" "$fixture_root/bin/metal-llm"
cp "$source_root/lib"/*.zsh "$fixture_root/lib/"
cp "$schema" "$fixture_root/schemas/result.schema.json"
cp "$source_root/manifests/hardware"/*.json "$fixture_root/manifests/hardware/"
cp "$source_root/manifests/runtimes"/*.json "$fixture_root/manifests/runtimes/"
cp "$raw_result" "$fixture_root/results/raw/result.json"
cp "$summary" "$fixture_root/results/summaries/qwen3.8-flash-next-m5-max.md"
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
    .id = "dynamic-short" | .profile_id = "auto" | .runtime_alias = "tuned" |
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
assert_route_invalid '.runs[0].mtp_selected = false' 'dynamic route disabled at threshold'
assert_route_invalid '.runs[0].effective_prompt_tokens = 32769' 'dynamic route enabled above threshold'
assert_route_invalid '.runs[0].prompt_tokens = 3 | .runs[0].effective_prompt_tokens = 3 | .runs[0].mtp_selected = false' \
  'text-only count substituted for expanded effective count'
assert_route_invalid '.runs[0].mtp_policy = "on" | .runs[0].mtp_selected = false | .runs[0].mtp_threshold = null' \
  'fixed-on route disabled'
assert_route_invalid '.runs[0].mtp_policy = "off" | .runs[0].mtp_selected = true | .runs[0].mtp_threshold = null' \
  'fixed-off route enabled'
assert_route_invalid '.runs[0].mtp_policy = "on" | .runs[0].mtp_threshold = 32768' \
  'fixed policy retained a threshold'
assert_route_invalid '.benchmark_mode = "local" | .runs[0].profile_id = null | .runs[0].context = null | .runs[0].vision = null' \
  'standalone llama-bench labeled as dynamic MTP'
assert_route_invalid '.runs[0].profile_id = null | .runs[0].runtime_alias = "tuned" | .runs[0].context = null | .runs[0].vision = null | .runs[0].mtp_policy = null | .runs[0].mtp_selected = null | .runs[0].effective_prompt_tokens = null | .runs[0].mtp_threshold = null' \
  'partially invented historical runtime alias'

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
