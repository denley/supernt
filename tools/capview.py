#!/usr/bin/env python3
"""Record the Super Nt's HDMI through the USB capture dongle and show it live on a phone.

Usage: capview.py [OUTDIR]   (default ~/scratch/cap)

One ffmpeg reads the MS2109 dongle (/dev/video0 MJPEG 1920x1080 30 fps, audio from ALSA card
MS2109) and writes:
  - OUTDIR/rec-YYYYmmdd-HHMMSS.mkv: the full-resolution MJPEG stream as captured, with sound;
  - a 960x540 10 fps MJPEG stream, served over HTTP on the tailnet address only:
      http://homebox.jaguar-munsell.ts.net:8765/        live view (open on the phone)
      http://homebox.jaguar-munsell.ts.net:8765/snap.jpg latest frame
The live view fetches one frame at a time (/next.jpg?after=N waits for a frame newer than N), so
it picks up again by itself when the phone comes back from another app or the network drops
(a multipart MJPEG <img> stream, still at /stream, stays frozen on iOS until the page is
reloaded). It says "no new frames" when the picture hasn't changed for 3 s (no HDMI signal).
The capture ends whenever the HDMI signal goes away (console off, core loading, video mode
change), so ffmpeg is restarted in a loop, one rec-*.mkv per stretch of signal. Ctrl-C (or
kill -INT) stops it. Frames for reading: tools/frames.sh REC.mkv DIR [fps].

Disk use (MJPEG is ~6 GB an hour; one overnight run left on filled 63 GB): rec-*.mkv files older
than KEEP_DAYS are deleted whenever a recording starts, and when the disk gets below MIN_FREE_GB
free, recording stops (the live view keeps going) and homebox-notify pushes to Denley's phone.
Copy a recording elsewhere if a note needs it kept longer.
"""
import glob
import shutil
import http.server
import os
import socketserver
import subprocess
import sys
import threading
import time

ADDR = ('100.110.207.42', 8765)   # homebox's tailnet IP: not reachable from the LAN/internet
KEEP_DAYS = 7
MIN_FREE_GB = 80                  # health-check warns at 85% of 452 GB, i.e. ~68 GB free
NOTIFY = os.path.expanduser('~/server/updates/homebox-notify')
outdir = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/scratch/cap')
os.makedirs(outdir, exist_ok=True)
ff = (glob.glob(os.path.expanduser(
    '~/scratch/ffvenv/lib/python3*/site-packages/imageio_ffmpeg/binaries/ffmpeg-*')) or ['ffmpeg'])[0]


