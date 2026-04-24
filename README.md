# Unify Desktop Assistant

A cross-platform application that sets up your machine as a remote-controllable AI assistant workstation, with VNC-based desktop sharing and an AI agent service powered by [Magnitude](https://github.com/magnitudedev/magnitude).

## Repository Structure

```
unify-desktop-assistant/
├── windows/                   # Windows (Inno Setup installer + tray GUI)
│   ├── agent-service/         # AI agent API service
│   ├── magnitude/             # Browser automation framework
│   ├── gui/                   # System tray app
│   ├── installer/             # Inno Setup build files
│   └── tools/                 # Setup & utility scripts
├── macos/                     # macOS (shell scripts)
│   ├── agent-service/
│   ├── magnitude/
│   └── *.sh
├── ubuntu/                    # Ubuntu/Linux (.deb package)
│   ├── agent-service/
│   ├── magnitude/
│   └── ...
└── .github/workflows/         # CI: syncs agent-service & magnitude
```

Each platform folder is **self-contained** with its own copy of `agent-service/` and `magnitude/`. These are kept in sync via GitHub Actions.

## Platform Guides

| Platform | Guide | Install Method |
|----------|-------|----------------|
| **Windows** | [windows/README.md](windows/README.md) | Inno Setup installer |
| **macOS** | [macos/README.md](macos/README.md) | Shell scripts |
| **Ubuntu/Linux** | [ubuntu/README.md](ubuntu/README.md) | Debian (`.deb`) installer |
