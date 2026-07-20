# Tasks

## 1. Adapter
- [ ] 1.1 `scripts/aoai-suggester.py` (IMDS token, AOAI json_schema call,
      mechanical id, fail-closed merge/validate)
- [ ] 1.2 `scripts/test_aoai_suggester.py` (network-free; stub `_imds_token` /
      `_call_aoai`; assert mechanical id + fail-closed cases)
- [ ] 1.3 Wire into `test/run-tests.sh`

## 2. Degrade-to-green
- [ ] 2.1 Guard the `SUGGESTER_CMD` call in `scripts/run-mining.sh`
- [ ] 2.2 Scenario in `scripts/test_run_mining.sh` (mineable shape +
      `SUGGESTER_CMD=false` → exit 0 + skip line)

## 3. Terraform
- [ ] 3.1 AOAI account + gpt-4o deployment + role assignment
- [ ] 3.2 Runner `.env` wiring (`KUSKUS_AOAI_*`) + outputs
- [ ] 3.3 `fmt -check` + `validate`

## 4. Workflow
- [ ] 4.1 `SUGGESTER_CMD` in `kuskus-report.yml`

## 5. Docs
- [ ] 5.1 Rewrite `scripts/suggest-rule.md` real-provider section
- [ ] 5.2 This openspec change; `openspec validate --strict`
