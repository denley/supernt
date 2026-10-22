#!/usr/bin/env python3
"""Record the Super Nt's HDMI through the USB capture dongle and show it live on a phone.

Usage: capview.py [OUTDIR]   (default ~/scratch/cap)

One ffmpeg reads the MS2109 dongle (/dev/video0 MJPEG 1920x1080 30 fps, audio from ALSA card
MS2109) and writes:
  - OUTDIR/rec-YYYYmmdd-HHMMSS.mkv: the full-resolution MJPEG stream as captured, with sound;
  - a 960x540 10 fps MJPEG stream, served over HTTP on the tailnet address only:
      http://homebox.jaguar-munsell.ts.net:8765/        live view (open on the phone)
      http://homebox.jaguar-munsell.ts.net:8765/snap.jpg latest frame
Ctrl-C (or kill) stops the recording. Frames for reading: tools/frames.sh REC.mkv DIR [fps].
"""
import glob
import http.server
import os
import socketserver
import subprocess
import sys
import threading
import time

ADDR = ('100.110.207.42', 8765)   # homebox's tailnet IP: not reachable from the LAN/internet
outdir = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/scratch/cap')
os.makedirs(outdir, exist_ok=True)
ff = (glob.glob(os.path.expanduser(
    '~/scratch/ffvenv/lib/python3*/site-packages/imageio_ffmpeg/binaries/ffmpeg-*')) or ['ffmpeg'])[0]
rec = os.path.join(outdir, time.strftime('rec-%Y%m%d-%H%M%S.mkv'))
cmd = [ff, '-hide_banner', '-loglevel', 'error',
       '-f', 'v4l2', '-input_format', 'mjpeg', '-video_size', '1920x1080', '-framerate', '30',
       '-thread_queue_size', '512', '-i', '/dev/video0',
       '-f', 'alsa', '-thread_queue_size', '512', '-i', 'hw:CARD=MS2109',
       '-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'pcm_s16le', rec,
       '-map', '0:v', '-vf', 'fps=10,scale=960:540', '-c:v', 'mjpeg', '-q:v', '5',
       '-f', 'mpjpeg', '-boundary_tag', 'frame', 'pipe:1']
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)

latest = b''
cond = threading.Condition()


def reader():
    """Split ffmpeg's multipart output into JPEG frames."""
    global latest
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
                cond.notify_all()
            buf = buf[e + 2:]


PAGE = b"""<!doctype html><meta name=viewport content="width=device-width">
<title>Super Nt</title><body style="margin:0;background:#000">
<img src="/stream" style="width:100%">"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(PAGE)
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
                while proc.poll() is None:
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


threading.Thread(target=reader, daemon=True).start()
print(f'recording {rec}; live view http://homebox.jaguar-munsell.ts.net:{ADDR[1]}/', flush=True)
srv = Server(ADDR, Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
try:
    proc.wait()
except KeyboardInterrupt:
    pass
finally:
    proc.terminate()
    proc.wait()
    srv.shutdown()
