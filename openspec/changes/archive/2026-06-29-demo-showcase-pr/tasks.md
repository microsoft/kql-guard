## 1. Demo fixture

- [x] 1.1 Add `demo/detections/SuspiciousSignin.kql`: misformatted, `contains`, no time filter, typo'd column.
- [x] 1.2 Add `demo/schema.json`: SigninLogs with the real columns the rule uses (typo excluded).
- [x] 1.3 Verify locally: scan fires cost rules, `--schema` fires KQL101, `fmt --check` shows a diff, `--max-cost 1` exits 1.

## 2. CI showcase

- [x] 2.1 Add demo steps to the workflow over `demo/` (scan+SARIF, --max-cost, --schema, fmt --check), each `continue-on-error` so the run completes and uploads SARIF.

## 3. Ship

- [x] 3.1 Commit to a demo branch, push to fork, open PR to microsoft/kql-guard with the 5-beat exec narration in the body.
- [x] 3.2 Confirm inline annotations + red gate render on the open PR.
