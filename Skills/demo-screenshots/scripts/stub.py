"""Local XMPP stub for Ducko demo screenshots.

Plays the server for one made-up account on 127.0.0.1: plaintext stream, SASL PLAIN
(any password), resource bind, a fixed roster, presence for the made-up contacts, and
answers to joins of the made-up rooms. Every other IQ gets a harmless canned
answer. Nothing leaves this machine.

Usage: python3 stub.py <port> <workdir> [content.json]
  [content.json]         the made-up account, contacts and rooms; defaults to the skill's
                         own content.json, and is read again at the start of each session
  <workdir>/stub.log     every byte string sent and received
  <workdir>/inject.txt   append one stanza per line to push it to the client; a line is
                         held until a client has received its roster and the presences
  <workdir>/joined/<room address>   written once the client has joined that room
  <workdir>/avatars/<localpart>.png   optional avatars served via vcard-temp
"""
import base64
import hashlib
import json
import os
import socket
import sys
import threading
import time
from xml.etree.ElementTree import XMLPullParser
from xml.sax.saxutils import escape, quoteattr

PORT = int(sys.argv[1])
WORKDIR = sys.argv[2]
CONTENT = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "content.json")
LOG = open(os.path.join(WORKDIR, "stub.log"), "a", buffering=1)
INJECT = os.path.join(WORKDIR, "inject.txt")
AVATARS = os.path.join(WORKDIR, "avatars")
JOINED = os.path.join(WORKDIR, "joined")

MUC_NS = "http://jabber.org/protocol/muc"

current = None  # the live client socket
current_lock = threading.Lock()


def log(direction, data):
    LOG.write("%s %s %s\n" % (time.strftime("%H:%M:%S"), direction, data))


def avatar(localpart):
    path = os.path.join(AVATARS, localpart + ".png")
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        return f.read()


def local(tag):
    return tag.rsplit("}", 1)[-1]


def ns(tag):
    return tag[1:].split("}", 1)[0] if tag.startswith("{") else ""


