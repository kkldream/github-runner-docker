FROM ubuntu:22.04

# Install required tools
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    tar \
    gzip \
    tzdata \
    openssh-client \
    iproute2 \
    libicu70 \
    libssl3 \
    libkrb5-3 \
    zlib1g \
    libgcc-s1 \
    libstdc++6 \
    libunwind8 \
    liblttng-ust1 \
    libcurl4 && rm -rf /var/lib/apt/lists/*

# Work in actions-runner directory
WORKDIR /actions-runner

# Download the runner package
RUN curl -L -o actions-runner-linux-x64-2.328.0.tar.gz https://github.com/actions/runner/releases/download/v2.328.0/actions-runner-linux-x64-2.328.0.tar.gz

# Extract the installer
RUN tar xzf actions-runner-linux-x64-2.328.0.tar.gz

# Install runner dependencies
RUN ./bin/installdependencies.sh

# Create non-root user and take ownership
RUN groupadd -g 1001 runner && useradd -m -u 1001 -g runner runner && \
    chown -R runner:runner /actions-runner

# Provide configurable defaults via environment variables
ENV RUNNER_URL="" \
    RUNNER_NAME="github-runner-docker" \
    RUNNER_GROUP="Default" \
    RUNNER_LABELS="docker" \
    RUNNER_WORKDIR="_work" \
    RUNNER_REPLACE="true" \
    RUNNER_EPHEMERAL="false"

# Drop privileges to non-root user
COPY --chown=runner:runner entrypoint.sh /actions-runner/entrypoint.sh
RUN chmod +x /actions-runner/entrypoint.sh

USER runner

# Use exec/JSON form to ensure proper signal handling
ENTRYPOINT ["/actions-runner/entrypoint.sh"]
