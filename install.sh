#!/bin/bash
set -e

# ---------- check for root (we need write access to /opt and /usr/local/bin) ----------
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (or use sudo)."
    exit 1
fi

# ---------- ensure python3, pip, venv ----------
if ! command -v python3 &>/dev/null; then
    echo "Installing python3 …"
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip python3-venv
else
    echo "python3 found, checking pip/venv …"
    # some minimal installs lack pip/venv
    if ! python3 -m pip --version &>/dev/null; then
        apt-get install -y -qq python3-pip
    fi
    if ! python3 -m venv --help &>/dev/null; then
        apt-get install -y -qq python3-venv
    fi
fi

# ---------- application directory ----------
APP_DIR="/opt/updown"
VENV_DIR="$APP_DIR/venv"
mkdir -p "$APP_DIR"

# ---------- create virtual environment ----------
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating Python virtual environment …"
    python3 -m venv "$VENV_DIR"
fi

# ---------- install dependencies ----------
echo "Installing server dependencies …"
"$VENV_DIR/bin/pip" install --quiet aiohttp aiofiles netifaces

# ---------- write the server script ----------
cat > "$APP_DIR/server.py" << 'PYEOF'
#!/usr/bin/env python3
"""
updown – asynchronous file upload & download server with progress bars.
Runs in the current directory.
"""

import asyncio
import json
import os
import socket
import sys
from pathlib import Path

try:
    import netifaces
    HAVE_NETIFACES = True
except ImportError:
    HAVE_NETIFACES = False

import aiohttp
from aiohttp import web

# ---------- HTML frontend (embedded) ----------
HTML_INDEX = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>updown</title>
<style>
  :root {
    --bg: #08080c;
    --card-bg: #111118;
    --surface: #1a1a24;
    --border: #1e1e2e;
    --border-hover: #2a2a3e;
    --primary: #22b8cf;
    --primary-glow: rgba(34, 184, 207, 0.12);
    --primary-dim: rgba(34, 184, 207, 0.05);
    --text: #d4d4d8;
    --text-muted: #52525b;
    --danger: #ef4444;
    --success: #22c55e;
    --radius: 8px;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 2rem 1rem;
    min-height: 100vh;
    background-image:
      radial-gradient(ellipse 80% 60% at 50% 0%, rgba(34, 184, 207, 0.03), transparent),
      radial-gradient(ellipse 60% 40% at 80% 100%, rgba(34, 184, 207, 0.02), transparent);
  }
  h1 {
    font-family: 'JetBrains Mono', monospace;
    font-size: 1.25rem;
    font-weight: 500;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    color: var(--text-muted);
    margin-bottom: 2rem;
    border: 1px solid var(--border);
    padding: 0.5rem 1.2rem;
    border-radius: var(--radius);
    display: inline-block;
  }
  .cards {
    display: flex;
    flex-wrap: wrap;
    gap: 1.5rem;
    width: 100%;
    max-width: 960px;
    justify-content: center;
  }
  .card {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 1.75rem;
    flex: 1 1 380px;
    min-width: 320px;
    transition: border-color 0.2s, box-shadow 0.2s;
  }
  .card:hover {
    border-color: var(--border-hover);
    box-shadow: 0 0 0 1px var(--border-hover);
  }
  .card h2 {
    font-family: 'JetBrains Mono', monospace;
    font-size: 0.8rem;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--text-muted);
    margin-bottom: 1.25rem;
    padding-bottom: 0.75rem;
    border-bottom: 1px solid var(--border);
  }
  #dropzone {
    border: 1px dashed var(--border-hover);
    border-radius: var(--radius);
    padding: 2.5rem 1rem;
    text-align: center;
    cursor: pointer;
    transition: background 0.2s, border-color 0.2s, box-shadow 0.2s;
    background: var(--primary-dim);
  }
  #dropzone:hover {
    background: var(--primary-glow);
  }
  #dropzone.dragover {
    background: var(--primary-glow);
    border-color: var(--primary);
    box-shadow: 0 0 24px var(--primary-glow);
  }
  #dropzone p {
    color: var(--text-muted);
    font-size: 0.85rem;
    font-family: 'JetBrains Mono', monospace;
  }
  #filelist { margin-top: 1rem; }
  .file-item {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.5rem 0;
    border-bottom: 1px solid var(--border);
  }
  .file-item:last-child { border-bottom: none; }
  .filename {
    min-width: 80px;
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 0.85rem;
    font-family: 'JetBrains Mono', monospace;
    color: var(--text);
  }
  progress {
    width: 100px;
    height: 4px;
    border-radius: 2px;
    border: none;
    background: var(--surface);
    accent-color: var(--primary);
  }
  progress::-webkit-progress-bar { background: var(--surface); border-radius: 2px; }
  progress::-webkit-progress-value { background: var(--primary); border-radius: 2px; }
  .status {
    font-size: 0.75rem;
    color: var(--text-muted);
    width: 50px;
    text-align: right;
    font-family: 'JetBrains Mono', monospace;
  }
  .toolbar {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .toolbar h2 {
    margin-bottom: 0;
    padding-bottom: 0;
    border-bottom: none;
  }
  .btn {
    background: transparent;
    color: var(--primary);
    border: 1px solid var(--border-hover);
    padding: 0.4rem 1rem;
    border-radius: var(--radius);
    cursor: pointer;
    font-size: 0.7rem;
    font-family: 'JetBrains Mono', monospace;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    transition: background 0.2s, border-color 0.2s, color 0.2s;
    text-decoration: none;
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    white-space: nowrap;
  }
  .btn:hover {
    background: var(--primary-glow);
    border-color: var(--primary);
    color: var(--primary);
  }
  .file-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.85rem;
  }
  .file-table th,
  .file-table td {
    padding: 0.6rem 0.4rem;
    text-align: left;
    border-bottom: 1px solid var(--border);
    font-family: 'JetBrains Mono', monospace;
    font-size: 0.8rem;
  }
  .file-table th {
    color: var(--text-muted);
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-size: 0.7rem;
  }
  .file-table td:last-child { text-align: right; white-space: nowrap; }
  .empty-msg {
    color: var(--text-muted);
    font-style: italic;
    padding: 1rem 0;
    font-size: 0.85rem;
    font-family: 'JetBrains Mono', monospace;
  }
