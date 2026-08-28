# Build Docker. ONE image, TWO entrypoints: /bin/snake-royale (the game server,
# which also makes every LLM call, because the game pod is the only container
# the platform injects the anthropic_api_key coworld secret into) and
# /bin/snake-royale-player (the thin snake seat registrar). The policy set is
# env-switched inside this same image (PLAYER_PROMPT vs PLAYER_SCRIPTED), which
# is what keeps a champion and a scripted filler byte-identical apart from
# their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/snake
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/snake-royale-nimcache \
  --out:snake-royale \
  src/snake_royale.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/snake-royale-player-nimcache \
  --out:snake-royale-player \
  src/snake_royale_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/snake
COPY --from=build /workspace/snake/snake-royale /bin/snake-royale
COPY --from=build /workspace/snake/snake-royale-player /bin/snake-royale-player
COPY --from=build /workspace/snake/*.json ./
COPY --from=build /workspace/snake/data ./data
COPY --from=build /workspace/snake/client ./client

CMD ["/bin/snake-royale"]
