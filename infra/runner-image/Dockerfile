# Ephemeral self-hosted runner for the Kuskus calibration/mining pipeline.
#
# Base = myoung34/github-runner: it wraps the official actions runner and already
# handles GitHub App auth + `--ephemeral` registration from APP_ID / APP_LOGIN /
# APP_PRIVATE_KEY, so we don't hand-roll JWT minting. We add only the pipeline
# toolchain. NO .NET SDK: the scanner is a shipped NativeAOT binary pulled per
# run via `gh release download kql-guard-linux-x64` (release.yml publishes it),
# so this image never rebuilds when kql-guard changes.
#
# Toolchain: az (blob watermark sync + MI login), python3 + azure-kusto-data
# (the fetch), gh (release download + PR open), jq.
FROM myoung34/github-runner:2.335.1-ubuntu-noble

USER root

# Pinned to match the runner-only dependency in scripts/manifest.schema.md.
ARG AZURE_KUSTO_DATA_VERSION=6.0.4

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip jq ca-certificates curl && \
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash && \
    if ! command -v gh >/dev/null 2>&1; then \
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
      echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
      apt-get update && apt-get install -y --no-install-recommends gh; \
    fi && \
    pip3 install --no-cache-dir --break-system-packages "azure-kusto-data==${AZURE_KUSTO_DATA_VERSION}" && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Smoke check at build time — fail the build if any tool is missing.
RUN python3 -c "import azure.kusto.data" && az version && gh --version && jq --version

# Base image's entrypoint (runner registration + run) is preserved; it expects root.
