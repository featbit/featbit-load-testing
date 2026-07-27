# Published AKS k6 report artifacts

These files preserve the public evidence selected for the repository README.

## Multi-environment G5 baseline

This baseline keeps the existing 10,000-connection AKS topology but distributes
connections across 100 environments. Only one target environment receives the
ten measured revisions, so each revision has 100 target samples. The validation
run and all three formal runs passed connection health, warm-up, formal
coverage, Redis-observer, isolation, fixed-resource, and evidence gates.

- [Complete multi-environment report](aks-10k-multi-environment-g5-d4-els3.md)
- [Machine-readable multi-environment result](aks-10k-multi-environment-g5-d4-els3.json)
- [Exact multi-environment matrix](../../k8s-infra/matrices/aks-multi-environment-g5-d4-els3.json)

| Artifact | SHA-256 |
| --- | --- |
| Report Markdown | `40019eedc0d180ae6bc8374ca2aeb17fdc748998692c85ed5c17d1f08ab7cd96` |
| Report JSON | `86b3bab2a373eff268b0048052f5e4539c98f6b83954f3d64d970feeadb03e66` |
| Matrix JSON | `1d0524295fa209712e84765b1c8c546b8c06e2aa06ae11b1c9f326b49067364b` |

The old single-environment G5 change fanned out to 10,000 connections; the
multi-environment change fans out to 100. The reports therefore define separate
baselines and do not label one faster or slower than the other.

## Latest Three-stage G5 replay

The latest retained run replayed the historical G5 topology with 10,000
WebSockets, 20 × 500 k6 runners on ten D4 loadgen nodes, and three ELS Pods
spread across three D4 FeatBit nodes. The canonical
`probe_sync_latency_ms` boundary is earliest Redis publication observation to
SDK apply.

- [Complete report](aks-10k-three-stage-g5-d4.md)
- [Machine-readable summary](aks-10k-three-stage-g5-d4.json)
- [Rendered Three-stage summary](aks-10k-three-stage-g5-d4.html)
- [One-second resource evidence](aks-10k-three-stage-g5-d4-node-evidence-1s.md)
- [Resource evidence JSON](aks-10k-three-stage-g5-d4-node-evidence-1s.json)
- [Exact experiment matrix](../../k8s-infra/matrices/aks-three-stage-g5-d4-els3.json)
- [Selected-run connection ramp health](aks-10k-ramp-health.json)

### Latest retained k6 artifact

Distributed k6 produces one HTML report per runner. Runner 17 is retained
because it had the highest overall raw `FeatureFlag.UpdatedAt → SDK` p99 among
the latest run's 20 runners. It is a conservative 500-connection runner view,
not a merged 10,000-connection report; use the aggregate Three-stage JSON for
the canonical Redis-observer boundary.

| Field | Value |
| --- | --- |
| Run ID | `growth-20260726-164117-6c29992e-0491` |
| Retained runner | 17 of 20 |
| Runner connections / formal samples | 500 / 5,000 |
| Raw average / p95 / p99 / maximum | 74.13 / 141.05 / 229 / 256 ms |
| HTML SHA-256 | `451189e330d6c0307c0e56b6da56a6ca25b881bbb6f9f5e5f6c396b732874904` |
| Aggregate Markdown SHA-256 | `bca0ecec4fbbae79f54b3fbcf1b46655d66b8c7592ffb546a6a3992bddc97208` |
| Aggregate JSON SHA-256 | `0f5bacc13da9c39ca6b5fb1c93fd75ab39f49b354014d5742cb967f4d1031c90` |
| Matrix SHA-256 | `e95a3902468f98c12e1ee6880b1473ef3b50487cb08d92d5b44143bb5246e8d6` |
| Ramp-health JSON SHA-256 | `cd0cd0f367c78ebb747e02a7a2a9eac53c64fe5f7ac32aa89000fd381f97ec6b` |

- [Versioned latest k6 HTML](aks-10k-three-stage-g5-d4-runner-17.html)

After these changes reach `main`, the Pages workflow publishes the k6 HTML at
`https://featbit.github.io/featbit-load-testing/reports/aks-10k-three-stage-g5-d4-runner-17.html`.

## Latest receiver-path diagnostic

