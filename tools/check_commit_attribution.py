#!/usr/bin/env python3
"""Reject assistant identities in Git attribution, without filtering normal prose."""
import argparse
import pathlib
import re
import subprocess
import sys

ASSISTANT = re.compile(r"\b(?:claude|anthropic|chatgpt|openai|codex|copilot|gemini)\b", re.I)
COAUTHOR = re.compile(r"^\s*co-authored-by\s*:\s*(.+)$", re.I | re.M)


def message_errors(message):
    return [f"assistant coauthor: {identity.strip()}"
            for identity in COAUTHOR.findall(message) if ASSISTANT.search(identity)]


def git(*args):
    return subprocess.check_output(['git', *args])


def revision_errors(revision):
    # Scan ancestry as well: merging an old branch must not restore old trailers.
    resolved = git('rev-parse', '--verify', f'{revision}^{{commit}}').decode().strip()
    records = git('log', '--format=%H%x00%an%x00%ae%x00%cn%x00%ce%x00%B%x1e', resolved)
    failures = []
    for record in records.decode('utf-8', errors='replace').split('\x1e'):
        if not record.strip():
            continue
        sha, author, email, committer, committer_email, body = record.strip().split('\0', 5)
        errors = message_errors(body)
        for role, identity in [('author', f'{author} <{email}>'),
                               ('committer', f'{committer} <{committer_email}>')]:
            if ASSISTANT.search(identity):
                errors.append(f'assistant {role}: {identity}')
        failures.extend(f'{sha[:12]}: {error}' for error in errors)
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--message-file', type=pathlib.Path)
    mode.add_argument('--revision')
    mode.add_argument('--pre-push', action='store_true')
    args = parser.parse_args()
    if args.message_file:
        errors = message_errors(args.message_file.read_text(encoding='utf-8-sig', errors='replace'))
    elif args.revision:
        errors = revision_errors(args.revision)
    else:
        revisions = set()
        for line in sys.stdin:
            _, local_sha, _, _ = line.split()
            if set(local_sha) != {'0'}:  # A deletion introduces no commits.
                revisions.add(local_sha)
        errors = [error for revision in sorted(revisions) for error in revision_errors(revision)]
    if errors:
        print('Push/commit blocked: automated assistant attribution is not allowed.', file=sys.stderr)
        print('\n'.join(errors[:20]), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
