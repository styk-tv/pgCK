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
        payload_len: usize,
        payload: Vec<u8>,
    },
}

/// Parse one client control line. Payload bytes, if any, are handled by the
/// caller after the control line has been parsed.
pub fn parse_line(line: &str) -> Option<ClientMsg> {
    let mut it = line.split_whitespace();
    let verb = it.next()?;
    let args: Vec<_> = it.collect();

    match verb.to_ascii_uppercase().as_str() {
        "PING" if args.is_empty() => Some(ClientMsg::Ping),
        "PONG" if args.is_empty() => Some(ClientMsg::Pong),
        "CONNECT" => parse_connect(line),
        "SUB" => match args.as_slice() {
            [subject, sid] => Some(ClientMsg::Sub {
                subject: (*subject).to_string(),
                queue: None,
                sid: (*sid).to_string(),
            }),
            [subject, queue, sid] => Some(ClientMsg::Sub {
                subject: (*subject).to_string(),
                queue: Some((*queue).to_string()),
                sid: (*sid).to_string(),
            }),
            _ => None,
        },
        "UNSUB" => match args.as_slice() {
            [sid] => Some(ClientMsg::Unsub {
                sid: (*sid).to_string(),
                max: None,
            }),
            [sid, max] => Some(ClientMsg::Unsub {
                sid: (*sid).to_string(),
                max: Some(max.parse().ok()?),
            }),
            _ => None,
        },
        "PUB" => match args.as_slice() {
            [subject, payload_len] => Some(ClientMsg::Pub {
                subject: (*subject).to_string(),
                reply: None,
                payload_len: payload_len.parse().ok()?,
                payload: Vec::new(),
            }),
            [subject, reply, payload_len] => Some(ClientMsg::Pub {
                subject: (*subject).to_string(),
                reply: Some((*reply).to_string()),
                payload_len: payload_len.parse().ok()?,
                payload: Vec::new(),
            }),
            _ => None,
        },
        _ => None,
    }
}

fn parse_connect(line: &str) -> Option<ClientMsg> {
    let trimmed = line.trim_start();
    let verb_end = trimmed.find(char::is_whitespace)?;
    let remainder = trimmed[verb_end..].trim();

    if remainder.is_empty() {
        return None;
    }

    Some(ClientMsg::Connect(remainder.to_string()))
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
    fn sub_with_queue() {
        assert_eq!(
            parse_line("SUB input.demo.Hello.create workers 1"),
            Some(ClientMsg::Sub {
                subject: "input.demo.Hello.create".into(),
                queue: Some("workers".into()),
                sid: "1".into(),
            })
        );
    }

    #[test]
    fn sub_rejects_extra_tokens() {
        assert_eq!(parse_line("SUB a workers 1 extra"), None);
    }

    #[test]
    fn pub_with_reply() {
        assert_eq!(
            parse_line("PUB a.b _INBOX.1 5"),
            Some(ClientMsg::Pub {
                subject: "a.b".into(),
                reply: Some("_INBOX.1".into()),
                payload_len: 5,
                payload: vec![],
            })
        );
    }

    #[test]
    fn pub_retains_payload_len() {
        assert_eq!(
            parse_line("PUB a.b 6"),
            Some(ClientMsg::Pub {
                subject: "a.b".into(),
                reply: None,
                payload_len: 6,
                payload: vec![],
            })
        );
    }

    #[test]
    fn unsub_rejects_invalid_max() {
        assert_eq!(parse_line("UNSUB 1 nope"), None);
    }

    #[test]
    fn ping_rejects_trailing_tokens() {
        assert_eq!(parse_line("PING junk"), None);
    }

    #[test]
    fn pong_rejects_trailing_tokens() {
        assert_eq!(parse_line("PONG junk"), None);
    }

    #[test]
    fn connect_parses_remainder_without_magic_slice() {
        assert_eq!(
            parse_line("  CONNECT {\"verbose\": false}"),
            Some(ClientMsg::Connect("{\"verbose\": false}".into()))
        );
    }

    #[test]
    fn connect_rejects_missing_remainder() {
        assert_eq!(parse_line("CONNECT"), None);
    }
}
