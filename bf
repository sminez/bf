#! /usr/bin/env python3
"""\
== embrace the blobfish ==
       ,-,
      ('_)<
       `-`

usage:
  bf [c]apture <file>  quickly capture an idea for later reviewing
  bf [n]ote <file>     open/create a note file
  bf [f]ind            search tagged notes and helpfiles
  bf [g]rep <pattern>  search note content using rg
  bf [t]odo            open the top level TODO file

  bf [s]ync            force sync with the remote repo
  bf [h]elp            display this help message

--------------------

== Disclaimer ==
This is a helper script that aims to acts as a capture and review system to
help me keep on top of things, regardless of what those things are.  There
are several directories that are required/expected to exist and in order to
keep things simple `bf` will simply fail loudly if it finds itself unable to
proceed.
>> In short, this is me-ware: not really us-ware and DEFINITELY not them-ware!
"""

import json
import os
import sys
import time
import shutil
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime
from itertools import cycle, zip_longest
from subprocess import DEVNULL, PIPE, Popen, run
from threading import Thread
from urllib.parse import urlencode
from urllib.request import Request, urlopen


REQUIRED_TOOLS = ["rg", "fzf", "bat", "git"]

DEFAULT_COMMIT_MESSAGE = "automated blobfish sync commit"
HELP_TEXT = __doc__.split("\n--------------------")[0]
DELIMITER = "|"

ROOT_DIR = os.get_env("NOTE_ROOT", os.path.expanduser("~/.notes"))
HELPFILE_DIR = f"{ROOT_DIR}/helpfiles"
CAPTURE_DIR = f"{ROOT_DIR}/capture"
NOTE_DIR = f"{ROOT_DIR}/notes"
TODO_FILE = f"{ROOT_DIR}/TODO.md"
EDITOR = os.getenv("EDITOR", "kak")

C = {
    color: f"\033[{code}m"
    for (color, code) in [
        ("red", 31),
        ("green", 32),
        ("yellow", 33),
        ("blue", 34),
        ("purple", 35),
        ("cyan", 36),
        ("white", 37),
        ("bold", 1),
        ("dim", 2),
        ("italic", 3),
        ("underline", 4),
        ("nc", 0),
    ]
}

TAGS = {
    "#": C["bold"] + C["yellow"],
    "%": C["bold"] + C["blue"],
    "?": C["dim"] + C["purple"] + C["italic"],
    ">": C["bold"],
}

warn_and_exit = lambda s: (heading(s, "yellow"), sys.exit(0))
error_and_exit = lambda s: (heading(s, "red"), sys.exit(1))


def heading(s, color="cyan", *, fmt=False):
    h = f"{C[color]}{C['bold']}:: {C['white']}{s}{C['nc']}"
    return h if fmt else print(h)


@contextmanager
def spinner(interval=0.2, *, prefix="", color="yellow", steps=("", ".", "..", "...")):
    def spin():
        p = heading(prefix, color=color, fmt=True) if prefix else prefix
        for step in cycle(steps):
            sys.stdout.write(f"{p}{C[color]}{step}{C['nc']}")
            sys.stdout.flush()
            time.sleep(interval)
            sys.stdout.write("\x1b[2K\r")  # clear the line

            if done:
                return

    done = False
    spin_thread = Thread(target=spin)
    spin_thread.start()
    yield
    done = True
    spin_thread.join()


