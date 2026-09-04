metal_llm_report_usage() {
    metal_llm_error 'usage: metal-llm report [--check]'
    return 2
}

metal_llm_dynamic_mtp_derived_data() {
    local result_file=$1
    jq '
      def mean: add / length;
      def sample_sd:
        . as $values | ($values | mean) as $mean |
        (($values | map((. - $mean) * (. - $mean)) | add) / ($values | length - 1)) | sqrt;
      .configuration.dynamic_threshold as $threshold |
      .configuration.throughput_tolerance_percent as $tolerance |
      (.runs | sort_by(.mtp_policy, .effective_prompt_tokens) |
        group_by([.mtp_policy, .effective_prompt_tokens]) |
        map(
          . as $runs |
          ($runs | map(.prompt_tokens_per_second)) as $prompt_samples |
          ($runs | map(.generation_tokens_per_second)) as $generation_samples |
          {
            policy: $runs[0].mtp_policy,
            effective_prompt_tokens: $runs[0].effective_prompt_tokens,
            selected_route: $runs[0].mtp_selected,
            sample_count: ($runs | length),
            prompt_tokens_per_second_samples: $prompt_samples,
            prompt_tokens_per_second_mean: ($prompt_samples | mean),
            prompt_tokens_per_second_sample_sd: ($prompt_samples | sample_sd),
            generation_tokens_per_second_samples: $generation_samples,
            generation_tokens_per_second_mean: ($generation_samples | mean),
            generation_tokens_per_second_sample_sd: ($generation_samples | sample_sd),
            draft_accepted: ($runs | map(.draft_acceptance | split("/")[0] | tonumber) | add),
            draft_generated: ($runs | map(.draft_acceptance | split("/")[1] | tonumber) | add),
            output_sha256: ($runs | map(.output_sha256)),
            distinct_output_count: ($runs | map(.output_sha256) | unique | length)
          }
        )) as $statistics |
      ([$statistics[] | select(.policy == "dynamic") as $dynamic |
        (if $dynamic.effective_prompt_tokens <= $threshold then "on" else "off" end) as $fixed_policy |
        ($statistics[] | select(.policy == $fixed_policy and
          .effective_prompt_tokens == $dynamic.effective_prompt_tokens)) as $fixed |
        (((($dynamic.generation_tokens_per_second_mean /
             $fixed.generation_tokens_per_second_mean) - 1) * 100)) as $delta |
        {
          effective_prompt_tokens: $dynamic.effective_prompt_tokens,
          dynamic_selected_route: $dynamic.selected_route,
          fixed_policy: $fixed_policy,
          dynamic_generation_tokens_per_second_mean: $dynamic.generation_tokens_per_second_mean,
          fixed_generation_tokens_per_second_mean: $fixed.generation_tokens_per_second_mean,
          percent_delta: $delta,
          tolerance_percent: $tolerance,
          passed: (($delta | fabs) <= $tolerance)
        }]) as $comparisons |
      {
        statistics: $statistics,
        dynamic_fixed_comparisons: $comparisons,
        performance_gate_passed: ($comparisons | all(.[]; .passed))
      }
    ' "$result_file"
}

metal_llm_validate_accepted_allocation_observation() {
    local observation=$1
    jq -e '
      (keys | sort) == ([
        "schema_version", "captured_at", "model_id", "profile_id", "runtime_alias",
        "context", "vision", "mtp_policy", "mtp_threshold", "process",
        "system_memory_pressure", "identity"
      ] | sort) and
      .schema_version == 1 and
      (.captured_at | type == "string" and
        (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == .) catch false)) and
      .model_id == "qwen3.8-flash-next" and .profile_id == "auto" and
      .runtime_alias == "tuned" and .context == 262144 and
      .vision == true and .mtp_policy == "dynamic" and .mtp_threshold == 32768 and
      (.process | keys | sort) == (["pid", "process_started_at", "rss_bytes"] | sort) and
      (.process.pid | type == "number" and floor == . and . > 1) and
      (.process.process_started_at | type == "string" and length > 0) and
      (.process.rss_bytes | type == "number" and floor == . and . > 0) and
      (.system_memory_pressure | keys) == ["free_percent"] and
      (.system_memory_pressure.free_percent | type == "number" and
        floor == . and . >= 0 and . <= 100) and
      (.identity | keys | sort) == ([
        "managed_process_sha256", "server_log_sha256", "executable_sha256"
      ] | sort) and
      all(.identity[]; type == "string" and test("^[0-9a-f]{64}$"))
    ' <<< "$observation" >/dev/null 2>&1
}

