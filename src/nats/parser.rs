//! NATS Core client->server verb parser. Subset: CONNECT, PING, PONG,
//! PUB, SUB, UNSUB. (INFO/MSG/+OK/-ERR are server->client.)

#[derive(Debug, PartialEq)]
pub enum ClientMsg {
    Connect(String),
    Ping,
    Pong,
    Sub {
        subject: String,
        queue: Option<String>,
        sid: String,
    },
    Unsub {
        sid: String,
        max: Option<u64>,
    },
    Pub {
        subject: String,
        reply: Option<String>,
        payload: Vec<u8>,
    },
}

/// Parse one client control line. Payload bytes, if any, are handled by the
/// caller after the control line has been parsed.
pub fn parse_line(line: &str) -> Option<ClientMsg> {
    let mut it = line.split_whitespace();

    match it.next()?.to_ascii_uppercase().as_str() {
        "PING" => Some(ClientMsg::Ping),
        "PONG" => Some(ClientMsg::Pong),
        "CONNECT" => Some(ClientMsg::Connect(line[7..].trim().to_string())),
        "SUB" => {
            let subject = it.next()?.to_string();
            let a = it.next()?;
            let b = it.next();

            match b {
                Some(sid) => Some(ClientMsg::Sub {
                    subject,
                    queue: Some(a.to_string()),
                    sid: sid.to_string(),
                }),
                None => Some(ClientMsg::Sub {
                    subject,
                    queue: None,
                    sid: a.to_string(),
                }),
            }
        }
        "UNSUB" => {
            let sid = it.next()?.to_string();
            let max = it.next().and_then(|s| s.parse().ok());

            Some(ClientMsg::Unsub { sid, max })
        }
        "PUB" => {
            let subject = it.next()?.to_string();
            let parts: Vec<_> = it.collect();
            let (reply, count) = match parts.as_slice() {
                [count] => (None, *count),
                [reply, count] => (Some((*reply).to_string()), *count),
                _ => return None,
            };

            let _payload_len: usize = count.parse().ok()?;

            Some(ClientMsg::Pub {
                subject,
                reply,
                payload: Vec::new(),
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping() {
        assert_eq!(parse_line("PING"), Some(ClientMsg::Ping));
    }

    #[test]
    fn sub_no_queue() {
        assert_eq!(
            parse_line("SUB input.demo.Hello.create 1"),
            Some(ClientMsg::Sub {
                subject: "input.demo.Hello.create".into(),
                queue: None,
                sid: "1".into(),
            })
        );
    }

    #[test]
    fn pub_with_reply() {
        assert_eq!(
            parse_line("PUB a.b _INBOX.1 5"),
            Some(ClientMsg::Pub {
                subject: "a.b".into(),
                reply: Some("_INBOX.1".into()),
                payload: vec![],
            })
        );
    }
}
