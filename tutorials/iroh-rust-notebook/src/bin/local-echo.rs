use std::time::Duration;

use anyhow::{Context, Result};
use iroh::{
    Endpoint,
    endpoint::{Connection, presets},
    protocol::{AcceptError, ProtocolHandler, Router},
};
use tokio::time::timeout;

const ECHO_ALPN: &[u8] = b"/pharos/tutorial/echo/1";
const MAX_MESSAGE_BYTES: usize = 64 * 1024;
const NETWORK_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone)]
struct Echo;

impl ProtocolHandler for Echo {
    async fn accept(
        &self,
        connection: Connection,
    ) -> std::result::Result<(), AcceptError> {
        let (mut send, mut receive) = connection.accept_bi().await?;
        let message = receive
            .read_to_end(MAX_MESSAGE_BYTES)
            .await
            .map_err(AcceptError::from_err)?;
        send.write_all(&message)
            .await
            .map_err(AcceptError::from_err)?;
        send.finish()?;
        connection.closed().await;
        Ok(())
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let server_endpoint = Endpoint::bind(presets::N0).await?;
    let server_address = server_endpoint.addr();
    let server = Router::builder(server_endpoint)
        .accept(ECHO_ALPN, Echo)
        .spawn();

    let client = Endpoint::bind(presets::N0).await?;
    let connection = timeout(
        NETWORK_TIMEOUT,
        client.connect(server_address, ECHO_ALPN),
    )
    .await
    .context("timed out connecting to the local Iroh endpoint")??;

    let (mut send, mut receive) = connection.open_bi().await?;
    send.write_all(b"hello from Rust + Iroh").await?;
    send.finish()?;

    let reply = timeout(
        NETWORK_TIMEOUT,
        receive.read_to_end(MAX_MESSAGE_BYTES),
    )
    .await
    .context("timed out waiting for the echo reply")??;

    println!("reply: {}", String::from_utf8(reply)?);

    connection.close(0u8.into(), b"tutorial complete");
    client.close().await;
    server.shutdown().await?;
    Ok(())
}
