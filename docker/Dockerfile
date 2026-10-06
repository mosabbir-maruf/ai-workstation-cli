FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/sandbox \
    NPM_CONFIG_PREFIX=/home/sandbox/.npm-global \
    PATH=/home/sandbox/.npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/sbin:/usr/bin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        passwd \
        curl \
        git \
        openssh-client \
        ripgrep \
        fd-find \
        procps \
        tini \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable \
    && npm install --prefix /usr/local -g --force pnpm \
    && rm -rf /root/.npm \
    && echo 'export PATH="/home/sandbox/.npm-global/bin:$PATH"' > /etc/profile.d/npm-global.sh \
    && chmod 0644 /etc/profile.d/npm-global.sh

RUN useradd \
    --create-home \
    --shell /bin/bash \
    --uid 1001 \
    sandbox \
    && echo 'PS1="\[\033[1;36m\]\u\[\033[1;30m\]@\[\033[1;36m\]aiws\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ "' >> /home/sandbox/.bashrc

RUN mkdir -p \
        /home/sandbox/.npm-global \
        /home/sandbox/.dsh \
        /workspace \
    && chown -R sandbox:sandbox \
        /home/sandbox \
        /workspace

COPY --chown=sandbox:sandbox docker/entrypoint.sh \
    /usr/local/bin/entrypoint.sh

COPY --chown=sandbox:sandbox docker/app-runner.sh \
    /usr/local/bin/app-runner.sh

COPY --chown=sandbox:sandbox docker/harness.sh \
    /usr/local/bin/harness.sh

COPY --chown=sandbox:sandbox docker/github-app-credential-helper \
    /usr/local/bin/github-app-credential-helper

RUN chmod 0755 \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/app-runner.sh \
    /usr/local/bin/harness.sh \
    /usr/local/bin/github-app-credential-helper

LABEL org.opencontainers.image.title="AIWS CLI" \
      org.opencontainers.image.description="Docker container environment for AIWS CLI" \
      org.opencontainers.image.source="https://github.com/mosabbir-maruf/aiws-cli" \
      org.opencontainers.image.licenses="MIT"

WORKDIR /workspace

USER sandbox

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

CMD ["sleep", "infinity"]
