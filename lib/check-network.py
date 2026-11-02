#!/usr/bin/env python3
"""Check signup DNS before allocating a mailbox or opening the browser."""
import socket
import sys


def check(provider='maildrop'):
    mail_host = {'maildrop': 'api.maildrop.cc', 'mail.tm': 'api.mail.tm'}.get(provider)
    if not mail_host:
        print('ERROR:Unknown mail provider: ' + provider, file=sys.stderr)
        return 1
    for host in ('wisprflow.ai', 'api.wisprflow.ai', mail_host):
        try:
            socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
        except OSError as error:
            print(f'ERROR:DNS lookup failed for {host}: {error}', file=sys.stderr)
            print('Check the Mac network/VPN DNS settings, then retry. No new signup was submitted.', file=sys.stderr)
            return 69
    return 0


if __name__ == '__main__':
    sys.exit(check(sys.argv[1] if len(sys.argv) > 1 else 'maildrop'))