The latest campaign kept 10,000 service-routed WebSockets and added a
10-loadgen × 6-ELS direct sentinel matrix. All three fresh repetitions passed.
Across 30 revisions it detected three pre-registered loadgen-row waves; one
survived a same-node observer sensitivity analysis that removes the
receiver's cross-node clock/observer offset. Both views had zero ELS-column
and zero global waves. This identifies the loadgen receive path as one real
tail-latency contributor without modifying FeatBit source.

- [Complete sentinel result](aks-10k-els-loadgen-sentinel.md)
- [Machine-readable sentinel result](aks-10k-els-loadgen-sentinel.json)
- [Exact sentinel matrix](../../k8s-infra/matrices/aks-els-loadgen-sentinel.json)

### Retained sentinel k6 artifact

| Field | Value |
| --- | --- |
| Run ID | `growth-20260726-052542-ce333a5f-ad79` |
| Repetition | 3 |
| Retained runner | 1 of 20 |
| Selection rule | Highest per-revision raw p99 among the final run's 20 runners |
| Runner connections / formal samples | 500 / 5,000 |
| Overall raw p99 / maximum | 169 / 181 ms |
| Worst per-revision raw p99 | 180 ms |
| HTML SHA-256 | `ac0cc0848d0995ef21a42f817f9d334884d0134abe023177d19a22a25ca8db6a` |
| Runner JSON SHA-256 | `29459ae5be2ce4432032b98c4796c86d53d108e4fcfdf14e73b34787c9a0773e` |
| Aggregate Markdown SHA-256 | `10ddc253970c905e24a94ef5ebef29279f08fb301bc46b1da9de7c4de9ed01d3` |
| Aggregate JSON SHA-256 | `47845dc3592cc9a5fdfd2955e1a04b11daf94bde3b79a865800df45df38bb541` |
| Matrix SHA-256 | `19c5403791364738090ae007acb13f21616d33b79868a3cf4a659eb7d4f84c59` |

- [Versioned latest k6 HTML](aks-10k-els-loadgen-sentinel-run3-runner-1.html)
- [Versioned latest runner summary](aks-10k-els-loadgen-sentinel-run3-runner-1-summary.json)

After these changes reach `main`, the Pages workflow publishes the HTML at
`https://featbit.github.io/featbit-load-testing/reports/aks-10k-els-loadgen-sentinel-run3-runner-1.html`.
The runner HTML shows one conservative representative, not a merged
10,000-connection report. Its raw latency is
`FeatureFlag.UpdatedAt → SDK`; use the aggregate sentinel report for the
canonical Redis-observer → SDK streaming metric and the cross-run conclusion.

## Three-stage latency report

The new canonical `probe_sync_latency_ms` is
`streaming_delivery_latency_ms`: earliest Redis publication observation to
SDK apply. A fresh 10,000-connection run preserves all three stages and the
legacy raw clock without changing FeatBit source code.

- [Rendered three-stage HTML](aks-10k-stage-latency-validation.html)
- [Complete three-stage report](aks-10k-stage-latency-validation.md)
- [Machine-readable three-stage summary](aks-10k-stage-latency-validation.json)
- [Exact validation matrix](../../k8s-infra/matrices/aks-stage-latency-validation.json)

| Artifact | SHA-256 |
| --- | --- |
| HTML | `f0f0ef737d571d1f4db9adcc2c676d110af64e42599c12c5b7dc63887a94603b` |
| JSON | `32efd8981931b70b116b95381a06427eab2c1877599cfdc2ced55ef8a83321e0` |
| Markdown | `171c544fb3d9f981f5b497f62d59f4352f6d0d0a24e71ca3e5642a86788a37f8` |

After these changes reach `main`, the Pages workflow publishes the HTML at
`https://featbit.github.io/featbit-load-testing/reports/aks-10k-stage-latency-validation.html`.

## Previous quota-safe aggregate result

The latest validated campaign uses 6 × D2 FeatBit nodes, 10 × D4 loadgen
nodes, six ELS Pods placed one per FeatBit node, and 20 × 500 runners. All
three 10,000-connection repetitions passed. The conservative p99 median was
283.01 ms with a 252–299.01 ms range.

The capacity artifacts below predate the three-stage observer. Their
`probe_sync_latency_ms` label retains the historical
`FeatureFlag.UpdatedAt → SDK` meaning; the three-stage report above owns the
new canonical meaning.

- [Complete full/de-jittered/resource report](aks-10k-d4-loadgen-d2-featbit-1s.md)
- [Machine-readable result](aks-10k-d4-loadgen-d2-featbit-1s.json)
- [Exact experiment matrix](../../k8s-infra/matrices/aks-10k-d4-loadgen-d2-featbit-1s.json)

