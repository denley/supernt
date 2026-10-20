#!/usr/bin/env python3
"""Trace routing in a mistral-cv .bt decompile.

Usage:
  trace.py file.bt back NODE...    follow drivers backwards to a block port
  trace.py file.bt fwd NODE...     list block ports reached from NODE

Route lines are "r SRC DST [; PIN]". Wire nodes have exactly one driver, so
walking back is a simple chain; walking forward fans out.
"""
import sys
from collections import defaultdict


def load(path):
    drv, fan = {}, defaultdict(list)
    for line in open(path):
        if not line.startswith('r '):
            continue
        body = line[2:].split(' ; ')[0].split()
        src, dst = body[0], body[1]
        drv[dst] = src
        fan[src].append(dst)
    return drv, fan


def is_port(node):
    return ':' in node


def back(drv, node):
    path = [node]
    while node in drv:
        node = drv[node]
        path.append(node)
        if is_port(node):
            break
    return path


def fwd(fan, node, limit=10000):
    out, todo, seen = [], [node], set()
    while todo and len(seen) < limit:
        n = todo.pop()
        if n in seen:
            continue
        seen.add(n)
        for d in fan.get(n, []):
            if is_port(d):
                out.append(d)
            else:
                todo.append(d)
    return sorted(out)


def main():
    path, mode, nodes = sys.argv[1], sys.argv[2], sys.argv[3:]
    drv, fan = load(path)
    for n in nodes:
        if mode == 'back':
            p = back(drv, n)
            print(n, '<=', p[-1], f'({len(p) - 1} hops)')
        else:
            print(n, '=>', ' '.join(fwd(fan, n)))


if __name__ == '__main__':
    main()
