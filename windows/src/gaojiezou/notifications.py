"""Local WinRT notifications for the installed desktop application."""

from __future__ import annotations

import ctypes
import logging
import sys
from datetime import datetime, timedelta, timezone
from enum import Enum, auto
from pathlib import Path
from xml.etree import ElementTree

APP_USER_MODEL_ID = "GaoSeries.GaoJieZou.Rhythm"
APP_ID_REGISTRY = rf"Software\Classes\AppUserModelId\{APP_USER_MODEL_ID}"
TOAST_PROTOCOL_ACTIVATOR = "{F41BCF1C-8CE7-4AAA-9D7A-7469E34F313A}"
HABIT_TAG = "habit-reminder"
HABIT_GROUP = "rhythm"
HABITS_URL = "gaojiezou://habits"
LOG = logging.getLogger(__name__)


class ToastResult(Enum):
    SUBMITTED = auto()
    DISABLED = auto()
    UNAVAILABLE = auto()


def installed_identity() -> bool:
    if sys.platform != "win32" or not getattr(sys, "frozen", False):
        return False
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, APP_ID_REGISTRY) as key:
            executable, _ = winreg.QueryValueEx(key, "RhythmExecutable")
        return Path(executable).resolve() == Path(sys.executable).resolve()
    except (OSError, TypeError, ValueError):
        return False


def set_process_identity() -> bool:
    if not installed_identity():
        return False
    set_id = ctypes.WinDLL("shell32").SetCurrentProcessExplicitAppUserModelID
    set_id.argtypes = [ctypes.c_wchar_p]
    set_id.restype = ctypes.c_long
    return set_id(APP_USER_MODEL_ID) >= 0


def habit_toast_xml(title: str, message: str) -> str:
    toast = ElementTree.Element("toast", {"activationType": "protocol", "launch": HABITS_URL})
    visual = ElementTree.SubElement(toast, "visual")
    binding = ElementTree.SubElement(visual, "binding", {"template": "ToastGeneric"})
    ElementTree.SubElement(binding, "text").text = title
    ElementTree.SubElement(binding, "text").text = message
    return ElementTree.tostring(toast, encoding="unicode")


def submit_habit_toast(title: str, message: str, *, quiet: bool = False) -> ToastResult:
    """Submit the reminder to Windows for the current interactive user."""
    try:
        from winrt.runtime import ApartmentType, init_apartment, uninit_apartment

        init_apartment(ApartmentType.MULTI_THREADED)
    except (ImportError, OSError, RuntimeError) as exc:
        LOG.warning("Windows notification runtime unavailable: %s", exc)
        return ToastResult.UNAVAILABLE
    try:
        return _show_habit_toast(habit_toast_xml(title, message), quiet)
    except (ImportError, OSError, RuntimeError) as exc:
        LOG.warning("Windows app notification unavailable: %s", exc)
        return ToastResult.UNAVAILABLE
    finally:
        uninit_apartment()


def _show_habit_toast(xml: str, quiet: bool) -> ToastResult:
    from winrt.windows.data.xml.dom import XmlDocument
    from winrt.windows.ui.notifications import NotificationSetting, ToastNotification, ToastNotificationManager

    notifier = ToastNotificationManager.create_toast_notifier_with_id(APP_USER_MODEL_ID)
    try:
        setting = notifier.setting
    except OSError as exc:
        # Immediately after installation Windows may not have announced the new sender to Settings yet.
        if exc.winerror != -2147023728:  # HRESULT_FROM_WIN32(ERROR_NOT_FOUND)
            raise
    else:
        if setting != NotificationSetting.ENABLED:
            return ToastResult.DISABLED
    document = XmlDocument()
    document.load_xml(xml)
    toast = ToastNotification(document)
    toast.tag = HABIT_TAG
    toast.group = HABIT_GROUP
    toast.expiration_time = datetime.now(timezone.utc) + timedelta(hours=12)
    toast.suppress_popup = quiet
    notifier.show(toast)
    return ToastResult.SUBMITTED
