# Execution harness for an OpenVM RV32 guest: the counterpart of runner/ for
# OpenVM's `main` line, which proves RV32IM.
#
#   docker run --rm -v "$PWD:/n" nethermindeth/openvm-runner:<rv32 tag> \
#       /n/nethermind /n/input.raw
#
# Prints the 32-byte public-values window, the retired instructions and the
# trace cost (src/main.rs). The input is raw SSZ, as for runner/.
#
# OPENVM_REV is on `main`. Pinned to a commit so the image is reproducible.
FROM rust:1.91-bookworm AS build
ARG OPENVM_REV=d218a6dd20127bf576f4c986b836b6c81567b327
WORKDIR /src
RUN apt-get update \
 && apt-get install -y --no-install-recommends git pkg-config libssl-dev cmake \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --filter=blob:none https://github.com/openvm-org/openvm.git . \
 && git checkout "${OPENVM_REV}"
COPY Cargo.toml crates/runelf32/Cargo.toml
COPY src crates/runelf32/src
RUN sed -i '0,/^members = \[/s//members = [\n    "crates\/runelf32",/' Cargo.toml \
 && grep -q 'crates/runelf32' Cargo.toml
RUN cargo build --release -p openvm-runelf32

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/openvm-runelf /usr/local/bin/openvm-runelf
ENTRYPOINT ["/usr/local/bin/openvm-runelf"]
