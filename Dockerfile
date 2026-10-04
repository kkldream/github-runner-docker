FROM ubuntu:22.04

ARG RUNNER_VERSION=2.337.0
ARG RUNNER_SHA256=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613

ENV DEBIAN_FRONTEND=noninteractive

RUN arch="$(dpkg --print-architecture)" \
    && if [ "$arch" != "amd64" ]; then \
         echo "Unsupported architecture: $arch. This image currently supports linux/amd64 only." >&2; \
         exit 1; \
       fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       docker.io \
       git \
       gzip \
       iproute2 \
       jq \
       libcurl4 \
       libgcc-s1 \
       libicu70 \
       libkrb5-3 \
       liblttng-ust1 \
       libssl3 \
       libstdc++6 \
       libunwind8 \
       openssh-client \
       tar \
       tini \
       tzdata \
       zlib1g \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /actions-runner

RUN archive="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${archive}" \
    && curl --fail --location --show-error \
         --retry 3 --retry-delay 2 --retry-connrefused \
         --output "${archive}" "${url}" \
    && echo "${RUNNER_SHA256}  ${archive}" | sha256sum --check --strict \
    && tar xzf "${archive}" \
    && rm "${archive}" \
    && ./bin/installdependencies.sh \
    && docker --version

RUN groupadd -g 1001 runner \
    && useradd -m -u 1001 -g runner runner \
    && chown -R runner:runner /actions-runner

ENV RUNNER_URL="" \
    RUNNER_NAME="github-runner-docker" \
    RUNNER_GROUP="Default" \
    RUNNER_LABELS="docker" \
    RUNNER_WORKDIR="_work" \
    RUNNER_REPLACE="false" \
    RUNNER_EPHEMERAL="false" \
    RUNNER_DOCKER_ENABLED="false" \
    RUNNER_MANUALLY_TRAP_SIG="1"

COPY --chown=runner:runner entrypoint.sh /actions-runner/entrypoint.sh
RUN chmod +x /actions-runner/entrypoint.sh

USER runner

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/actions-runner/entrypoint.sh"]
