# SoftBar

An on-screen replacement for a broken MacBook Pro Touch Bar.
A small floating bar with **Esc, F1–F12, brightness, keyboard light, media, volume, screenshot and lock**.

Works on Intel and Apple Silicon Macs running macOS 10.15 Catalina or newer. No admin password needed.

## Install

Open **Terminal** and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/ahmadwaqar17/softbar/main/install.sh | bash
```

Or, if you were sent the file: `bash ~/Downloads/install.sh`

Then turn on **SoftBar** in System Settings → Privacy & Security → **Accessibility**.
If Apple's Command Line Tools aren't installed yet, a window pops up first. Click **Install** and the script continues by itself.

## Use

- Click the buttons. Volume, brightness and keyboard light repeat while held.
- Hold the **fn** key to show F1–F12, or click **fn** on the bar.
- **Ctrl+Option+T** shows or hides the bar. Drag it anywhere.
- The menu bar icon has more options and Quit.
- It starts automatically at login.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ahmadwaqar17/softbar/main/install.sh | bash -s -- --uninstall
```