This aggregate campaign produces 20 runner HTML files per repetition. The
previously published g2 report below remains the stable online HTML until a
new representative runner artifact is intentionally promoted through the
Pages workflow; it is not overwritten by the aggregate report.

### Current campaign representative artifact

| Field | Value |
| --- | --- |
| Matrix group | 20 runners × 500 connections, 6 ELS Pods / 6 D2 nodes |
| Run ID | `growth-20260725-130514-ce333a5f-1519` |
| Repetition | 3 |
| Retained runner | 3 of 20 |
| Selection rule | Highest overall `probe_sync_latency_ms p99` among the 20 runners in the best-primary-p99 repetition |
| Runner samples | 5,000 |
| Runner p99 / maximum | 235.01 ms / 251 ms |
| HTML SHA-256 | `2afc481220a5966863f14b90fe82722a1f0ae11f090238923821be757a92bc80` |
| Runner JSON SHA-256 | `9d975e63345b318adc43220167f638b19a3789ef9e5a1aeeda7b2ff89bcab7d2` |
| Matrix JSON SHA-256 | `d4feb0d96c4288e54fb985b7f37a44445d686b3393e73eea399da794b1d4c6bd` |

- [Versioned current HTML](aks-10k-d4-loadgen-d2-featbit-run3-runner-3.html)
- [Current runner summary JSON](aks-10k-d4-loadgen-d2-featbit-run3-runner-3-summary.json)

The Pages workflow will publish this versioned path after these repository
changes reach `main`. Until that deployment succeeds, the verified online URL
below remains the public report.

## Currently deployed online report

| Field | Value |
| --- | --- |
| Matrix group | g2: 40 runners × 250 connections, 6 ELS Pods / 3 nodes |
| Run ID | `growth-20260724-230351-fdf299e3-980a` |
| Repetition | 3 |
| Retained runner | 15 of 40 |
| Selection rule | Highest overall `probe_sync_latency_ms p99` among the 40 runners in the final run |
| Runner samples | 2,500 |
| Runner p99 / maximum | 230 ms / 232 ms |
| HTML SHA-256 | `61c17ac6c07306d3b571612992ea7a919e0826a19343cc17af333593ec8dfb01` |
| Runner JSON SHA-256 | `dc6a23e1c9e29e94b112f3ca275b4f38836674f2f1b06b7f8d9979f4c49b0253` |
| Matrix JSON SHA-256 | `2aab7314a711e017c3d2fd32609b82d6cb6077eb6c74d81e963f8ab20a7cb9f3` |

- [Rendered report on GitHub Pages](https://featbit.github.io/featbit-load-testing/reports/aks-10k-g2-run3-runner-15.html)
- [Versioned HTML](aks-10k-g2-run3-runner-15.html)
- [Runner summary JSON](aks-10k-g2-run3-runner-15-summary.json)
- [Five-group best-run and de-jitter report](aks-p99-capacity-10k-best-runs.md)
- [Five-group best-run machine-readable JSON](aks-p99-capacity-10k-best-runs.json)
- [Complete matrix summary](aks-p99-capacity-10k-summary.md)
- [Complete matrix JSON](aks-p99-capacity-10k-summary.json)
- [Quota-constrained D2 node-isolation diagnostic](aks-10k-d2-node-isolation-1s.md)
- [D2 diagnostic machine-readable JSON](aks-10k-d2-node-isolation-1s.json)
- [Quota-safe D4-loadgen validation](aks-10k-d4-loadgen-d2-featbit-1s.md)
- [D4-loadgen validation machine-readable JSON](aks-10k-d4-loadgen-d2-featbit-1s.json)

Distributed k6 creates one HTML report per runner. The retained report is a
conservative representative artifact, not a merged 10,000-connection report.
Use the matrix JSON for aggregate conclusions.

GitHub Pages was enabled in Actions mode and the retained URL was verified
with HTTP 200 on 2026-07-25.

The D2-loadgen diagnostic is intentionally not promoted as a validated online
k6 artifact: one runner/revision crossed the p95 threshold, and one-second
evidence shows loadgen scheduling pressure. Its complete raw and filtered
results remain available for reproducibility and root-cause work. The newer
D4-loadgen campaign passed all three repetitions and is the aggregate source
of truth; the retained online HTML remains a single-runner illustration.
