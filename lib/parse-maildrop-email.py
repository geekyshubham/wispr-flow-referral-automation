#!/usr/bin/env python3
"""Decode Maildrop's raw RFC822 message without executing email HTML."""
from email import policy
from email.parser import Parser
from email.utils import getaddresses, parseaddr, parsedate_to_datetime
from html.parser import HTMLParser
import json
import sys

value = json.load(sys.stdin)
raw = value.get('data') or ''
message = Parser(policy=policy.default).parsestr(raw)
text = raw
html = value.get('html') or ''
if message.keys():
    plain = message.get_body(preferencelist=('plain',))
    rich = message.get_body(preferencelist=('html',))
    text = plain.get_content() if plain is not None else ''
    if not html and rich is not None:
        html = rich.get_content()
if not text and html:
    class VisibleText(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.hidden = 0
            self.parts = []

        def handle_starttag(self, tag, attrs):
            if tag in ('head', 'style', 'script'):
                self.hidden += 1
            elif tag in ('br', 'p', 'div', 'tr', 'td') and not self.hidden:
                self.parts.append('\n')

        def handle_endtag(self, tag):
            if tag in ('head', 'style', 'script') and self.hidden:
                self.hidden -= 1

        def handle_data(self, data):
            if not self.hidden:
                self.parts.append(data)

    parser = VisibleText()
    parser.feed(html)
    text = ''.join(parser.parts)
sender = parseaddr(value.get('headerfrom') or str(message.get('From', '')))[1]
recipients = value.get('rcptto') or message.get_all('To', [])
addresses = [address for _, address in getaddresses(recipients)]
if not addresses:
    addresses = [value['expectedEmail']]
sent_at = None
try:
    if message.get('Date'):
        sent_at = parsedate_to_datetime(message['Date']).isoformat()
except (TypeError, ValueError, OverflowError):
    pass
print(json.dumps({'text': text, 'html': html, 'from': {'address': sender},
                  'to': [{'address': address} for address in addresses], 'sentAt': sent_at}))