def ffmpeg_cmd(rec):
    """rec=None: live view only, nothing written to disk."""
    cmd = [ff, '-hide_banner', '-loglevel', 'error',
           '-f', 'v4l2', '-input_format', 'mjpeg', '-video_size', '1920x1080', '-framerate', '30',
           '-thread_queue_size', '512', '-i', '/dev/video0']
    if rec:
        cmd += ['-f', 'alsa', '-thread_queue_size', '512', '-i', 'hw:CARD=MS2109',
                '-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'pcm_s16le', rec]
    return cmd + ['-map', '0:v', '-vf', 'fps=10,scale=960:540', '-c:v', 'mjpeg', '-q:v', '5',
                  '-f', 'mpjpeg', '-boundary_tag', 'frame', 'pipe:1']


def free_gb():
    return shutil.disk_usage(outdir).free / 1e9


def prune():
    """Delete recordings older than KEEP_DAYS."""
    cutoff = time.time() - KEEP_DAYS * 86400
    for f in glob.glob(os.path.join(outdir, 'rec-*.mkv')):
        if os.path.getmtime(f) < cutoff:
            print(f'deleting {f} (older than {KEEP_DAYS} days)', flush=True)
            os.remove(f)


def stop_recording():
    """Disk nearly full: carry on with the live view only."""
    global recording
    recording = False
    msg = f'Under {MIN_FREE_GB} GB free on /: stopped recording, live view still on. ' \
          f'Delete old {outdir}/rec-*.mkv and restart capview.'
    print(msg, flush=True)
    subprocess.run([NOTIFY, '--tag', 'capview', 'capview stopped recording', msg])
    if proc:
        proc.terminate()            # the reader loop restarts ffmpeg without the file output


def disk_guard():
    while not stopping:
        if recording and free_gb() < MIN_FREE_GB:
            stop_recording()
        time.sleep(30)


proc = None
stopping = False
recording = True
latest = b''
frame_id = 0
cond = threading.Condition()


def reader():
    """Run ffmpeg (restarting it when the signal drops) and split its multipart output into
    JPEG frames."""
    global latest, frame_id, proc
    while not stopping:
        prune()
        if recording and free_gb() < MIN_FREE_GB:
            stop_recording()
        rec = os.path.join(outdir, time.strftime('rec-%Y%m%d-%H%M%S.mkv')) if recording else None
        proc = subprocess.Popen(ffmpeg_cmd(rec), stdout=subprocess.PIPE)
        print(f'recording {rec}' if rec else 'live view only, not recording', flush=True)
        buf = b''
        while True:
            chunk = proc.stdout.read(65536)
            if not chunk:
                break
            buf += chunk
            while True:
                s = buf.find(b'\xff\xd8')
                e = buf.find(b'\xff\xd9', s + 2)
                if s < 0 or e < 0:
                    break
                with cond:
                    latest = buf[s:e + 2]
                    frame_id += 1
                    cond.notify_all()
                buf = buf[e + 2:]
        proc.wait()
        if rec and os.path.exists(rec) and os.path.getsize(rec) < 100000:
            os.remove(rec)          # no signal: nothing worth keeping
        time.sleep(1)


PAGE = b"""<!doctype html><meta name=viewport content="width=device-width">
<title>Super Nt</title><body style="margin:0;background:#000;color:#ccc;font:14px sans-serif">
<img id=v style="width:100%;display:block"><div id=s style="padding:4px 8px"></div>
<script>
// One frame per request: survives the tab being suspended (iOS app switch) without a reload.
let after = 0, last = Date.now(), url = null, gen = 0;
const v = document.getElementById('v'), s = document.getElementById('s');
async function run(g) {
  while (g === gen) {
    try {
      const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), 5000);
      const r = await fetch('/next.jpg?after=' + after, {cache: 'no-store', signal: ctl.signal});
      clearTimeout(t);
      if (g !== gen) return;
      const id = +r.headers.get('X-Frame-Id');
      if (r.ok && id > after) {
        after = id; last = Date.now();
        const u = URL.createObjectURL(await r.blob());
        v.src = u; if (url) URL.revokeObjectURL(url); url = u;
      }
      if (id < after) after = 0;          // the server restarted
    } catch (e) { await new Promise(ok => setTimeout(ok, 500)); }
  }
}
function start() { gen++; run(gen); }
document.addEventListener('visibilitychange', () => { if (!document.hidden) start(); });
window.addEventListener('pageshow', start);
window.addEventListener('focus', start);
setInterval(() => {
  const age = (Date.now() - last) / 1000;
  s.textContent = age > 3 ? 'no new frames for ' + age.toFixed(0) + ' s (no HDMI signal?)' : '';
  if (age > 6 && !document.hidden) start();   // a stuck request: start over
}, 1000);
start();
</script>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(PAGE)
        elif self.path.startswith('/next.jpg'):
            try:
                after = int(self.path.split('after=')[1].split('&')[0])
            except (IndexError, ValueError):
                after = 0
            with cond:
                cond.wait_for(lambda: frame_id != after or stopping, timeout=2)
                f, fid = latest, frame_id
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Frame-Id', str(fid))
            self.send_header('Content-Length', str(len(f)))
            self.end_headers()
            self.wfile.write(f)
        elif self.path.startswith('/snap.jpg'):
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.end_headers()
            self.wfile.write(latest)
        elif self.path == '/stream':
            self.send_response(200)
            self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
            self.end_headers()
            try:
                while not stopping:
                    with cond:
                        cond.wait(2)
                        f = latest
                    self.wfile.write(b'--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d'
                                     b'\r\n\r\n' % len(f) + f + b'\r\n')
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_error(404)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


print(f'live view http://homebox.jaguar-munsell.ts.net:{ADDR[1]}/', flush=True)
srv = Server(ADDR, Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=disk_guard, daemon=True).start()
try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    pass
finally:
    stopping = True
    if proc:
        proc.terminate()
        proc.wait()
    srv.shutdown()
