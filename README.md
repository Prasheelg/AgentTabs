# Agent Tabs

A small Windows app for opening [Claude Code](https://claude.com/claude-code) in your projects.
It lists your project folders; open one and Claude Code runs in a tab inside the launcher.
Tabs can be split into side-by-side or stacked panes, one Claude session per pane.

## Requirements

- Windows 10 or 11
- Claude Code installed, with `claude` on your `PATH` (check by running `claude --version` in a terminal)
- Windows Terminal is optional; it's only used by the "External terminal" option

Windows PowerShell 5.1 and .NET Framework 4 are also needed. Both come with Windows, so there's nothing else to install.

## Build the exe

From the project folder, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

This creates `dist\AgentTabs.exe`. The build uses the C# compiler that ships with Windows, so it needs no Visual Studio or SDK.

The exe is a single self-contained file with the launcher script embedded. When it runs, it copies the script to
`%LOCALAPPDATA%\AgentTabs` and starts it without a console window.

Rebuild after changing `AgentTabs.ps1`. The exe carries its own copy of the script, so it won't see your changes until it's rebuilt.

## Install on another machine

1. Copy `dist\AgentTabs.exe` anywhere, for example `C:\Tools`.
2. Double-click it. To pin it, right-click it and choose **Pin to Start** or **Pin to taskbar**.

The exe isn't code-signed, so the first time it runs Windows SmartScreen may say "Windows protected your PC".
Choose **More info**, then **Run anyway**.

## Run from source (without building)

Double-click `AgentTabs.vbs`. It starts the launcher with no console window flashing up.
`AgentTabs.bat` does the same, but briefly shows a console window. Keep it as a fallback, since Microsoft is
phasing out VBScript.

## Using it

- **Root folders...**: every subfolder of a root folder is listed as a project.
- **Add project...**: pin a single folder.
- **Remove** hides a project from the list. You can bring hidden projects back under **Root folders...**.
- **Enter** opens the selected project in a new tab.
- **Ctrl+Enter** (or **Open side by side**) opens the selected projects together in one split tab.
- Each pane's header has buttons to split right or split down, and a **...** menu to pop the pane out into its own tab or move it into another tab.
- The 5 most recently opened projects are listed first.

Options at the bottom of the window:

| Option | What it does |
|---|---|
| Reopen tabs | Restores the tabs and split layout you had open when you last closed the launcher |
| Resume last chat | Starts each session with `claude --continue` |
| Remote Control | Starts each session with `claude --remote-control <project>` |
| External terminal | Opens projects in Windows Terminal instead of inside the launcher |
| Glass window | Makes the window slightly see-through |

### Open a project from the command line

With the launcher running, this opens a folder in a new tab, using the options that are switched on
(so with Remote Control on, the new session shows up in the Claude app):

```
AgentTabs.exe open <folder>
```

It prints the result and exits with 0 on success or 1 on an error, such as a missing folder or the launcher not running.
A relative folder is resolved against the current directory. Running from source, use
`powershell -File AgentTabs.ps1 open <folder>`.

This lets you start a new project while you're away from the desk: ask a Claude session you're driving with
Remote Control to create the folder and run the command. PowerShell doesn't wait for a windowed program like
`AgentTabs.exe`, so from PowerShell run it as `cmd /c AgentTabs.exe open <folder>`. From bash or cmd it works as is.

Claude Code asks whether you trust a folder the first time it opens there, and nobody is at the desk to answer.
A folder inside one you already trust doesn't ask, so trust your root folder once: run `claude` in it and choose
**Yes, I trust this folder**. New projects created under it then open without the prompt.

### Keyboard shortcuts

These work even while you're typing in a session:

| Keys | Action |
|---|---|
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Ctrl+PgDn / Ctrl+PgUp | Next / previous tab |
| Ctrl+1 ... Ctrl+8 | Go to that tab (Ctrl+1 is Projects) |
| Ctrl+9 | Go to the last tab |
| Ctrl+Arrow keys | Move between panes of a split tab |

## Files it creates

| Path | Contents |
|---|---|
| `%APPDATA%\AgentTabs\config.json` | Settings: root folders, pinned and hidden projects, options, window position, open tabs |
| `%LOCALAPPDATA%\AgentTabs\error.log` | Details of any error that stopped the launcher from starting |
| `%LOCALAPPDATA%\AgentTabs\types\` | Cached compiled helpers, so the launcher starts faster (safe to delete) |
| `%LOCALAPPDATA%\AgentTabs\AgentTabs.ps1` | The script copied out of the exe |

If `config.json` can't be read, the launcher renames it to `config.json.bad-<date>` and starts with default settings.

## Project files

| File | Purpose |
|---|---|
| `AgentTabs.ps1` | The launcher (Windows PowerShell + WinForms) |
| `build.ps1` | Builds `dist\AgentTabs.exe` |
| `AgentTabs.vbs` / `AgentTabs.bat` | Run the script directly, without building |
