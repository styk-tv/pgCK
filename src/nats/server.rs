//! Minimal NATS Core server: TcpListener accept loop on :4222.
//! Handles INFO/CONNECT/PING/PONG/SUB/UNSUB/PUB and MSG fan-out.
//! No SPI coupling here; the bgworker only hosts the listener for S3.

use std::io;

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{tcp::OwnedReadHalf, tcp::OwnedWriteHalf, TcpListener, TcpStream};
use tokio::sync::broadcast;

use crate::nats::parser::{parse_line, ClientMsg};
use crate::nats::router::Router;

const INFO: &str =
    "INFO {\"server_name\":\"pgck\",\"version\":\"0.1.9\",\"max_payload\":1048576}\r\n";
const MAX_PAYLOAD: usize = 1024 * 1024;

#[derive(Clone, Debug)]
struct Delivery {
    subject: String,
    reply: Option<String>,
    payload: Vec<u8>,
}

pub async fn run(bind: &str) -> io::Result<()> {
    let listener = TcpListener::bind(bind).await?;
    serve(listener).await
}

async fn serve(listener: TcpListener) -> io::Result<()> {
    let (tx, _) = broadcast::channel::<Delivery>(1024);

    loop {
        let (socket, _) = listener.accept().await?;
        let tx = tx.clone();
        let rx = tx.subscribe();

        tokio::spawn(async move {
            let _ = handle_client(socket, tx, rx).await;
        });
    }
}

async fn handle_client(
    socket: TcpStream,
    tx: broadcast::Sender<Delivery>,
    mut rx: broadcast::Receiver<Delivery>,
) -> io::Result<()> {
    let (reader, mut writer) = socket.into_split();
    let mut reader = BufReader::new(reader);
    let mut router = Router::new();

    writer.write_all(INFO.as_bytes()).await?;

    loop {
        tokio::select! {
            message = read_client_message(&mut reader) => {
                match message? {
                    Some(ClientMsg::Connect(_)) | Some(ClientMsg::Pong) => {}
                    Some(ClientMsg::Ping) => writer.write_all(b"PONG\r\n").await?,
                    Some(ClientMsg::Sub { subject, sid, .. }) => router.add(sid, subject),
                    Some(ClientMsg::Unsub { sid, .. }) => router.remove(&sid),
                    Some(ClientMsg::Pub { subject, reply, payload, .. }) => {
                        let _ = tx.send(Delivery {
                            subject,
                            reply,
                            payload,
                        });
                    }
                    None => break,
                }
            }
            delivery = rx.recv() => {
                match delivery {
                    Ok(delivery) => {
                        for sid in router.matching(&delivery.subject) {
                            write_msg(&mut writer, &delivery, &sid).await?;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }

    Ok(())
}

async fn read_client_message(
    reader: &mut BufReader<OwnedReadHalf>,
) -> io::Result<Option<ClientMsg>> {
    let mut line = Vec::new();
    let bytes_read = reader.read_until(b'\n', &mut line).await?;
    if bytes_read == 0 {
        return Ok(None);
    }

    let line = decode_control_line(&line)?;
    let mut message = parse_line(&line)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid NATS control line"))?;

    if let ClientMsg::Pub {
        payload_len,
        ref mut payload,
        ..
    } = message
    {
        if payload_len > MAX_PAYLOAD {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("payload exceeds max_payload of {MAX_PAYLOAD} bytes"),
            ));
        }

        payload.resize(payload_len, 0);
        reader.read_exact(payload).await?;

        let mut terminator = [0_u8; 2];
        reader.read_exact(&mut terminator).await?;
        if terminator != *b"\r\n" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "payload missing CRLF terminator",
            ));
        }
    }

    Ok(Some(message))
}

fn decode_control_line(bytes: &[u8]) -> io::Result<String> {
    let line = std::str::from_utf8(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "control line is not utf-8"))?;

    Ok(line.trim_end_matches(['\r', '\n']).to_string())
}

