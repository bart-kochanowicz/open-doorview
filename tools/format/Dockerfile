# The C formatter (clang-format of Debian 12). Kept apart from tools/build/Dockerfile so that installing it can never
# change the pinned cross compiler.
FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends clang-format \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
