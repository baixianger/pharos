# Learn Rust through Iroh

This tutorial teaches the Rust syntax needed to understand Iroh, then uses that
syntax to build and reason about a small peer-to-peer system. It is based on the
current official Iroh 1.x documentation and was checked against:

- `iroh 1.0.3`
- `iroh-gossip 0.101.0`
- `iroh-tickets 1.0.0`
- Rust 1.91 or newer

The notebook is written in Chinese, with English API names preserved so it is
easy to move between the tutorial, Rust compiler errors, and upstream docs.

## Install the Rust Jupyter kernel

Install Rust with [rustup](https://rustup.rs/), then:

```bash
cargo install --locked evcxr_jupyter
evcxr_jupyter --install
python3 -m pip install --user jupyterlab
```

Launch the notebook from this directory:

```bash
cd tutorials/iroh-rust-notebook
python3 -m jupyter lab iroh-official-tour.ipynb
```

The first dependency cell may take several minutes because Evcxr compiles the
Iroh dependency graph. Later cells reuse that compiled cache.

## A compile-checked companion example

The notebook contains small, independently executable cells. The same local
echo experiment is also provided as a normal Rust binary:

```bash
cargo run --bin local-echo
```

It starts two Iroh endpoints in one process, negotiates a versioned ALPN,
exchanges one message over a bidirectional QUIC stream, then shuts down. It has
timeouts, so a broken networking experiment does not wait forever.

## Reading order

1. Rust expressions, bindings, ownership, borrowing, enums, `Result`, and `?`
2. `async`/`.await`, tasks, and bounded waits
3. Iroh endpoint identity and endpoint addresses
4. A real two-endpoint QUIC exchange
5. ALPN protocol routing and tickets
6. Gossip and when not to use it
7. Production practices and their Pharos/MeshKit equivalents

The notebook intentionally distinguishes three layers:

- **Transport identity:** Iroh `EndpointId`
- **Reachability hints:** direct addresses, relays, discovery, and tickets
- **Application authority:** Pharos membership epochs, admin roles, and signed
  domain events

An encrypted Iroh connection authenticates an endpoint key. It does not, by
itself, decide whether that endpoint is an authorized Pharos device.

## Official references

- [What is Iroh?](https://docs.iroh.computer/what-is-iroh)
- [Quickstart](https://docs.iroh.computer/quickstart)
- [Connect two endpoints](https://docs.iroh.computer/connect-two-endpoints)
- [Endpoints](https://docs.iroh.computer/concepts/endpoints)
- [Tickets](https://docs.iroh.computer/concepts/tickets)
- [Protocols and ALPN](https://docs.iroh.computer/concepts/protocols)
- [Using QUIC](https://docs.iroh.computer/protocols/using-quic)
- [Gossip](https://docs.iroh.computer/connecting/gossip)
- [Security and privacy](https://docs.iroh.computer/deployment/security-privacy)
- [Troubleshooting](https://docs.iroh.computer/troubleshooting)
- [`iroh` Rust API](https://docs.rs/iroh/1.0.3/iroh/)
- [`iroh-gossip` Rust API](https://docs.rs/iroh-gossip/0.101.0/iroh_gossip/)
