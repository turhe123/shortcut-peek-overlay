# ShortcutPeekOverlay — specification

**Tagline:** Hold Command for a moment and see every menu shortcut of the frontmost app in a searchable overlay.

**Category:** Focus & Productivity

**Inspired by (paid):** KeyCue ($19.99 one-time, sale price seen)

**Frameworks:** SwiftUI, AppKit, ApplicationServices, CoreGraphics, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does and evidence of demand. KeyCue from Ergonis shows the keyboard shortcuts of the current app when you hold the Command key, so you can learn shortcuts without reading manuals. It is a long-lived paid utility, listed at roughly 19.99 dollars when on sale and higher at list price, and it is regularly named in lists of shortcut helper apps alongside free options like CheatSheet and KeyClu. The steady stream of copycats shows people want this, and the free ones are limited. Our version targets the same hold-to-reveal flow with search.

Feature set for our clean-room version. A menu bar app. When the user holds the Command key alone for a chosen delay (default 1.2 seconds), a centered overlay panel shows all menu items of the frontmost app that have keyboard shortcuts, grouped by top-level menu such as File, Edit and View, each row showing the item name and the shortcut as keycap glyphs. Disabled items are dimmed. Releasing Command hides the overlay. A second mode, opened by a global hotkey, shows the same panel as a persistent search window where typing filters the list by item name and pressing Return triggers the selected menu item directly. A favorites toggle pins frequently used shortcuts to the top.

UI spec. A MenuBarExtra with items Show Shortcuts Now, Hold Delay submenu (0.8, 1.2, 2 seconds), Settings and Quit. The overlay is a rounded translucent non-activating panel with an app icon and name header, a multi-column layout that scales to the screen, and a small footer hint saying Release Command to close. The settings window has hold delay, hotkey recorder for the search mode with a default of Control Option Command K, an excluded apps list where the overlay never shows, a toggle to include items without shortcuts in the search mode and launch at login. Empty state: if an app has no shortcuts, the overlay says This app has no menu shortcuts. When Accessibility permission is missing, the overlay shows an explanation with a button to grant access.

Technical approach. Detect the lone Command hold with a listen-only CGEventTap on flagsChanged, tracking that Command was pressed with no other key or mouse click in between, then starting a timer. Read the frontmost app from NSWorkspace, create an AXUIElement for its pid and read the menu bar attribute, then walk children recursively collecting title, command character, command modifiers and enabled state using the Accessibility attributes AXMenuItemCmdChar, AXMenuItemCmdModifiers and AXMenuItemCmdGlyph. Convert modifier bitmasks to glyphs. Cache results per bundle identifier for a few seconds and refresh on app activation. In search mode, perform the chosen item with the AXPress action. Check permission with AXIsProcessTrustedWithOptions. Persist settings with AppStorage and use SMAppService for launch at login.

Edge cases and error handling. Cancel the pending overlay if any other key is pressed during the hold, so ordinary shortcuts like Command C never flash the overlay. Menu walking can be slow in large apps, so run it on a background task with a short timeout and show partial results. Some apps, such as those with custom menus, expose little through Accessibility, in which case show a polite note. Handle special glyph characters and function key shortcuts. Ignore the overlay while the system is in secure input or full-screen games listed as excluded. Keep the code near 450 lines.
