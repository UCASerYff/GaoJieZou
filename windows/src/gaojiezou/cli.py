"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from gaojiezou.desktop import DesktopInstance, WindowsDesktop, open_window, route_index
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
    parser.add_argument("--widgets", action="store_true", help="打开桌面小组件")
    parser.add_argument("link", nargs="?", help="打开搞节奏链接")
    args = parser.parse_args(argv)
    if args.version:
        print(VERSION_LABEL)
        return 0
    try:
        route = route_index(args.link)
    except ValueError as exc:
        parser.error(str(exc))
    directory = Path(args.data_dir) if args.data_dir else default_data_dir()
    instance = DesktopInstance(directory) if sys.platform == "win32" else None
    try:
        if instance and not instance.owner:
            if not (args.inspect or args.widget_snapshot or args.create_empty or args.no_browser or args.port):
                if instance.forward(route, args.widgets):
                    return 0
            print("此资料库正在使用。", file=sys.stderr)
            return 2
        return _run(args, directory, instance, route)
    finally:
        if instance:
            instance.close()


def _run(args, directory: Path, instance: DesktopInstance | None, route: int) -> int:
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
    server = serve(store, port=args.port, open_browser=False)
    desktop = WindowsDesktop(server, instance.name, tray=not args.no_browser) if instance else None
    try:
        if desktop:
            desktop.start()
        server.desktop = desktop
        if args.widgets and desktop:
            desktop.show_widgets()
        elif not args.no_browser:
            open_window(server.url, route)
        server.shutdown_requested.wait()
    except KeyboardInterrupt:
        pass
    except OSError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    finally:
        server.shutdown()
        if desktop:
            desktop.close()
        try:
            with server.lock:
                store.prepare_for_exit()
        except AppError as exc:
            print(exc.message, file=sys.stderr)
            return 2
        finally:
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
