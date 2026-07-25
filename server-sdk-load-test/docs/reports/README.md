# Published AKS k6 report artifacts

These files preserve the public evidence selected for the repository README.

## Latest retained report

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

Distributed k6 creates one HTML report per runner. The retained report is a
conservative representative artifact, not a merged 10,000-connection report.
Use the matrix JSON for aggregate conclusions.
