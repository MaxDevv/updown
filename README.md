# updown

Minimal async file upload/download server with a dark-themed web UI and progress bars. Drops into your current directory — no config, no daemonization. Useful when `scp`/`sftp` feels heavy.

## Install

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/MaxDevv/updown/install.sh | sudo bash
```

## Usage

```bash
cd /path/to/share && updown
```

The server binds to `0.0.0.0` on a random port and prints the accessible URLs. Upload files via drag-and-drop, download any file in the directory with one click.


## Requirements

- Python 3.8+
- Linux (tested on Debian/Ubuntu; install script uses `apt`)

## Uninstall

```bash
sudo rm -rf /opt/updown /usr/local/bin/updown
```
