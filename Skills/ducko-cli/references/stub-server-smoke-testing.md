# Stub-Server Smoke Testing

Exercise stream-level behavior (STARTTLS negotiation, stream features, injected or malformed server data) through the CLI against a local stub instead of a live server.

## Point the CLI at the Stub

Run a one-connection Python stub on a free `127.0.0.1` port. Check the port with `lsof -iTCP:<port> -sTCP:LISTEN` first, record the stub's PID for cleanup, and start a fresh stub per scenario. Binary, profile prefix and cleanup follow the Throwaway Profiles section of SKILL.md.

- **Pre-auth, creates no account**: `.build/debug/DuckoCLI account check-registration --server example.com --host 127.0.0.1 --port <port>`
- **Login path**: `DUCKO_PROFILE=<unique> .build/debug/DuckoCLI account add alice@example.com --password x --host 127.0.0.1 --port <port>`.

Failures exit 1 with `Error: <summary>[: <reason>]`. `account check-registration` reports a rejected stream header or features element only as `Error: Unexpected response from the server`.

## Stub Requirements

1. Read until `<stream:stream` arrives.
2. Reply with a stream header carrying `version='1.0'`, then a `<stream:features>` element. The client rejects a version other than 1.0, or a features element with a different name, before reaching the code under test.
   ```xml
   <?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0' id='stub'><stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls></stream:features>
   ```
3. Read until the client's next element (e.g. `<starttls`) arrives before answering it, unless the scenario deliberately pipelines ahead of the client.
4. When the scenario depends on elements arriving together (e.g. `<proceed/>` plus injected data), send them in a single `sendall`.
5. Log every byte string sent and received, so a surprising result can be traced to what actually went over the wire.
6. Hold the socket open until the client closes it, with a socket timeout so the stub never lingers.

## Pair Negative Scenarios with a Control

A rejection only means something when a control that differs in the dimension under test reaches the code beyond it. For example, a stub that answers `<starttls/>` with `<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>` plus an injected `<message>` in one send expects `Secure connection failed: The server sent unexpected data after agreeing to start TLS`. Its control sends only the `<proceed/>`, so the client starts a real TLS ClientHello. Answering that with non-TLS junk such as `HTTP/1.1 400 Bad Request\r\n\r\n` yields a handshake reason (e.g. `Secure connection failed: record overflow`), which proves the upgrade was reached.

## Probe a Real Server's Raw Replies

Use `openssl s_client` to see what a live server answers after STARTTLS. Pipe a post-TLS stream header plus the stanzas to send, and bound the run, since `s_client` otherwise holds the connection open:

```
(printf "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' to='<domain>' version='1.0'><iq type='get' id='q1'><query xmlns='jabber:iq:register'/></iq>"; perl -e 'select(undef,undef,undef,5)') \
  | perl -e 'alarm 10; exec @ARGV' openssl s_client -connect <host>:5222 -starttls xmpp -xmpphost <domain> -quiet > "$TMPDIR/probe.txt" 2>&1
```
