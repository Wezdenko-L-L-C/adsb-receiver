#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# .github/scripts/check-disk-commands.py: no disk formatting command outside setup/foundation/
# (PLAN §9m: no step runs mkfs). Run by CI over the files it names; prints each hit as
# path:line:text and exits 1 if there is any. Any error (an unreadable file, bad bytes, a bug
# here) is an uncaught exception, so the check fails rather than quietly passing.
#
# What counts, as words, quoted or not, on any line that is not a whole-line comment: mkfs and
# mkfs.*, mke2fs, mkdosfs, mkntfs, mkexfatfs, mkswap, wipefs, sfdisk, sgdisk, gdisk, cfdisk,
# fdisk, parted, blkdiscard, shred, systemd-repart, pvcreate, vgcreate, lvcreate,
# `mdadm ... --create` (or -C), `cryptsetup ... luksFormat`, `dd ... of=` naming /dev/ or a
# variable (quoted or not), and a redirection (>, >>, >|) onto /dev/sd*, /dev/mmcblk*, /dev/nvme*
# or /dev/disk/.
#
# Shell heredocs: the body of a heredoc read by `cat` is printed text (step 30 prints the manual
# format commands as help) and is skipped, with two exceptions that are checked as code: a cat
# whose output is piped on (`cat <<EOF | bash`), and, in an unquoted heredoc (where the shell
# expands the body), a line holding $( or a backtick, which runs a command. Every other heredoc
# body (bash, sh, python3, ...) is code and is checked. A heredoc starts only at a real `<<`
# redirection: outside quotes, not `<<<`, not inside (( )) or $(( )), and followed by a word. The
# word is read as the shell reads it: up to a blank or one of |&;()<>, with quotes and backslashes
# removed (so END-OF-HELP, EOF.x and 'END OF' are whole delimiters); any quote in it makes the
# body literal. Several on one line are read in order, each body ending at its own terminator
# (with <<-, after leading tabs).
# Python files (a .py name or a python3 shebang) have no heredocs: `<<` there is a shift.

import os
import re
import sys

CMD = re.compile(r"(?<![\w.-])(mkfs(?:\.\w+)?|mke2fs|mkdosfs|mkntfs|mkexfatfs|mkswap|wipefs"
                 r"|sfdisk|sgdisk|gdisk|cfdisk|fdisk|parted|blkdiscard|shred|systemd-repart"
                 r"|pvcreate|vgcreate|lvcreate)(?![\w.-])")
DD = re.compile(r"""(?<![\w.-])dd(?![\w.-])[^\n]*\bof=["']?(?:/dev/|\$)""")
LUKS = re.compile(r"(?<![\w.-])cryptsetup(?![\w.-])[^\n]*\bluksFormat\b")
MDADM = re.compile(r"(?<![\w.-])mdadm(?![\w.-])[^\n]*(?:--create\b|\s-C\b)")
REDIR = re.compile(r""">\|?\s*["']?/dev/(?:sd|mmcblk|nvme|disk/)""")
WORD_END = set(" \t|&;()<>")
KEYWORDS = {"if", "then", "do", "else", "elif", "while", "until", "!", "exec", "command",
            "time", "{", "(", "sudo", "env"}


def is_python(path, first):
    return path.endswith(".py") or re.match(r"#!.*[/\s]python3(\s|$)", first) is not None


def hit(line):
    return any(r.search(line) for r in (CMD, DD, LUKS, MDADM, REDIR))


def heredoc_word(line, j):
    """(delimiter, quoted, end) for the word at line[j:], read as the shell reads a heredoc
    word: up to a blank or one of |&;()<>, quotes and backslashes removed. delimiter is "" if
    there is no word."""
    out, quoted, n = [], False, len(line)
    while j < n and line[j] not in WORD_END:
        c = line[j]
        if c == "\\":
            quoted = True
            if j + 1 < n:
                out.append(line[j + 1])
            j += 2
        elif c in "'\"":
            quoted = True
            k = j + 1
            while k < n and line[k] != c:
                if c == '"' and line[k] == "\\" and k + 1 < n:
                    k += 1
                out.append(line[k])
                k += 1
            j = k + 1
        else:
            out.append(c)
            j += 1
    return "".join(out), quoted, j


def piped_after(rest):
    """True if the rest of the command line pipes the heredoc's reader into something."""
    return re.search(r"(?<!\|)\|(?![|])", rest.split("#", 1)[0]) is not None


def command_before(prefix):
    """The command word that reads a heredoc whose operator follows prefix."""
    # & splits commands, except in a redirection (>&2, <&3, &>file).
    seg = re.split(r"\|\||&&|(?<![<>])&(?!>)|[|;`]|\$\(|\(", prefix)[-1]
    for tok in seg.split():
        if tok in KEYWORDS or re.match(r"[A-Za-z_]\w*=", tok) or re.match(r"\d*[<>]", tok):
            continue
        return os.path.basename(tok.strip("'\""))
    return ""


def heredocs(line):
    """[(delimiter, strip_tabs, command, quoted, piped)] for each real heredoc operator on the
    line, in order."""
    out, i, n, quote, arith = [], 0, len(line), None, 0
    while i < n:
        c = line[i]
        if quote == "'":
            quote = None if c == "'" else quote
            i += 1
            continue
        if quote == '"':
            if c == "\\":
                i += 2
                continue
            quote = None if c == '"' else quote
            i += 1
            continue
        if c == "\\":
            i += 2
            continue
        if c in "'\"":
            quote = c
            i += 1
            continue
        if c == "#" and (i == 0 or line[i - 1] in " \t;|&("):
            break
        if line.startswith("((", i):
            arith += 1
            i += 2
            continue
        if arith and line.startswith("))", i):
            arith -= 1
            i += 2
            continue
        if line.startswith("<<<", i):
            i += 3
            continue
        if not arith and line.startswith("<<", i):
            j = i + 2
            strip = j < n and line[j] == "-"
            j += 1 if strip else 0
            while j < n and line[j] in " \t":
                j += 1
            word, quoted, end = heredoc_word(line, j)
            if word:
                out.append((word, strip, command_before(line[:i]), quoted,
                            piped_after(line[end:])))
                i = end
                continue
        i += 1
    return out


def check(path):
    hits = []
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    python = is_python(path, lines[0] if lines else "")
    pending = []          # heredocs whose bodies come next, as heredocs() returns them
    for n, line in enumerate(lines, 1):
        if pending:
            delim, strip, cmd, quoted, piped = pending[0]
            if (line.lstrip("\t") if strip else line) == delim:
                pending.pop(0)
                continue
            # cat's body is printed text, unless it is piped on, or (unquoted) runs a command.
            text = cmd == "cat" and not piped and (quoted or ("$(" not in line and "`" not in line))
            if not text and not line.lstrip().startswith("#") and hit(line):
                hits.append(f"{path}:{n}:{line}")
            continue
        if line.lstrip().startswith("#"):
            continue
        if hit(line):
            hits.append(f"{path}:{n}:{line}")
        if not python:
            pending.extend(heredocs(line))
    return hits


def main(paths):
    hits = [h for p in paths for h in check(p)]
    for h in hits:
        print(h)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
