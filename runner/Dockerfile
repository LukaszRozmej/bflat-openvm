# Transpiles and executes a bflat-built OpenVM guest ELF and prints the 32-byte
# public-values window. Nethermind's guest publishes keccak256 of its result
# there, because the window is fixed-size and the result is not.
#
# WHY THIS EXISTS. OpenVM publishes no image at all - cargo-openvm is a source
# install - and the CLI's `run` only accepts a transpiled .vmexe, not an ELF.
# Consumers would each have to build the SDK from source, which is the long
# pole in any job that touches it. They pull this instead.
#
#   docker run --rm -v "$PWD:/n" nethermindeth/openvm-runner:v2.1.0-rv64 \
#       /n/nethermind /n/openvm.toml /n/input.raw
#
# Pass "-" instead of a config path to use the extension set shipped in the
# image (/openvm.toml), which matches what the bindings expose.
#
# The input is RAW SSZ, as for SP1: the test bucket's .ssz files are ZisK-framed.
#
# OPENVM_REV is on the rv64 line (branch develop-v2.1.0). `main` is still rv32
# and rejects a 64-bit ELF outright, so this is not a version preference. Pinned
# to a commit rather than the branch so the image is reproducible.
FROM rust:1.91-bookworm AS build
ARG OPENVM_REV=56d5e4dbb545662f7ba3c31ac6c3e0ab1c6a481d
WORKDIR /src
RUN apt-get update \
 && apt-get install -y --no-install-recommends git pkg-config libssl-dev cmake \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --filter=blob:none https://github.com/openvm-org/openvm.git . \
 && git checkout "${OPENVM_REV}"
COPY Cargo.toml crates/runelf/Cargo.toml
COPY src crates/runelf/src
# Prepend the harness to the workspace members so it builds against the
# workspace's own openvm-sdk/toml/hex/eyre versions - the reason it lives here
# rather than as a standalone crate with git dependencies.
RUN sed -i '0,/^members = \[/s//members = [\n    "crates\/runelf",/' Cargo.toml \
 && grep -q 'crates/runelf' Cargo.toml
RUN cargo test --release -p openvm-runelf \
 && cargo build --release -p openvm-runelf

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/openvm-runelf /usr/local/bin/openvm-runelf
# Default extension set, used when the caller passes "-" for the config.
COPY openvm.toml /openvm.toml
ENTRYPOINT ["/usr/local/bin/openvm-runelf"]