def sh(cmd, *, cwd=NOTE_DIR, stdin=None, communicate=False, silent=False):
    lines = []

    if stdin is not None:
        stdin = "\n".join(stdin) if isinstance(stdin, list) else stdin
        stdin = stdin.encode() if isinstance(stdin, str) else stdin
        proc = Popen(cmd, shell=True, cwd=cwd, stdin=PIPE, stdout=PIPE)
        stdout, _ = proc.communicate(stdin)
        if stdout:
            lines = stdout.decode("utf-8").strip().split("\n")

    elif communicate:
        proc = Popen(cmd, shell=True, cwd=NOTE_DIR, stdout=PIPE)
        stdout, _ = proc.communicate()
        if stdout:
            lines = stdout.decode("utf-8").strip().split("\n")

    elif silent:
        run(cmd, shell=True, cwd=cwd, stdout=DEVNULL, stderr=DEVNULL)

    else:
        output = run(cmd, text=True, shell=True, cwd=cwd, capture_output=True)
        stdout = output.stdout.strip()
        if stdout:
            lines = stdout.split("\n")

    return lines


def edit(fname, lnum=1, expand=True):
    if fname is not None:
        fname = expand_note_name(fname) if expand else fname
        run([EDITOR, fname, f"+{lnum}"])


def expand_note_name(fname):
    fname = f"{fname}.md" if not fname.endswith(".md") else fname
    return f"{NOTE_DIR}/{fname}"


def find_files(marker, condition=lambda _: True):
    paths = []
    for d, _, fs in os.walk(NOTE_DIR):
        candidates = [os.path.join(d, f).replace(NOTE_DIR + "/", "") for f in fs]
        paths.extend(filter(condition, candidates))

    parts = []
    for path in paths:
        try:
            prefix, rest = path.rsplit("/", 1)
        except ValueError:
            prefix, rest = "", path

        rest = rest.replace(".md", "")
        tags = ""
        with open(os.path.join(NOTE_DIR, path), "r") as f:
            for line in f:
                if line.startswith("Tags:"):
                    tags = sorted(line.lstrip("Tags: ").replace("@", "").split())
                    tags = ",".join(tags)
                    break
        parts.append([marker, prefix, rest, tags])

    return parts


# NOTE: this assumes that the file is well formatted
def helpfile_snippets():
    snippets = []
    for path in os.listdir(HELPFILE_DIR):
        lines = (
            line.strip()
            for line in open(os.path.join(HELPFILE_DIR, path), "r")
            if line.startswith("#") or line.startswith("?")
        )
        pairs = list(zip_longest(*[lines for _ in range(2)]))  # chunk in groups of 2
        prefix = path.split(".")[0]
        snippets.extend(["h", prefix, title[2:], tags[2:]] for title, tags in pairs)

    return snippets


def format_select_lines(raw):
    widths = [max(len(s) for s in [r[i] for r in raw]) for i in range(4)]
    spaced = [f" {DELIMITER} ".join(r[i].ljust(widths[i]) for i in range(4)) for r in raw]
    return "\n".join(sorted(spaced))


def select(raw):
    cmd = "fzf --preview-window=up:70% --preview 'bf __preview {}'"
    stdout = sh(cmd, stdin=format_select_lines(raw))
    if stdout:
        return stdout[0]


def select_existing_note():
    choice = select(find_files("n", lambda p: p.endswith(".md")))
    if choice is not None:
        _, prefix, fname, _ = choice.split(DELIMITER)
        return os.path.join(prefix.strip(), fname.strip())


def select_any():
    lines = find_files("n", lambda p: p.endswith(".md")) + helpfile_snippets()
    choice = select(sorted(lines))
    if choice is None:
        return

    marker, prefix, fname, _ = choice.split(DELIMITER)
    if marker.strip() == "n":
        edit(os.path.join(prefix.strip(), fname.strip()))
    elif marker.strip() == "h":
        helpfile_preview(prefix.strip(), fname.strip())


def known_tags():
    n_tags = sh("rg --no-heading --no-filename --no-line-number Tags:")
    n_tags = sum((line.replace("@", "").split()[1:] for line in n_tags), [])
    h_tags = sh("rg --no-heading --no-filename --no-line-number '^\\?'", cwd=HELPFILE_DIR)
    h_tags = sum((line[2:].split(",") for line in h_tags), [])
    return sorted(set(n_tags + [t.strip() for t in h_tags]))


