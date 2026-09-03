metal_llm_report_usage() {
    metal_llm_error 'usage: metal-llm report [--check]'
    return 2
}

metal_llm_validate_result() {
    local result_file=$1
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
        metal_llm_die "invalid result document: ${result_file#$METAL_LLM_ROOT/}"
        return 1
    }

    local unsafe_path secret_key
    unsafe_path=$(jq -r '[.. | strings | select(startswith("/" + "Users" + "/"))][0] // empty' "$result_file") || return 1
    [[ -z "$unsafe_path" ]] || {
        metal_llm_die "unsafe private path in ${result_file#$METAL_LLM_ROOT/}"
        return 1
    }
    secret_key=$(jq -r '[.. | objects | keys[] |
      select(test("(^|[_-])(api[_-]?key|access[_-]?token|token|password|secret)($|[_-])"; "i"))][0] // empty' \
      "$result_file") || return 1
    [[ -z "$secret_key" ]] || {
        metal_llm_die "secret-like key in ${result_file#$METAL_LLM_ROOT/}: $secret_key"
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
        (if $percent >= 0 then "+" else "" end) + ($percent | tostring) + "%";
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
        "The recorded matched run improved from " + ($matched_off | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " to " + ($matched_on | shown("generation_tokens_per_second"; "generation_tokens_per_second_display")) + " tok/s (" + percent_change($matched_off.generation_tokens_per_second; $matched_on.generation_tokens_per_second) + ")" +
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
        "| Run | Experiment | Prompt tokens | Generated tokens | Prompt tok/s | Generation tok/s |",
        "| --- | --- | ---: | ---: | ---: | ---: |"
      ] +
      [.runs[] |
        "| " + .id + " | " + .experiment + " | " + (.effective_prompt_tokens | comma) +
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
        generated=$(metal_llm_generate_summary "$result_file") || return 1
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
