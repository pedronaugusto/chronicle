# zjournal — a Linux with the pinned Zig in it, and nothing else.
#
# ci/linux.sh builds this and runs the suite inside it, so that the file
# behaviour this package promises is proved on the kernel a daemon runs on and
# not only on the one the author is typing on. Debian for the libc a released
# binary is likely to meet; the toolchain is fetched by version so the image is
# reproducible from this file alone.

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
ARG ZIG=0.16.0
RUN set -e; arch=$(uname -m); \
    for name in "zig-${arch}-linux-${ZIG}" "zig-linux-${arch}-${ZIG}"; do \
      if curl -fsSL "https://ziglang.org/download/${ZIG}/${name}.tar.xz" -o /tmp/zig.tar.xz; then break; fi; done; \
    mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
WORKDIR /src