async fn write_msg(writer: &mut OwnedWriteHalf, delivery: &Delivery, sid: &str) -> io::Result<()> {
    let header = match &delivery.reply {
        Some(reply) => format!(
            "MSG {} {} {} {}\r\n",
            delivery.subject,
            sid,
            reply,
            delivery.payload.len()
        ),
        None => format!(
            "MSG {} {} {}\r\n",
            delivery.subject,
            sid,
            delivery.payload.len()
        ),
    };

    writer.write_all(header.as_bytes()).await?;
    writer.write_all(&delivery.payload).await?;
    writer.write_all(b"\r\n").await
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;
    use std::time::Duration;

    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
    use tokio::net::{tcp::OwnedReadHalf, tcp::OwnedWriteHalf, TcpListener, TcpStream};
    use tokio::task::JoinHandle;
    use tokio::time::timeout;

    use super::serve;

    #[tokio::test(flavor = "current_thread")]
    async fn sends_info_banner_and_pong() {
        let (server, addr) = spawn_server().await;
        let (mut reader, mut writer) = connect(addr).await;

        let info = read_line(&mut reader).await;
        assert!(info.starts_with("INFO "));
        assert!(info.contains("\"server_name\":\"pgck\""));
        assert!(info.contains("\"version\":\"0.1.9\""));
        assert!(info.contains(&format!("\"max_payload\":{}", super::MAX_PAYLOAD)));

        writer.write_all(b"PING\r\n").await.unwrap();
        assert_eq!(read_line(&mut reader).await, "PONG\r\n");

        server.abort();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn publishes_payload_to_matching_subscribers() {
        let (server, addr) = spawn_server().await;
        let (mut subscriber_reader, mut subscriber_writer) = connect(addr).await;
        let _ = read_line(&mut subscriber_reader).await;

        subscriber_writer
            .write_all(b"SUB event.demo.> 1\r\n")
            .await
            .unwrap();
        subscriber_writer.write_all(b"PING\r\n").await.unwrap();
        assert_eq!(read_line(&mut subscriber_reader).await, "PONG\r\n");

        let (_publisher_reader, mut publisher_writer) = connect(addr).await;
        publisher_writer
            .write_all(b"PUB event.demo.Hello.created 5\r\nhello\r\n")
            .await
            .unwrap();

        assert_eq!(
            read_line(&mut subscriber_reader).await,
            "MSG event.demo.Hello.created 1 5\r\n"
        );
        assert_eq!(read_line(&mut subscriber_reader).await, "hello\r\n");

        server.abort();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn unsub_stops_delivery() {
        let (server, addr) = spawn_server().await;
        let (mut subscriber_reader, mut subscriber_writer) = connect(addr).await;
        let _ = read_line(&mut subscriber_reader).await;

        subscriber_writer
            .write_all(b"SUB event.demo.> 1\r\nUNSUB 1\r\n")
            .await
            .unwrap();
        subscriber_writer.write_all(b"PING\r\n").await.unwrap();
        assert_eq!(read_line(&mut subscriber_reader).await, "PONG\r\n");

        let (_publisher_reader, mut publisher_writer) = connect(addr).await;
        publisher_writer
            .write_all(b"PUB event.demo.Hello.created 5\r\nhello\r\n")
            .await
            .unwrap();

        let mut line = String::new();
        assert!(timeout(
            Duration::from_millis(200),
            subscriber_reader.read_line(&mut line)
        )
        .await
        .is_err());

        server.abort();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn oversized_pub_is_rejected_immediately() {
        let (server, addr) = spawn_server().await;
        let (mut reader, mut writer) = connect(addr).await;
        let _ = read_line(&mut reader).await;

        let payload_len = super::MAX_PAYLOAD + 1;
        writer
            .write_all(format!("PUB event.demo.too-big {}\r\n", payload_len).as_bytes())
            .await
            .unwrap();

        let mut buf = [0_u8; 1];
        let bytes_read = timeout(Duration::from_millis(200), reader.read(&mut buf))
            .await
            .expect("server should reject oversized PUB without waiting for a payload body")
            .unwrap();
        assert_eq!(bytes_read, 0, "oversized PUB should close the connection");

        server.abort();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn max_payload_pub_is_accepted() {
        let (server, addr) = spawn_server().await;
        let (mut subscriber_reader, mut subscriber_writer) = connect(addr).await;
        let _ = read_line(&mut subscriber_reader).await;

        subscriber_writer
            .write_all(b"SUB event.demo.max 1\r\n")
            .await
            .unwrap();
        subscriber_writer.write_all(b"PING\r\n").await.unwrap();
        assert_eq!(read_line(&mut subscriber_reader).await, "PONG\r\n");

        let payload = vec![b'a'; super::MAX_PAYLOAD];
        let (_publisher_reader, mut publisher_writer) = connect(addr).await;
        publisher_writer
            .write_all(format!("PUB event.demo.max {}\r\n", payload.len()).as_bytes())
            .await
            .unwrap();
        publisher_writer.write_all(&payload).await.unwrap();
        publisher_writer.write_all(b"\r\n").await.unwrap();

        assert_eq!(
            read_line(&mut subscriber_reader).await,
            format!("MSG event.demo.max 1 {}\r\n", super::MAX_PAYLOAD)
        );

        let mut received = vec![0_u8; super::MAX_PAYLOAD + 2];
        timeout(
            Duration::from_secs(3),
            subscriber_reader.read_exact(&mut received),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(&received[..super::MAX_PAYLOAD], payload.as_slice());
        assert_eq!(&received[super::MAX_PAYLOAD..], b"\r\n");

        server.abort();
    }

    async fn spawn_server() -> (JoinHandle<()>, SocketAddr) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = serve(listener).await;
        });
        (server, addr)
    }

    async fn connect(addr: SocketAddr) -> (BufReader<OwnedReadHalf>, OwnedWriteHalf) {
        let stream = timeout(Duration::from_secs(1), TcpStream::connect(addr))
            .await
            .unwrap()
            .unwrap();
        let (reader, writer) = stream.into_split();
        (BufReader::new(reader), writer)
    }

    async fn read_line(reader: &mut BufReader<OwnedReadHalf>) -> String {
        let mut line = String::new();
        timeout(Duration::from_secs(1), reader.read_line(&mut line))
            .await
            .unwrap()
            .unwrap();
        line
    }
}
