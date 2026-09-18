import xml.etree.ElementTree as ET


class StreamReader:
    def __init__(self, connection):
        self.connection = connection
        self.parser = ET.XMLPullParser(events=('start', 'end'))
        self.depth = 0

    def next(self):
        while True:
            for kind, element in self.parser.read_events():
                if kind == 'start':
                    self.depth += 1
                    if self.depth == 1:
                        return 'open', element
                else:
                    self.depth -= 1
                    if self.depth == 1:
                        return 'stanza', element
                    if self.depth == 0:
                        return 'close', element
            data = self.connection.recv(4096)
            if not data:
                return 'eof', None
            self.parser.feed(data)

    def opened(self):
        kind, element = self.next()
        assert kind == 'open' and element.tag == '{http://etherx.jabber.org/streams}stream'

    def stanza(self):
        kind, element = self.next()
        assert kind == 'stanza', kind
        return element
