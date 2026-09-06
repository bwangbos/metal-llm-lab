# Extended fast/stable context sweep on Apple M5 Max 128 GB

Vision on, text-only repeated-token prompts; one warm-up and three retained samples per cell.
Each response generates 128 tokens. Ceiling prompts leave 256 tokens of space.
Values are mean ± sample standard deviation in tokens/s. All retained responses passed count, truncation, and uncached-prefill checks. MTP routing was checked where exposed; stable's MTP-off configuration is recorded in its managed session identity.

| Profile | Prompt tokens | Prefill tok/s | Generation tok/s | MTP selected |
| --- | ---: | ---: | ---: | :---: |
| fast-equivalent (256K custom) | 128 | 576.84 ± 0.33 | 86.40 ± 0.15 | on |
| fast-equivalent (256K custom) | 32,768 | 985.27 ± 10.25 | 47.45 ± 0.12 | on |
| fast-equivalent (256K custom) | 65,536 | 754.58 ± 12.76 | 31.72 ± 0.42 | on |
| fast-equivalent (256K custom) | 98,304 | 683.65 ± 6.48 | 25.20 ± 0.08 | on |
| fast-equivalent (256K custom) | 131,072 | 676.76 ± 40.90 | 22.22 ± 1.03 | on |
| fast-equivalent (256K custom) | 163,840 | 637.44 ± 18.09 | 19.34 ± 0.07 | on |
| fast-equivalent (256K custom) | 196,608 | 597.96 ± 2.20 | 16.89 ± 0.05 | on |
| fast-equivalent (256K custom) | 229,376 | 562.36 ± 27.62 | 14.87 ± 0.72 | on |
| fast-equivalent (256K custom) | 261,888 | 536.36 ± 11.60 | 13.76 ± 0.03 | on |
| stable-equivalent (256K custom) | 128 | 470.07 ± 4.41 | 39.78 ± 0.23 | off |
| stable-equivalent (256K custom) | 32,768 | 748.43 ± 16.07 | 30.18 ± 0.74 | off |
| stable-equivalent (256K custom) | 65,536 | 651.20 ± 1.46 | 24.50 ± 0.30 | off |
| stable-equivalent (256K custom) | 98,304 | 601.26 ± 6.13 | 20.70 ± 0.36 | off |
| stable-equivalent (256K custom) | 131,072 | 559.90 ± 3.90 | 18.25 ± 0.26 | off |
| stable-equivalent (256K custom) | 163,840 | 530.55 ± 2.56 | 15.74 ± 0.12 | off |
| stable-equivalent (256K custom) | 196,608 | 490.17 ± 5.05 | 14.07 ± 0.03 | off |
| stable-equivalent (256K custom) | 229,376 | 453.19 ± 9.62 | 12.62 ± 0.01 | off |
| stable-equivalent (256K custom) | 261,888 | 454.77 ± 0.53 | 11.76 ± 0.01 | off |

Evidence: [measurements.json](measurements.json).
Protocol and limitations: [experiment notes](../../../docs/experiments/2026-09-06-extended-context-sweep.md).