class Session:
    def __init__(self, sock):
        self.sock = sock
        with open(CONTENT, encoding="utf-8") as f:
            content = json.load(f)
        self.me = content["account"]["jid"]
        self.my_name = content["account"]["name"]
        self.domain = self.me.split("@", 1)[1]
        # show None = available, "offline" = no presence
        self.contacts = content["contacts"]
        self.rooms = {room["jid"]: room for room in content["rooms"]}
        self.authenticated = False
        self.full_jid = self.me + "/ducko"
        self.presence_sent = False
        self.ready = False  # roster and presences are out, so injected stanzas may follow

    def send(self, data):
        log("TX", data)
        self.sock.sendall(data.encode())

    def stream_header(self):
        self.send(
            "<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
            "xmlns:stream='http://etherx.jabber.org/streams' from='%s' version='1.0' id='demo%d'>"
            % (self.domain, int(time.time()))
        )
        if not self.authenticated:
            self.send(
                "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                "<mechanism>PLAIN</mechanism></mechanisms></stream:features>"
            )
        else:
            self.send("<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/></stream:features>")

    def result(self, iq, payload=""):
        self.send(
            "<iq type='result' id=%s to=%s%s>%s</iq>"
            % (quoteattr(iq.get("id", "")), quoteattr(self.full_jid), self.from_attr(iq), payload)
        )

    def error(self, iq, condition="service-unavailable"):
        self.send(
            "<iq type='error' id=%s to=%s%s><error type='cancel'>"
            "<%s xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            % (quoteattr(iq.get("id", "")), quoteattr(self.full_jid), self.from_attr(iq), condition)
        )

    @staticmethod
    def from_attr(iq):
        to = iq.get("to")
        return " from=%s" % quoteattr(to) if to else ""

    def roster(self):
        items = "".join(
            "<item jid='%s@%s' name=%s subscription='both'><group>%s</group></item>"
            % (c["localpart"], self.domain, quoteattr(c["name"]), escape(c["group"]))
            for c in self.contacts
        )
        return "<query xmlns='jabber:iq:roster'>%s</query>" % items

    def send_presences(self):
        for c in self.contacts:
            if c["show"] == "offline":
                continue
            body = ""
            if c["show"]:
                body += "<show>%s</show>" % c["show"]
            if c["status"]:
                body += "<status>%s</status>" % escape(c["status"])
            photo = avatar(c["localpart"])
            if photo:
                body += "<x xmlns='vcard-temp:x:update'><photo>%s</photo></x>" % hashlib.sha1(photo).hexdigest()
            self.send(
                "<presence from='%s@%s/%s' to=%s>%s</presence>"
                % (c["localpart"], self.domain, c["resource"], quoteattr(self.full_jid), body)
            )

    def join_room(self, room, nickname):
        def occupant(nick, affiliation, role, own=False):
            status = "<status code='110'/>" if own else ""
            return (
                "<presence from=%s to=%s><x xmlns='http://jabber.org/protocol/muc#user'>"
                "<item affiliation='%s' role='%s'/>%s</x></presence>"
                % (quoteattr("%s/%s" % (room["jid"], nick)), quoteattr(self.full_jid), affiliation, role, status)
            )

        for o in room["occupants"]:
            self.send(occupant(o["nick"], o["affiliation"], o["role"]))
        self.send(occupant(nickname, "member", "participant", own=True))
        self.send(
            "<message from=%s to=%s type='groupchat'><subject>%s</subject></message>"
            % (quoteattr(room["jid"]), quoteattr(self.full_jid), escape(room["subject"]))
        )
        os.makedirs(JOINED, exist_ok=True)
        open(os.path.join(JOINED, room["jid"]), "w").close()

    def vcard(self, bare):
        lp = bare.split("@", 1)[0]
        name = self.my_name if bare == self.me else next((c["name"] for c in self.contacts if c["localpart"] == lp), lp)
        photo = avatar(lp)
        photo_xml = ""
        if photo:
            photo_xml = "<PHOTO><TYPE>image/png</TYPE><BINVAL>%s</BINVAL></PHOTO>" % base64.b64encode(photo).decode()
        return "<vCard xmlns='vcard-temp'><FN>%s</FN>%s</vCard>" % (escape(name), photo_xml)

    def handle_iq(self, iq):
        kind = iq.get("type")
        if kind not in ("get", "set"):
            return
        child = next(iter(iq), None)
        if child is None:
            return self.error(iq, "bad-request")
        name, space = local(child.tag), ns(child.tag)
        to = iq.get("to")
        to_bare = to.split("/", 1)[0] if to else None

        if space == "urn:ietf:params:xml:ns:xmpp-bind":
            res = child.find("{urn:ietf:params:xml:ns:xmpp-bind}resource")
            if res is not None and res.text:
                self.full_jid = "%s/%s" % (self.me, res.text)
            return self.send(
                "<iq type='result' id=%s><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>%s</jid></bind></iq>"
                % (quoteattr(iq.get("id", "")), escape(self.full_jid))
            )
        if space == "urn:ietf:params:xml:ns:xmpp-session":
            return self.result(iq)
        if space == "jabber:iq:roster":
            return self.result(iq, self.roster() if kind == "get" else "")
        if space == "urn:xmpp:ping":
            return self.result(iq)
        if space == "vcard-temp":
            if kind == "set":
                return self.result(iq)
            return self.result(iq, self.vcard(to_bare or self.me))
        if space == "http://jabber.org/protocol/disco#info":
            if to_bare in (None, self.domain):
                return self.result(
                    iq,
                    "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    "<identity category='server' type='im' name='Pond'/>"
                    "<feature var='http://jabber.org/protocol/disco#info'/>"
                    "<feature var='vcard-temp'/><feature var='urn:xmpp:ping'/></query>",
                )
            if to_bare == self.me:
                return self.result(
                    iq,
                    "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    "<identity category='account' type='registered'/></query>",
                )
            return self.error(iq)
        if space == "http://jabber.org/protocol/disco#items":
            return self.result(iq, "<query xmlns='http://jabber.org/protocol/disco#items'/>")
        if space == "urn:xmpp:carbons:2":
            return self.result(iq)
        if space == "urn:xmpp:blocking" and kind == "get":
            return self.result(iq, "<blocklist xmlns='urn:xmpp:blocking'/>")
        if space == "urn:xmpp:mam:2" and name == "query":
            return self.result(
                iq,
                "<fin xmlns='urn:xmpp:mam:2' complete='true'>"
                "<set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set></fin>",
            )
        if space == "http://jabber.org/protocol/pubsub":
            return self.error(iq, "item-not-found") if kind == "get" else self.result(iq)
        return self.error(iq)

    def handle(self, el):
        name, space = local(el.tag), ns(el.tag)
        if space == "urn:ietf:params:xml:ns:xmpp-sasl" and name == "auth":
            self.authenticated = True
            self.send("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            return "restart"
        if name == "iq":
            self.handle_iq(el)
        elif name == "presence":
            to = el.get("to")
            if not el.get("type") and not to and not self.presence_sent:
                self.presence_sent = True
                self.send_presences()
                self.ready = True
            elif not el.get("type") and to and "/" in to and el.find("{%s}x" % MUC_NS) is not None:
                room_jid, nickname = to.split("/", 1)
                if room_jid in self.rooms:
                    self.join_room(self.rooms[room_jid], nickname)
        return None

    def run(self):
        parser = XMLPullParser(events=("start", "end"))
        depth = 0
        while True:
            data = self.sock.recv(65536)
            if not data:
                return
            log("RX", data.decode(errors="replace"))
            parser.feed(data)
            restart = False
            for event, el in parser.read_events():
                if event == "start":
                    depth += 1
                    if depth == 1:
                        self.stream_header()
                else:
                    depth -= 1
                    if depth == 0:
                        self.send("</stream:stream>")
                        return
                    if depth == 1 and self.handle(el) == "restart":
                        restart = True
            if restart:
                parser = XMLPullParser(events=("start", "end"))
                depth = 0


def serve(sock):
    global current
    try:
        session = Session(sock)
    except (OSError, ValueError, KeyError) as exc:
        log("ERR", "content unreadable: %r" % exc)
        sock.close()
        return
    with current_lock:
        current = session
    try:
        session.run()
    except Exception as exc:  # keep the stub alive across client reconnects
        log("ERR", repr(exc))
    finally:
        with current_lock:
            if current is session:
                current = None
        sock.close()
        log("--", "connection closed")


def inject_loop():
    open(INJECT, "a").close()
    with open(INJECT) as f:
        f.seek(0, os.SEEK_END)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.2)
                continue
            line = line.strip()
            if not line:
                continue
            # Hold the line until a client is ready: one sent earlier would be lost or land mid-negotiation.
            while True:
                with current_lock:
                    session = current
                if session and session.ready:
                    break
                time.sleep(0.2)
            try:
                session.send(line.replace("{ME}", session.full_jid))
            except OSError as exc:
                log("ERR", repr(exc))


def main():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", PORT))
    listener.listen(4)
    log("--", "listening on 127.0.0.1:%d" % PORT)
    threading.Thread(target=inject_loop, daemon=True).start()
    while True:
        sock, _ = listener.accept()
        log("--", "connection accepted")
        threading.Thread(target=serve, args=(sock,), daemon=True).start()


if __name__ == "__main__":
    main()