metal_llm_validate_dynamic_mtp_derived_data() {
    local result_file=$1 derived allocation_observation allocation_sha expected_allocation_sha
    derived=$(metal_llm_dynamic_mtp_derived_data "$result_file") || return 1
    allocation_observation=$(jq -c '.configuration.accepted_allocation_observation.observation' \
      "$result_file") || return 1
    metal_llm_validate_accepted_allocation_observation "$allocation_observation" || return 1
    allocation_sha=$(print -r -- "$(jq -cS . <<< "$allocation_observation")" | \
      shasum -a 256 | awk '{print $1}') || return 1
    expected_allocation_sha=$(jq -er \
      '.configuration.accepted_allocation_observation.evidence_sha256' "$result_file") || return 1
    [[ "$allocation_sha" == "$expected_allocation_sha" ]] || return 1
    jq -e --argjson derived "$derived" '
      . as $result |
      ([.configuration.mtp_policies[] as $policy |
        .configuration.effective_prompt_lengths[] as $effective |
        range(1; .configuration.samples_per_cell + 1) as $sample |
        ($policy + "-" + ($effective | tostring) + "-s" + ($sample | tostring))] | sort) as $expected_ids |
      .configuration.mtp_policies == ["on", "off", "dynamic"] and
      .configuration.dynamic_threshold == 32768 and
      .configuration.context_allocation == 262144 and .configuration.vision == true and
      .configuration.effective_prompt_lengths == [29000, 30000, 32767, 32768, 32769, 33868, 98304] and
      .configuration.warmups_per_cell == 1 and .configuration.samples_per_cell == 5 and
      .configuration.throughput_tolerance_percent == 5 and
      .configuration.comparison_metric == "generation_tokens_per_second" and
      (.configuration.correctness_harness_sha256 | type == "string" and
        test("^[0-9a-f]{64}$")) and
      ([.runs[].id] | sort) == $expected_ids and
      ([.runs[].id] | unique | length) == (.runs | length) and
      ($derived.statistics | length) == 21 and
      all($derived.statistics[]; .sample_count == $result.configuration.samples_per_cell) and
      ($derived.dynamic_fixed_comparisons | length) == 7 and
      .configuration.statistics == $derived.statistics and
      .configuration.dynamic_fixed_comparisons == $derived.dynamic_fixed_comparisons and
      .interpretation.performance_gate_passed == $derived.performance_gate_passed and
      (.configuration.accepted_allocation_observation as $allocation |
        ($allocation | keys | sort) == (["evidence_sha256", "observation"] | sort) and
        ($allocation.evidence_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        ($allocation.observation | type == "object")) and
      .configuration.accepted_allocation_observation.observation.identity.executable_sha256 ==
        .provenance.runtime.executable.sha256 and
      ([.validations[] | select(.check == "Dynamic-to-corresponding-fixed 5% generation-throughput tolerance") | .result] ==
        [(if $derived.performance_gate_passed then "Pass" else "Fail" end)]) and
      ([.validations[] | select(.check == "Accepted default 262,144-token allocation memory observation") | .result] ==
        ["Pass; sanitized RSS and system memory pressure captured"]) and
      all(.runs[]; . as $run |
        ($run.server_session_id | type == "string") and
        ($run.server_session_id | test("^(on|off|dynamic)-session-[0-9]+$") and
          startswith($run.mtp_policy + "-session-")) and
        any($result.configuration.server_log_sha256[];
          .policy == $run.mtp_policy and .session_id == $run.server_session_id))
    ' "$result_file" >/dev/null 2>&1
}

metal_llm_validate_result() {
    local result_file=$1
    local result_label=${2:-${result_file#$METAL_LLM_ROOT/}}
    local schema_file="$METAL_LLM_ROOT/schemas/result.schema.json"

    [[ -f "$schema_file" ]] || {
        metal_llm_die 'result schema is missing: schemas/result.schema.json'
        return 1
    }
    jq -e --slurpfile schema "$schema_file" '
      def resolved($spec):
        if ($spec | has("$ref")) then
          ($spec["$ref"] | split("/") | last) as $name |
          $schema[0]["$defs"][$name]
        else $spec end;
      def type_ok($value; $wanted):
        if ($wanted | type) == "array" then
          [$wanted[] | type_ok($value; .)] | any
        elif $wanted == "integer" then
          ($value | type) == "number" and ($value | floor) == $value
        else
          ($value | type) == $wanted
        end;
      def valid($value; $input_spec):
        resolved($input_spec) as $spec |
        (if $spec | has("const") then $value == $spec.const else true end) and
        (if $spec | has("enum") then [$spec.enum[] | . as $choice | $value == $choice] | any else true end) and
        (if $spec | has("type") then type_ok($value; $spec.type) else true end) and
        (if (($value | type) == "string" and ($spec | has("minLength"))) then
          ($value | length) >= $spec.minLength else true end) and
        (if (($value | type) == "string" and ($spec | has("pattern"))) then
          ($value | test($spec.pattern)) else true end) and
        (if (($value | type) == "string" and $spec.format? == "date") then
          (try ((($value + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $value) catch false)
         elif (($value | type) == "string" and $spec.format? == "date-time") then
          (try (($value | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false)
         else true end) and
        (if (($value | type) == "number" and ($spec | has("minimum"))) then
          $value >= $spec.minimum else true end) and
        (if ($value | type) == "object" then
          (if $spec | has("required") then
            [$spec.required[] | . as $key | $value | has($key)] | all
           else true end) and
          (if $spec.additionalProperties? == false then
            ($spec.properties // {} | keys) as $allowed |
            [$value | keys[] | . as $key | ($allowed | index($key)) != null] | all
           else true end) and
          (if $spec | has("properties") then
            [$spec.properties | to_entries[] | . as $property |
              if $value | has($property.key) then
                valid($value[$property.key]; $property.value)
              else true end] | all
           else true end)
         else true end) and
        (if ($value | type) == "array" then
          (if $spec | has("minItems") then ($value | length) >= $spec.minItems else true end) and
          (if $spec | has("items") then [$value[] | . as $item | valid($item; $spec.items)] | all else true end)
         else true end);
      valid(.; $schema[0])
    ' "$result_file" >/dev/null 2>&1 || {
        metal_llm_die "invalid result document: $result_label"
        return 1
    }

    jq -e '
      . as $root |
      def historical_route_unknown:
        .profile_id == null and .runtime_alias == null and .context == null and
        .mtp_policy == null and .mtp_selected == null and .mtp_threshold == null and
        .prompt_tokens == null;
      def local_runtime_only:
        .profile == null and .profile_id == null and
        (.runtime_alias == "tuned" or .runtime_alias == "upstream") and
        .context == null and .vision == null and .mtp_policy == null and
        .mtp_selected == null and .effective_prompt_tokens == null and .mtp_threshold == null;
      def endpoint_route:
        .profile == null and
        (.profile_id | type == "string" and length > 0) and
        (.runtime_alias == "tuned" or .runtime_alias == "upstream") and
        (.context | type == "number" and floor == . and . > 0) and
        (.vision | type == "boolean") and
        (.effective_prompt_tokens | type == "number" and floor == . and . >= 0) and
        .effective_prompt_tokens <= .context and
        (.mtp_selected | type == "boolean") and
        (if .mtp_policy == "dynamic" then
          (.mtp_threshold | type == "number" and floor == . and . > 0) and
          .mtp_selected == (.effective_prompt_tokens <= .mtp_threshold)
        elif .mtp_policy == "on" then
          .mtp_selected == true and .mtp_threshold == null
        elif .mtp_policy == "off" then
          .mtp_selected == false and .mtp_threshold == null
        else false end) and
        (if .runtime_alias == "upstream" then .mtp_policy == "off" else true end);
      def matches_common_provenance($provenance):
        .repository_revision == $provenance.repository.revision and
        .hardware_id == $provenance.hardware.id and
        .profile_id == $provenance.profile_id and
        .runtime_alias == $provenance.runtime_alias and
        .context == $provenance.context and .vision == $provenance.vision and
        .runtime_id == $provenance.runtime.id and
        .runtime_revision == $provenance.runtime.tested_revision;
      def matches_provenance($provenance):
        matches_common_provenance($provenance) and
        .mtp_policy == $provenance.mtp_policy and .mtp_threshold == $provenance.mtp_threshold;
      def multi_policy_endpoint_acceptance:
        .model_id == "qwen3.8-flash-next" and .suite_id == "dynamic-mtp-performance" and
        .configuration.acceptance_variant == "multi-policy-endpoint" and
        .configuration.mtp_policies == ["on", "off", "dynamic"] and
        .configuration.dynamic_threshold == 32768 and
        .provenance.hardware.id == "apple-m5-max-128gb" and
        .provenance.hardware.chip == "Apple M5 Max" and
        .provenance.hardware.unified_memory_bytes == 137438953472 and
        .provenance.profile_id == "custom" and .provenance.runtime_alias == "tuned" and
        .provenance.context == 262144 and .provenance.vision == true and
        .provenance.mtp_policy == null and .provenance.mtp_threshold == null and
        .provenance.runtime.id == "llama-cpp-qwen38-hybrid" and
        ([.runs[].mtp_policy] | unique) == ["dynamic", "off", "on"] and
        all(.runs[];
          endpoint_route and matches_common_provenance($root.provenance) and
          (if .mtp_policy == "dynamic" then
             .mtp_threshold == $root.configuration.dynamic_threshold
           else .mtp_threshold == null end));
      (if .benchmark_mode == "local" then
         .provenance != null and .suite_id == .provenance.suite.id and
         .provenance.profile_id == null and
         (.provenance.runtime_alias == "tuned" or .provenance.runtime_alias == "upstream") and
         .provenance.context == null and .provenance.vision == null and
         .provenance.mtp_policy == null and .provenance.mtp_threshold == null and
         .provenance.runtime.executable.name == "llama-bench"
       elif .benchmark_mode == "endpoint" then
         .provenance != null and .suite_id == .provenance.suite.id and
         (.provenance.profile_id | type == "string" and length > 0) and
         (.provenance.runtime_alias == "tuned" or .provenance.runtime_alias == "upstream") and
         (.provenance.context | type == "number" and floor == . and . > 0) and
         (.provenance.vision | type == "boolean") and
         .provenance.runtime.executable.name == "llama-server" and
         (if .provenance.mtp_policy == null then
            multi_policy_endpoint_acceptance
          else
            (.provenance.mtp_policy == "on" or .provenance.mtp_policy == "off" or
              .provenance.mtp_policy == "dynamic") and
            (if .provenance.mtp_policy == "dynamic" then
               (.provenance.mtp_threshold | type == "number" and floor == . and . > 0)
             else .provenance.mtp_threshold == null end) and
            (if .provenance.runtime_alias == "upstream" then .provenance.mtp_policy == "off" else true end)
          end)
       else
         .provenance == null and
         (has("benchmark_mode") | not) and (has("suite_id") | not)
       end) and
      all(.runs[];
        if $root.benchmark_mode == "local" then
          local_runtime_only and
          (if $root.provenance == null then true else matches_provenance($root.provenance) end)
        elif $root.benchmark_mode == "endpoint" then
          endpoint_route and
          (if $root.provenance.mtp_policy == null then
             matches_common_provenance($root.provenance) and
             (if .mtp_policy == "dynamic" then
                .mtp_threshold == $root.configuration.dynamic_threshold
              else .mtp_threshold == null end)
           else matches_provenance($root.provenance) end)
        else
          historical_route_unknown
        end)
    ' "$result_file" >/dev/null 2>&1 || {
        metal_llm_die "invalid benchmark route provenance: $result_label"
        return 1
    }

    if [[ "$(jq -r '.configuration.acceptance_variant // empty' "$result_file")" == \
        multi-policy-endpoint ]]; then
        metal_llm_validate_dynamic_mtp_derived_data "$result_file" || {
            metal_llm_die "invalid dynamic-MTP derived data: $result_label"
            return 1
        }
    fi

    local unsafe_path secret_key
    unsafe_path=$(jq -r '[.. | strings | select(test("/" + "Users" + "/[^/[:space:]]+/"))][0] // empty' \
      "$result_file") || return 1
    [[ -z "$unsafe_path" ]] || {
        metal_llm_die "unsafe private path in $result_label"
        return 1
    }
    secret_key=$(jq -r '[.. | objects | keys[] |
      select(test("(^|[_-])(api[_-]?key|access[_-]?token|token|password|secret)($|[_-])"; "i"))][0] // empty' \
      "$result_file") || return 1
    [[ -z "$secret_key" ]] || {
        metal_llm_die "secret-like key in $result_label: $secret_key"
        return 1
    }

    local hardware_id runtime_id
    for hardware_id in "${(@f)$(jq -r '.runs[].hardware_id' "$result_file" | sort -u)}"; do
        [[ -f "$METAL_LLM_ROOT/manifests/hardware/$hardware_id.json" ]] || {
            metal_llm_die "unknown hardware id: $hardware_id"
            return 1
        }
    done
    for runtime_id in "${(@f)$(jq -r '.runs[].runtime_id' "$result_file" | sort -u)}"; do
        [[ -f "$METAL_LLM_ROOT/manifests/runtimes/$runtime_id.json" ]] || {
            metal_llm_die "unknown runtime id: $runtime_id"
            return 1
        }
    done
}

metal_llm_generate_summary() {
    local result_file=$1
    local raw_name=${result_file:t}
    jq -r --arg raw_name "$raw_name" '
      def comma:
        tostring | if length <= 3 then . else
          (length % 3) as $first |
          if $first == 0 then 3 else $first end as $head |
          .[0:$head] + ([.[ $head: ] | scan(".{3}")] | if length == 0 then "" else "," + join(",") end)
        end;
      def shown($field; $display):
        if .[$field] == null then "n/a"
        elif has($display) then .[$display]
        else (.[$field] | tostring) end;
      def compact_k:
        if . % 1000 == 0 then ((. / 1000) | tostring) + "K"
        else ((. / 1000) | tostring) + "K" end;
      def percent_change($base; $new):
        (((($new / $base - 1) * 1000) | round) / 10) as $percent |
        (if $percent > 0 then "+" else "" end) + ($percent | tostring) + "%";
      def table($rows): $rows | join("\n");
      . as $root |
      ([.runs[] | select(.id == "matched-no-mtp")][0]) as $matched_off |
      ([.runs[] | select(.id == "matched-mtp")][0]) as $matched_on |
      ([.runs[] | select(.id == "retrieval-96k-mtp")][0]) as $retrieval |
      ([.runs[] | select(.id == "image-99405-no-mtp")][0]) as $image_long |
      ([.runs[] | select(.id == "text-single-98338-no-mtp")][0]) as $text_long |
      [
        "# " + .summary.title,
        "",
        "> Generated by `metal-llm report` from [`../raw/" + $raw_name + "`](../raw/" + $raw_name + "). Do not edit this file by hand.",
        "",
        "These are machine-specific measurements captured on " + .date + ". Single runs, three-run means, sample standard deviations, interpolation, interpretation, and future work are labeled separately.",
        "",
        "## Runtime comparison (three-run means)",
        "",
        "| Runtime | Cache depth | Prompt tok/s | Generation tok/s |",
        "| --- | ---: | ---: | ---: |"
      ] +
      ([.runs[] | select(.experiment == "runtime-comparison") |
        "| " + .notes + " | " + (.cache_depth | comma) + " | " + shown("prompt_tokens_per_second"; "prompt_tokens_per_second_display") + " | " + shown("generation_tokens_per_second"; "generation_tokens_per_second_display") + " |"] ) +
      [
        "",
        .interpretation.runtime_comparison_limit,
        "",
        "## Matched short-context MTP A/B (single runs)",
        "",
        "| Mode | Generation tok/s | Draft acceptance | Output |",
        "| --- | ---: | ---: | --- |"
      ] +
      ([.runs[] | select(.experiment == "matched-mtp-ab") |
        "| " + (if .mtp then "MTP on, max " + ($root.configuration.mtp_draft_n_max | tostring) + " draft tokens" else "MTP off" end) + " | " + shown("generation_tokens_per_second"; "generation_tokens_per_second_display") + " | " + (.draft_acceptance // "n/a") + " | " + (if .output_equivalence == "byte_identical" then "Byte-identical" else .output_equivalence end) + " |"] ) +
      [
        "",
        "The recorded matched run " +
          (if $matched_on.generation_tokens_per_second > $matched_off.generation_tokens_per_second then
             "improved from " + ($matched_off | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " to " + ($matched_on | shown("generation_tokens_per_second"; "generation_tokens_per_second_display"))
           elif $matched_on.generation_tokens_per_second < $matched_off.generation_tokens_per_second then
             "declined from " + ($matched_off | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " to " + ($matched_on | shown("generation_tokens_per_second"; "generation_tokens_per_second_display"))
           else
             "was unchanged at " + ($matched_on | shown("generation_tokens_per_second"; "generation_tokens_per_second_display"))
           end) +
          " tok/s (" + percent_change($matched_off.generation_tokens_per_second; $matched_on.generation_tokens_per_second) + ")" +
          (if $matched_on.output_equivalence == "byte_identical" then " and produced byte-identical output."
           elif $matched_on.output_equivalence == "diverged" then " and the outputs diverged."
           else " and output equivalence was not compared." end) +
          " This one comparison does not establish universal output equivalence.",
        "",
        "## Long-context retrieval and validation",
        "",
        "| Check | Result |",
        "| --- | --- |"
      ] +
      ([.validations[] | "| " + .check + " | " + .result + " |"] ) +
      [
        "",
        "The " + ($retrieval.effective_prompt_tokens | comma) + "-token retrieval ran at " + ($retrieval | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " tok/s with " + (if $retrieval.mtp then "MTP enabled" else "MTP disabled" end) + ". A " + (.interpretation.retrieval_initial_output_budget_tokens | tostring) + "-token output budget clipped visible content after reasoning; a cached retry with " + (.interpretation.retrieval_retry_output_budget_tokens | tostring) + " returned the full key.",
        "",
        "## Attached-image crossover (single runs)",
        "",
        "| Effective prompt tokens | No MTP | MTP | Draft acceptance |",
        "| ---: | ---: | ---: | ---: |"
      ] +
      ([.runs | group_by(.effective_prompt_tokens)[] |
        select(.[0].experiment == "attached-image-crossover") |
        (map(select(.mtp == false))[0]) as $off |
        (map(select(.mtp == true))[0]) as $on |
        "| " + (.[0].effective_prompt_tokens | comma) + " | " + ($off | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " | " + ($on | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " | " + $on.draft_acceptance + " |"] ) +
      [
        "",
        "Measured crossover bracket: " + (.interpretation.attached_image_crossover_bracket_tokens[0] | comma) + "–" + (.interpretation.attached_image_crossover_bracket_tokens[1] | comma) + " effective prompt tokens. Linear interpolation gives approximately " + (.interpretation.attached_image_interpolation_tokens_approximate | compact_k) + ". " + .interpretation.crossover_limit,
        "",
        "## Vision-loaded, text-only boundary (three-run means and sample SD)",
        "",
        "| Prompt tokens | No MTP mean | No MTP SD | MTP mean | MTP SD | MTP change |",
        "| ---: | ---: | ---: | ---: | ---: | ---: |"
      ] +
      ([.runs | group_by(.effective_prompt_tokens)[] |
        select(.[0].experiment == "text-boundary-mean") |
        (map(select(.mtp == false))[0]) as $off |
        (map(select(.mtp == true))[0]) as $on |
        "| " + (.[0].effective_prompt_tokens | comma) + " | " + ($off | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " | " + ($off.generation_tokens_per_second_sd_display // ($off.generation_tokens_per_second_sd | tostring)) + " | " + ($on | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " | " + ($on.generation_tokens_per_second_sd_display // ($on.generation_tokens_per_second_sd | tostring)) + " | " + $on.change_display + " |"] ) +
      [
        "",
        "## Vision-loaded, text-only calibration (single runs)",
        "",
        "| Prompt tokens | No MTP | MTP |",
        "| ---: | ---: | ---: |"
      ] +
      ([.runs | group_by(.effective_prompt_tokens)[] |
        select(.[0].experiment == "text-boundary-single") |
        (map(select(.mtp == false))[0]) as $off |
        (map(select(.mtp == true))[0]) as $on |
        "| " + (.[0].effective_prompt_tokens | comma) + " | " + ($off | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " | " + ($on | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " |"] ) +
      [
        "",
        "The no-MTP measurements at " + ($image_long.effective_prompt_tokens | comma) + " effective tokens with an attached image (" + ($image_long | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " tok/s) and at " + ($text_long.effective_prompt_tokens | comma) + " text tokens with the projector resident (" + ($text_long | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " tok/s) correct any implication that the earlier " + ($retrieval | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " tok/s MTP retrieval number represented no-MTP performance.",
        "",
        "## Interpretation and limits",
        "",
        "The repeated general-purpose gray zone is approximately " + (.interpretation.general_purpose_gray_zone_tokens_approximate[0] | comma) + "–" + (.interpretation.general_purpose_gray_zone_tokens_approximate[1] | comma) + " effective tokens. " + .interpretation.routing_guidance,
        "",
        .interpretation.output_behavior,
        "",
        .interpretation.limitation
      ] +
      (if any(.runs[]; .mtp_policy != null) then
        [
          "",
          "## MTP route provenance",
          "",
          "| Run | Configured policy | Selected route | Effective prompt tokens | Threshold |",
          "| --- | --- | --- | ---: | ---: |"
        ] +
        [.runs[] | select(.mtp_policy != null) |
          "| " + .id + " | " + .mtp_policy + " | " +
          (if .mtp_selected then "on" else "off" end) + " | " +
          (.effective_prompt_tokens | comma) + " | " +
          (if .mtp_threshold == null then "n/a" else (.mtp_threshold | comma) end) + " |"]
       else [] end) | table(.)
    ' "$result_file"
}

metal_llm_generate_dynamic_mtp_summary() {
    local result_file=$1
    local raw_name=${result_file:t}
    local derived
    derived=$(metal_llm_dynamic_mtp_derived_data "$result_file") || return 1
    jq -r --arg raw_name "$raw_name" --argjson derived "$derived" '
      def comma:
        tostring | if length <= 3 then . else
          (length % 3) as $first |
          if $first == 0 then 3 else $first end as $head |
          .[0:$head] + ([.[ $head: ] | scan(".{3}")] |
            if length == 0 then "" else "," + join(",") end)
        end;
      def route: if . then "on" else "off" end;
      def signed_percent:
        (if . > 0 then "+" else "" end) + (tostring) + "%";
      def absolute: if . < 0 then -. else . end;
      def table($rows): $rows | join("\n");
      ($derived.dynamic_fixed_comparisons |
        min_by(.tolerance_percent - (.percent_delta | absolute))) as $narrowest |
      [
        "# " + .summary.title,
        "",
        "> Generated by `metal-llm report` from [`../raw/" + $raw_name + "`](../raw/" + $raw_name + "). Do not edit this file by hand.",
        "",
        "Acceptance result: **" + (if .interpretation.performance_gate_passed then "PASS" else "FAIL" end) + "** on " + .provenance.hardware.chip + " with " + ((.provenance.hardware.unified_memory_bytes / 1073741824) | tostring) + " GiB unified memory.",
        "",
        "## Method",
        "",
        "One full-model server at a time measured fixed MTP on, fixed MTP off, and dynamic routing with vision loaded and a " + (.configuration.context_allocation | comma) + "-token allocation. Each of the 21 cells used one warm-up followed by five retained samples with identical generation settings. Dynamic MTP selects on at or below " + (.configuration.dynamic_threshold | comma) + " effective tokens and off above it.",
        "",
        "Collection: " + .configuration.collection_started + " through " + .configuration.collection_completed + ". Comparison metric: generation tokens per second; predeclared tolerance: ±" + (.configuration.throughput_tolerance_percent | tostring) + "%.",
        "",
        "## Dynamic versus corresponding fixed route",
        "",
        "| Effective prompt tokens | Dynamic route | Dynamic mean | Fixed mean | Delta | Result |",
        "| ---: | --- | ---: | ---: | ---: | --- |"
      ] +
      [$derived.dynamic_fixed_comparisons[] |
        "| " + (.effective_prompt_tokens | comma) + " | " +
        (.dynamic_selected_route | route) + " | " +
        (.dynamic_generation_tokens_per_second_mean | tostring) + " | " +
        (.fixed_generation_tokens_per_second_mean | tostring) + " | " +
        (.percent_delta | signed_percent) + " | " +
        (if .passed then "Pass" else "Fail" end) + " |"] +
      [
        "",
        "## Per-cell measurements",
        "",
        "| Policy | Effective prompt tokens | Selected route | Samples | Generation mean | Sample SD | Draft accepted/generated | Distinct outputs |",
        "| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |"
      ] +
      [$derived.statistics[] |
        "| " + .policy + " | " + (.effective_prompt_tokens | comma) + " | " +
        (.selected_route | route) + " | " + (.sample_count | tostring) + " | " +
        (.generation_tokens_per_second_mean | tostring) + " | " +
        (.generation_tokens_per_second_sample_sd | tostring) + " | " +
        (.draft_accepted | tostring) + "/" + (.draft_generated | tostring) + " | " +
        (.distinct_output_count | tostring) + " |"] +
      [
        "",
        "## Acceptance validations",
        "",
        "| Check | Result |",
        "| --- | --- |"
      ] +
      [.validations[] | "| " + .check + " | " + .result + " |"] +
      [
        "",
        "## Accepted default allocation observation",
        "",
        "The exact default `auto` configuration was observed healthy at " +
          .configuration.accepted_allocation_observation.observation.captured_at +
          " with server RSS " +
          (.configuration.accepted_allocation_observation.observation.process.rss_bytes | tostring) +
          " bytes and system-wide effective free memory " +
          (.configuration.accepted_allocation_observation.observation.system_memory_pressure.free_percent | tostring) +
          "%. This is a point-in-time allocation observation, not a peak-memory claim.",
        "",
        "- Observation evidence: `" + .configuration.accepted_allocation_observation.evidence_sha256 + "`",
        "- Managed process identity: `" + .configuration.accepted_allocation_observation.observation.identity.managed_process_sha256 + "`",
        "- Accepted-run server log: `" + .configuration.accepted_allocation_observation.observation.identity.server_log_sha256 + "`"
      ] +
      [
        "",
        "## Reproducibility identities",
        "",
        "- Repository revision: `" + .provenance.repository.revision + "`",
        "- Repository tree: `" + .provenance.repository.tree_sha + "`",
        "- Runtime revision/tree: `" + .provenance.runtime.tested_revision + "` / `" + .provenance.runtime.tested_tree_sha + "`",
        "- Runtime manifest/build receipt/executable: `" + .provenance.runtime.manifest_sha256 + "` / `" + .provenance.runtime.build_receipt_sha256 + "` / `" + .provenance.runtime.executable.sha256 + "`",
        "- Model manifest: `" + .provenance.model_manifest_sha256 + "`",
        "- Correctness evidence: `" + .configuration.correctness_evidence_sha256 + "`",
        "- Correctness harness: `" + .configuration.correctness_harness_sha256 + "`",
        "- Checkpoint identity: `" + .configuration.checkpoint_identity_sha256 + "`"
      ] +
      [.configuration.server_log_sha256[] |
        "- " + .policy + " server log (`" + .session_id + "`): `" + .sha256 + "`"] +
      [
        "",
        "## Limitations",
        "",
        .interpretation.limitation,
        "The " + ($narrowest.percent_delta | signed_percent) + " result at " +
          ($narrowest.effective_prompt_tokens | comma) +
          " effective tokens passes by only " +
          (((($narrowest.tolerance_percent - ($narrowest.percent_delta | absolute)) * 100000) | round) / 100000 | tostring) +
          " percentage points; treat that boundary comparison as narrow-margin evidence rather than a broad performance claim."
      ] | table(.)
    ' "$result_file"
}

metal_llm_generate_generic_summary() {
    local result_file=$1
    jq -r '
      def comma:
        tostring | if length <= 3 then . else
          (length % 3) as $first |
          if $first == 0 then 3 else $first end as $head |
          .[0:$head] + ([.[ $head: ] | scan(".{3}")] | if length == 0 then "" else "," + join(",") end)
        end;
      def shown($field; $display):
        if .[$field] == null then "n/a"
        elif has($display) then .[$display]
        else (.[$field] | tostring) end;
      [
        "# Benchmark result: " + .experiment_id,
        "",
        "| Run | Experiment | Prompt tokens | Effective prompt tokens | MTP policy | Selected route | Generated tokens | Prompt tok/s | Generation tok/s |",
        "| --- | --- | ---: | ---: | --- | --- | ---: | ---: | ---: |"
      ] +
      [.runs[] |
        "| " + .id + " | " + .experiment + " | " + (if .prompt_tokens == null then "n/a" else (.prompt_tokens | comma) end) +
        " | " + (if .effective_prompt_tokens == null then "n/a" else (.effective_prompt_tokens | comma) end) +
        " | " + (.mtp_policy // "n/a") +
        " | " + (if .mtp_selected == null then "n/a" elif .mtp_selected then "on" else "off" end) +
        " | " + (if .generated_tokens == null then "n/a" else (.generated_tokens | comma) end) + " | " +
        shown("prompt_tokens_per_second"; "prompt_tokens_per_second_display") + " | " +
        shown("generation_tokens_per_second"; "generation_tokens_per_second_display") + " |"
      ] | join("\n")
    ' "$result_file"
}

metal_llm_report() {
    local check=0
    if (( $# > 1 )); then
        metal_llm_report_usage
        return $?
    fi
    if (( $# == 1 )); then
        [[ "$1" == --check ]] || { metal_llm_report_usage; return $?; }
        check=1
    fi
    command -v jq >/dev/null 2>&1 || { metal_llm_die 'jq is required'; return 1; }

    local result_file output_name summary_path generated temporary_summary
    typeset -a result_files
    result_files=("$METAL_LLM_ROOT"/results/raw/*.json(N))
    (( ${#result_files} > 0 )) || { metal_llm_die 'no raw result documents found'; return 1; }

    for result_file in "${result_files[@]}"; do
        metal_llm_validate_result "$result_file" || return 1
        output_name=$(jq -r '.summary.output // empty' "$result_file") || return 1
        if [[ -z "$output_name" ]]; then
            if (( check == 0 )); then
                metal_llm_generate_generic_summary "$result_file" || return 1
            fi
            continue
        fi
        summary_path="$METAL_LLM_ROOT/results/summaries/$output_name"
        if [[ "$(jq -r '.configuration.acceptance_variant // empty' "$result_file")" == \
            multi-policy-endpoint ]]; then
            generated=$(metal_llm_generate_dynamic_mtp_summary "$result_file") || return 1
        else
            generated=$(metal_llm_generate_summary "$result_file") || return 1
        fi
        if (( check == 1 )); then
            [[ -f "$summary_path" ]] || {
                metal_llm_die "summary is missing: ${summary_path#$METAL_LLM_ROOT/}"
                return 1
            }
            cmp -s <(print -r -- "$generated") "$summary_path" || {
                metal_llm_die "summary differs from generated output: ${summary_path#$METAL_LLM_ROOT/}"
                return 1
            }
        else
            mkdir -p "$summary_path:h"
            temporary_summary=$(mktemp "$summary_path.part.XXXXXX") || return 1
            if ! print -r -- "$generated" > "$temporary_summary"; then
                rm -f -- "$temporary_summary"
                return 1
            fi
            mv -f -- "$temporary_summary" "$summary_path" || return 1
            print -r -- "$generated"
        fi
    done
}
