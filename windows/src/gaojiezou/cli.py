"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
import sys

from gaojiezou.errors import AppError
from gaojiezou.store import RhythmStore, default_data_dir
from gaojiezou.version import VERSION_LABEL
from gaojiezou.web import serve


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="GaoJieZou", description="搞节奏 Windows 版")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--data-dir", default=None)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--create-empty", action="store_true")
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--widget-snapshot", action="store_true")
    args = parser.parse_args(argv)
    if args.version:
        print(VERSION_LABEL)
        return 0
    directory = default_data_dir() if not args.data_dir else __import__("pathlib").Path(args.data_dir)
    store = RhythmStore(directory)
    try:
        if args.create_empty:
            store.create_library()
            if not args.serve:
                print("created")
                return 0
        if args.inspect:
            _print_counts(store)
            return 0
        if args.widget_snapshot:
            if store.status != "ready":
                print(store.notice or store.status, file=sys.stderr)
                return 2
            store.save()
            print("widget-snapshot")
            return 0
    except AppError as exc:
        print(exc.message, file=sys.stderr)
        return 2
    if args.inspect:
        return 0
    server = serve(store, port=args.port, open_browser=not args.no_browser)
    try:
        server.shutdown_requested.wait()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            store.prepare_for_exit()
        except AppError as exc:
            print(exc.message, file=sys.stderr)
            return 2
        server.server_close()
    return 0


def _print_counts(store: RhythmStore) -> None:
    print(f"status={store.status}")
    print(f"version={VERSION_LABEL}")
    counts = store.counts()
    for key in ("habits", "chores", "focusRecords", "sleepRecords", "longGoals", "shortActions", "coins", "bait"):
        print(f"{key}={counts.get(key)}")
    print(f"health={'yes' if counts['health'] else 'no'}")
    print(f"footprints={'yes' if counts['footprints'] else 'no'}")
    print(f"sharedSleep={'yes' if counts['sharedSleep'] else 'no'}")