def show_help_and_exit(exit_code):
    print(HELP_TEXT)
    sys.exit(exit_code)


def create_capture_file(words=[]):
    title = datetime.now().strftime("%F")
    if len(words) > 0:
        title = "_".join([title] + words)

    fname = f"{CAPTURE_DIR}/{title}.md"
    if not os.path.exists(fname):
        with open(fname, "w") as f:
            f.write(f"### {' '.join(words) if words else 'Daily notes'}")

    return fname


def helpfile_preview(fname, title):
    def _color(line):
        for char, color in TAGS.items():
            if line.startswith(char):
                return color + line[2:] + C["nc"]
        return line

    snippet = []
    fname += ".helpfile"
    with open(os.path.join(HELPFILE_DIR, fname), "r") as f:
        for line in f:
            if title in line:
                break
        else:
            return ""
        snippet.append(_color(line))
        for line in f:
            if line == "--\n":
                break
            snippet.append(_color(line))

    print("".join(snippet))


def preview(line):
    sections = [section.strip() for section in line.split(DELIMITER)]
    _preview = line
    if sections[0] == "n":
        output = sh(f"bat --color=always {NOTE_DIR}/{sections[1]}/{sections[2]}.md")
        _preview = "\n".join(output)
    elif sections[0] == "h":
        _preview = helpfile_preview(sections[1], sections[2])

    print(_preview)


# top level commands


def grep(args):
    patt = "" if len(args) == 0 else args[0]
    rg = "rg --column --line-number --no-heading " "--color=always --smart-case -m5"
    stdout = sh(
        f"FZF_DEFAULT_COMMAND='{rg} \"{patt}\"' "
        f'fzf --bind "change:reload:{rg} "{{q}}" || true" '
        f'--ansi --phony --query "{patt}" --delimiter : '
        "--preview 'bat --color=always --theme=ansi "
        "--style=numbers --highlight-line {2} {1}' "
        "--preview-window +{2}-/2",
        communicate=True,
    )

    if stdout:
        fname, lnum, *_ = stdout[0].split(":")
        edit(fname, lnum)


def sync(args):
    os.chdir(ROOT_DIR)
    with spinner(prefix="pulling remote changes"):
        sh("git pull --autostash", silent=True)

    if len(sh("git status -s -uall")) == 0:
        warn_and_exit("nothing to commit")

    msg = " ".join(args) if args else DEFAULT_COMMIT_MESSAGE
    with spinner(prefix="pushing local changes"):
        sh("git add -A", silent=True)
        sh(f"git commit -m'{msg}'", silent=True)
        sh("git push", silent=True)

    heading("done")


def get_command(cmd):
    commands = {
        # Main functionality
        "capture": lambda args: edit(create_capture_file(args), expand=False),
        "find": lambda _: select_any(),
        "grep": grep,
        "note": lambda args: edit(args[0] if args else select_existing_note()),
        "todo": lambda _: edit(TODO_FILE, expand=False),
        "sync": sync,
        "help": lambda _: show_help_and_exit(0),
        # helpers for use in other programs interacting with us
        "__snippets": lambda _: print(format_select_lines(helpfile_snippets())),
        "__preview": lambda args: preview(" ".join(args)),
        "__capfile": lambda args: print(create_capture_file(args)),
        "__tags": lambda _: print("\n".join(known_tags())),
    }

    # allow for single character abbreviations as well
    for c, f in list(commands.items()):
        if not c.startswith("_"):
            commands[c[0]] = f

    return commands.get(cmd, lambda _: show_help_and_exit(1))


def check_required_tools():
    for tool in REQUIRED_TOOLS:
        if shutil.which(tool) is None:
            error_and_exit(f"{tool} needs to be on your $PATH for bf to function")


if __name__ == "__main__":
    check_required_tools()

    args = sys.argv[1:]
    if len(args) == 0:
        show_help_and_exit(1)

    get_command(args[0])(args[1:])
