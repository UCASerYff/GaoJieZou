"""营销版本与当前 Mac 版 Info.plist 的 CFBundleShortVersionString 对齐。

Windows 构建号独立于 Mac 的 CFBundleVersion。
"""

MARKETING_VERSION = "4.12"
WINDOWS_BUILD = "2"
VERSION_LABEL = f"{MARKETING_VERSION}+{WINDOWS_BUILD}"
SCHEMA_VERSION = 11
APP_NAME = "搞节奏"
BUNDLE_ID = "com.gaojiezou.rhythm"