</style>
<div class="cards">
  <div class="card">
    <h2>▴ Upload files</h2>
    <div id="dropzone">
      <p>+ Drop files here, or click to browse</p>
      <input type="file" id="fileinput" multiple style="display:none">
    </div>
    <div id="filelist"></div>
  </div>
  <div class="card">
    <div class="toolbar">
      <h2>▾ Download files</h2>
      <button id="refreshBtn" class="btn" title="Refresh file list">↻ Refresh</button>
    </div>
    <div id="downloadList"></div>
  </div>
</div>

<script>
  const dropzone = document.getElementById('dropzone');
  const fileinput = document.getElementById('fileinput');
  const filelist = document.getElementById('filelist');

  dropzone.addEventListener('click', () => fileinput.click());
  dropzone.addEventListener('dragover', (e) => {
    e.preventDefault();
    dropzone.classList.add('dragover');
  });
  dropzone.addEventListener('dragleave', () => dropzone.classList.remove('dragover'));
  dropzone.addEventListener('drop', (e) => {
    e.preventDefault();
    dropzone.classList.remove('dragover');
    if (e.dataTransfer.files.length) handleFiles(e.dataTransfer.files);
  });
  fileinput.addEventListener('change', () => {
    if (fileinput.files.length) handleFiles(fileinput.files);
  });

  function handleFiles(files) {
    for (const file of files) uploadFile(file);
  }

  function uploadFile(file) {
    const itemDiv = document.createElement('div');
    itemDiv.className = 'file-item';
    const nameSpan = document.createElement('span');
    nameSpan.className = 'filename';
    nameSpan.textContent = file.name;
    const progressBar = document.createElement('progress');
    progressBar.value = 0;
    progressBar.max = 100;
    const statusSpan = document.createElement('span');
    statusSpan.className = 'status';
    statusSpan.textContent = '0%';
    itemDiv.appendChild(nameSpan);
    itemDiv.appendChild(progressBar);
    itemDiv.appendChild(statusSpan);
    filelist.appendChild(itemDiv);

    const formData = new FormData();
    formData.append('file', file, file.name);
    const xhr = new XMLHttpRequest();

    xhr.upload.addEventListener('progress', (e) => {
      if (e.lengthComputable) {
        const percent = Math.round((e.loaded / e.total) * 100);
        progressBar.value = percent;
        statusSpan.textContent = percent + '%';
      }
    });

    xhr.addEventListener('load', () => {
      progressBar.value = 100;
      statusSpan.textContent = 'Done';
      refreshFileList();
    });

    xhr.addEventListener('error', () => {
      statusSpan.textContent = 'Error';
      progressBar.style.accentColor = 'var(--danger)';
    });

    xhr.addEventListener('abort', () => {
      statusSpan.textContent = 'Aborted';
    });

    xhr.open('POST', '/upload');
    xhr.send(formData);
  }

  const downloadList = document.getElementById('downloadList');
  const refreshBtn = document.getElementById('refreshBtn');
  refreshBtn.addEventListener('click', refreshFileList);

  async function refreshFileList() {
    try {
      const resp = await fetch('/files');
      if (!resp.ok) throw new Error('Server error');
      const files = await resp.json();
      renderDownloadList(files);
    } catch (err) {
      downloadList.innerHTML = '<div class="empty-msg">Could not load file list</div>';
    }
  }

  function formatSize(bytes) {
    if (bytes === 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    const size = (bytes / Math.pow(1024, i)).toFixed(i > 0 ? 1 : 0);
    return size + ' ' + units[i];
  }

  function renderDownloadList(files) {
    if (!files.length) {
      downloadList.innerHTML = '<div class="empty-msg">No files in current directory</div>';
      return;
    }
    let html = '<table class="file-table">' +
      '<thead><tr><th>Name</th><th>Size</th><th></th></tr></thead><tbody>';
    for (const f of files) {
      html += '<tr>' +
        '<td title="' + escapeHtml(f.name) + '">' + escapeHtml(truncate(f.name, 40)) + '</td>' +
        '<td>' + formatSize(f.size) + '</td>' +
        '<td><a class="btn" href="/download/' + encodeURIComponent(f.name) + '" download>↓ Download</a></td>' +
        '</tr>';
    }
    html += '</tbody></table>';
    downloadList.innerHTML = html;
  }

  function escapeHtml(text) {
    const map = {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;'};
    return text.replace(/[&<>"']/g, m => map[m]);
  }

  function truncate(name, maxLen) {
    return name.length > maxLen ? name.slice(0, maxLen-3) + '...' : name;
  }

  refreshFileList();
</script>
</body>
</html>
"""

# ---------- IP detection ----------
def get_local_ips():
    ips = []
    if HAVE_NETIFACES:
        for iface in netifaces.interfaces():
            addrs = netifaces.ifaddresses(iface)
            if netifaces.AF_INET in addrs:
                for addr in addrs[netifaces.AF_INET]:
                    ip = addr['addr']
                    if ip != '127.0.0.1':
                        ips.append(ip)
        if not ips:
            ips.append('127.0.0.1')
    else:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(('8.8.8.8', 80))
            ips.append(s.getsockname()[0])
            s.close()
        except Exception:
            ips.append('127.0.0.1')
        if '127.0.0.1' not in ips:
            ips.append('127.0.0.1')
    ips = sorted(set(ips))
    return ips

# ---------- Upload handler (streaming) ----------
async def upload_file(request: web.Request) -> web.Response:
    reader = await request.multipart()
    field = await reader.next()
    if not field or field.name != 'file':
        return web.Response(text='No file field found.', status=400)

    filename = field.filename
    if not filename:
        return web.Response(text='No filename provided.', status=400)

    # Sanitize: only the base name, no paths
    safe_name = Path(filename).name
    filepath = Path.cwd() / safe_name

    try:
        import aiofiles
        async with aiofiles.open(filepath, 'wb') as f:
            while True:
                chunk = await field.read_chunk(1024 * 1024)  # 1 MB
                if not chunk:
                    break
                await f.write(chunk)
    except Exception as e:
        if filepath.exists():
            filepath.unlink()
        return web.Response(text=f'Upload failed: {e}', status=500)

    return web.Response(text=f'Uploaded successfully ({safe_name})')

# ---------- List files in CWD ----------
async def list_files(request: web.Request) -> web.Response:
    cwd = Path.cwd()
    files = []
    for entry in cwd.iterdir():
        if entry.is_file():
            files.append({
                "name": entry.name,
                "size": entry.stat().st_size
            })
    files.sort(key=lambda x: x["name"].lower())
    return web.json_response(files)

# ---------- Download a file ----------
async def download_file(request: web.Request) -> web.Response:
    raw_name = request.match_info['filename']
    safe_name = Path(raw_name).name
    filepath = Path.cwd() / safe_name

    if not filepath.is_file():
        raise web.HTTPNotFound(text='File not found')

    return web.FileResponse(
        path=filepath,
        headers={'Content-Disposition': f'attachment; filename="{safe_name}"'}
    )

# ---------- Serve the HTML page ----------
async def index(request: web.Request) -> web.Response:
    return web.Response(text=HTML_INDEX, content_type='text/html')

# ---------- Main ----------
def main():
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind(('', 0))
        port = sock.getsockname()[1]
        sock.close()
    except OSError as e:
        print(f"Could not find a free port: {e}", file=sys.stderr)
        sys.exit(1)

    ips = get_local_ips()
    if not ips:
        print("Could not determine any local IP address.", file=sys.stderr)
        sys.exit(1)

    print("=" * 50)
    print("File Exchange Server (Upload + Download) is running!")
    print("Access it from any of these addresses:")
    for ip in ips:
        print(f"  {ip:15}   http://{ip}:{port}")
    print("=" * 50)

    app = web.Application(client_max_size=0)  # no upload size limit
    app.router.add_get('/', index)
    app.router.add_post('/upload', upload_file)
    app.router.add_get('/files', list_files)
    app.router.add_get('/download/{filename}', download_file)

    web.run_app(app, host='0.0.0.0', port=port, print=None)

if __name__ == '__main__':
    main()
PYEOF

chmod +x "$APP_DIR/server.py"

# ---------- create /usr/local/bin/updown ----------
cat > /usr/local/bin/updown << 'EOF'
#!/bin/bash
exec /opt/updown/venv/bin/python /opt/updown/server.py "$@"
EOF

chmod +x /usr/local/bin/updown

echo ""
echo "✅ updown installed successfully!"
echo "   Now run:   updown"
echo "   The server will start in your current directory."