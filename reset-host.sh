#!/bin/sh
# Reset the wedged legacyScreenSaver host so the Options sheet / preview work again.
killall legacyScreenSaver 2>/dev/null || true
killall ScreenSaverEngine 2>/dev/null || true
killall "System Settings" 2>/dev/null || true
echo "Host reset. Reopen System Settings > Screen Saver and click Options."
