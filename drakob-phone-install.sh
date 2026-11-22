#!/usr/bin/env bash
# DRAKOB Phone - cài điện thoại Android ảo (redroid) + máy chủ điều khiển + HTTPS tự động.
# Chạy trên VPS/PC Linux (Ubuntu 22.04/24.04 hoặc Debian 12) với quyền root:
#   sudo bash drakob-phone-install.sh
# Tuỳ chọn (biến môi trường): PHONES=2  ANDROID=13.0.0  WIDTH=720 HEIGHT=1280 DPI=320  DOMAIN=ten-mien-cua-ban.com
#   TUNNEL=tailscale  → KHÔNG cần thẻ, KHÔNG cần mở cổng, chạy được trên máy tính/laptop cũ ở nhà (dùng Tailscale Funnel miễn phí)
#   TUNNEL=caddy (mặc định) → VPS có IP công khai, tự lấy HTTPS bằng Caddy + sslip.io
#   ORIGINS=https://drakob-ai.vercel.app   Gỡ cài: sudo bash drakob-phone-install.sh --uninstall
#   Ví dụ: sudo TUNNEL=tailscale PHONES=2 bash drakob-phone-install.sh
set -euo pipefail

PHONES="${PHONES:-1}"
ANDROID="${ANDROID:-13.0.0}"
WIDTH="${WIDTH:-720}"; HEIGHT="${HEIGHT:-1280}"; DPI="${DPI:-320}"; FPS="${FPS:-30}"
ORIGINS="${ORIGINS:-https://drakob-ai.vercel.app}"
TUNNEL="${TUNNEL:-caddy}"
case "$TUNNEL" in caddy|tailscale) ;; *) echo "TUNNEL chỉ nhận caddy hoặc tailscale" >&2; exit 1;; esac
DIR=/opt/drakob-phone; ENVF=/etc/drakob-phone.env; DATA=/var/lib/drakob-phone

c() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
w() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mLỖI: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "Hãy chạy bằng root: sudo bash $0"

if [ "${1:-}" = "--uninstall" ]; then
  c "Gỡ DRAKOB Phone (giữ lại dữ liệu điện thoại ở $DATA)"
  systemctl disable --now drakob-phone 2>/dev/null || true
  rm -f /etc/systemd/system/drakob-phone.service; systemctl daemon-reload || true
  for i in $(seq 0 9); do docker rm -f "drakob-phone-$i" 2>/dev/null || true; done
  command -v tailscale >/dev/null && tailscale funnel reset 2>/dev/null || true
  rm -rf "$DIR" /etc/caddy/Caddyfile.d-drakob; sed -i '/DRAKOB-PHONE-BEGIN/,/DRAKOB-PHONE-END/d' /etc/caddy/Caddyfile 2>/dev/null || true
  systemctl reload caddy 2>/dev/null || true
  echo "Đã gỡ. Xoá hẳn dữ liệu bằng: rm -rf $DATA $ENVF"; exit 0
fi

case "$PHONES" in ''|*[!0-9]*) die "PHONES phải là số";; esac
[ "$PHONES" -ge 1 ] && [ "$PHONES" -le 8 ] || die "PHONES từ 1 đến 8"
command -v apt-get >/dev/null || die "Script này hỗ trợ Ubuntu/Debian (có apt)."
ARCH="$(uname -m)"; case "$ARCH" in x86_64|aarch64) ;; *) die "Kiến trúc $ARCH chưa hỗ trợ (cần x86_64 hoặc aarch64)";; esac
if [ "$ARCH" = aarch64 ]; then
  # Máy ARM (Oracle A1/A2...) nên dùng ảnh 64-bit để tránh lỗi 32-bit.
  case "$ANDROID" in *_64only) ;; *) ANDROID="${ANDROID}_64only";; esac
fi
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
NEED=$((PHONES*1500+500))
[ "$MEM_MB" -ge "$NEED" ] || w "RAM $MEM_MB MB hơi ít cho $PHONES máy (khuyến nghị ≥ $NEED MB). Vẫn tiếp tục."
c "Máy: $ARCH, RAM ${MEM_MB} MB, Android $ANDROID, $PHONES điện thoại"

export DEBIAN_FRONTEND=noninteractive
c "Cài gói cần thiết"
apt-get update -y >/dev/null
apt-get install -y curl ca-certificates gnupg openssl python3 python3-pil adb debian-keyring debian-archive-keyring apt-transport-https >/dev/null \
  || apt-get install -y curl ca-certificates gnupg openssl python3 python3-pil android-tools-adb >/dev/null || die "Không cài được gói cơ bản"
command -v adb >/dev/null || apt-get install -y android-tools-adb >/dev/null || die "Không cài được adb"

c "Chuẩn bị nhân Linux (binder cho Android)"
apt-get install -y "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || w "Không cài được linux-modules-extra-$(uname -r) (có thể đã có sẵn)"
modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
modprobe ashmem_linux 2>/dev/null || true
if ! lsmod | grep -q binder_linux && [ ! -e /dev/binder ] && ! grep -q binder /proc/filesystems 2>/dev/null; then
  die "Nhân Linux của máy này không có binder_linux (thường gặp trên VPS dùng ảo hoá container/OpenVZ hoặc nhân tuỳ biến). Hãy dùng VPS KVM chạy Ubuntu 22.04/24.04 chuẩn, hoặc Oracle Cloud Always Free."
fi
echo binder_linux > /etc/modules-load.d/drakob-phone.conf
echo 'options binder_linux devices=binder,hwbinder,vndbinder' > /etc/modprobe.d/drakob-phone.conf
modprobe ashmem_linux 2>/dev/null && echo ashmem_linux >> /etc/modules-load.d/drakob-phone.conf || true

if ! command -v docker >/dev/null; then
  c "Cài Docker"
  curl -fsSL https://get.docker.com | sh >/dev/null || die "Không cài được Docker"
fi
systemctl enable --now docker >/dev/null 2>&1 || true

mkdir -p "$DIR" "$DATA"
if [ -f "$ENVF" ]; then . "$ENVF"; else
  PHONE_SECRET="$(openssl rand -hex 24)"
fi

c "Tạo $PHONES điện thoại Android $ANDROID"
DEVS=""; CONS=""
for i in $(seq 0 $((PHONES-1))); do
  N="drakob-phone-$i"; P=$((5555+i)); mkdir -p "$DATA/d$i"
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$N"; then
    docker run -itd --privileged --restart unless-stopped --name "$N" \
      -v "$DATA/d$i:/data" -p "127.0.0.1:$P:5555" \
      "redroid/redroid:$ANDROID" \
      androidboot.redroid_width="$WIDTH" androidboot.redroid_height="$HEIGHT" androidboot.redroid_dpi="$DPI" \
      androidboot.redroid_fps="$FPS" androidboot.redroid_gpu_mode=guest >/dev/null \
      || die "Không chạy được container $N. Xem: docker logs $N"
  else docker start "$N" >/dev/null 2>&1 || true; fi
  DEVS="${DEVS:+$DEVS,}127.0.0.1:$P"; CONS="${CONS:+$CONS,}$N"
done

setup_tailscale() {
  c "Cài Tailscale (đường hầm HTTPS miễn phí, không cần thẻ, không cần mở cổng)"
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh >/dev/null || die "Không cài được Tailscale"
  systemctl enable --now tailscaled >/dev/null 2>&1 || true
  if ! tailscale status >/dev/null 2>&1 || tailscale status 2>&1 | grep -qiE 'logged out|needs login|NeedsLogin'; then
    echo
    w "BẠN CẦN LÀM 1 VIỆC: mở liên kết hiện ra bên dưới trong trình duyệt, đăng nhập bằng Google/Microsoft/GitHub để cho máy này vào mạng Tailscale của bạn (miễn phí)."
    timeout 900 tailscale up --hostname=drakob-phone || die "Chưa đăng nhập Tailscale. Chạy lại script để thử lại."
  fi
  c "Bật Funnel (địa chỉ https công khai cho máy chủ điện thoại)"
  echo "   Nếu hiện một liên kết yêu cầu 'enable Funnel' / 'HTTPS certificates': mở nó, bấm bật, script sẽ tự chạy tiếp."
  timeout 900 tailscale funnel --bg 8787 || {
    w "Chưa bật được Funnel. Vào https://login.tailscale.com/admin/dns → bật 'MagicDNS' và 'HTTPS Certificates', rồi chạy lại script."
    die "Funnel chưa sẵn sàng"; }
  TS_NAME="$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
  [ -n "$TS_NAME" ] || die "Không đọc được tên miền Tailscale (chạy: tailscale status)"
  DOMAIN="$TS_NAME"
}
if [ "$TUNNEL" = tailscale ]; then
  [ -n "${DOMAIN:-}" ] && DOMAIN=""
  setup_tailscale
else
  IP="${PUBIP:-$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)}"
  if [ -z "${DOMAIN:-}" ]; then
    [ -n "$IP" ] || die "Không lấy được IP công khai. Chạy lại với: PUBIP=1.2.3.4 sudo -E bash $0 (hoặc dùng TUNNEL=tailscale)"
    DOMAIN="$(echo "$IP" | tr . -).sslip.io"
  fi
fi

cat > "$ENVF" <<EOF
PHONE_SECRET=$PHONE_SECRET
PHONE_DEVICES=$DEVS
PHONE_CONTAINERS=$CONS
PHONE_ORIGINS=$ORIGINS
PHONE_PORT=8787
PHONE_BIND=127.0.0.1
DOMAIN=$DOMAIN
EOF
chmod 600 "$ENVF"

c "Cài máy chủ điều khiển"
cat > "$DIR/phone_server.py" <<'DKEOF'
#!/usr/bin/env python3
"""DRAKOB Phone server: điều khiển và xem màn hình điện thoại Android ảo (redroid) qua HTTP.

Chạy sau Caddy (HTTPS). Mọi yêu cầu cần token ngắn hạn do Edge Function `phone-proxy` của DRAKOB ký bằng
PHONE_SECRET (HMAC-SHA256). Không có token hợp lệ thì không làm được gì.

Biến môi trường: PHONE_SECRET, PHONE_DEVICES (vd localhost:5555,localhost:5556), PHONE_CONTAINERS,
PHONE_ORIGINS (danh sách origin được phép, phân cách bằng dấu phẩy, * = tất cả), PHONE_PORT, PHONE_BIND, ADB.
"""
import base64, hashlib, hmac, io, json, os, re, shutil, struct, subprocess, sys, tempfile, threading, time, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    from PIL import Image
except Exception:  # không có Pillow: dùng bộ mã hóa PNG thuần Python (chậm hơn nhưng chạy được)
    Image = None

SECRET = os.environ.get("PHONE_SECRET", "").encode()
DEVICES = [d.strip() for d in os.environ.get("PHONE_DEVICES", "localhost:5555").split(",") if d.strip()]
CONTAINERS = [c.strip() for c in os.environ.get("PHONE_CONTAINERS", "").split(",") if c.strip()]
ORIGINS = [o.strip().rstrip("/") for o in os.environ.get("PHONE_ORIGINS", "*").split(",") if o.strip()]
ADB = os.environ.get("ADB", "adb")
PORT = int(os.environ.get("PHONE_PORT", "8787"))
BIND = os.environ.get("PHONE_BIND", "127.0.0.1")
MAX_APK = int(os.environ.get("PHONE_MAX_APK_MB", "400")) * 1024 * 1024
IDLE = 6.0  # giây không ai xem thì ngừng chụp màn hình

KEYS = {3, 4, 187, 24, 25, 26, 66, 67, 112, 61, 82, 224, 223, 164, 19, 20, 21, 22, 23, 111, 92, 93, 84, 122, 123, 85, 87, 88, 62, 160}
PKG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
IME = "com.android.adbkeyboard/.AdbIME"


def b64u_dec(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def verify(tok):
    """Token = base64url(JSON{v,exp,n}) + '.' + hex(HMAC_SHA256(secret, phần trước))."""
    if not SECRET or not tok or len(tok) > 400 or "." not in tok:
        return False
    body, sig = tok.split(".", 1)
    good = hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, good):
        return False
    try:
        j = json.loads(b64u_dec(body))
        now = time.time()
        return j.get("v") == 1 and now < float(j["exp"]) < now + 3600
    except Exception:
        return False


def sq(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def png_rgba(w, h, data):
    raw = b"".join(b"\x00" + data[y * w * 4:(y + 1) * w * 4] for y in range(h))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b"")


class Phone:
    def __init__(self, idx, serial):
        self.idx, self.serial = idx, serial
        self.cond = threading.Condition()
        self.seq = 0
        self.size = (0, 0)
        self.rgba = None
        self.crc = None
        self.last_req = 0.0
        self.err = ""
        self.cache = (None, None)
        self.io = threading.Lock()  # giữ đúng thứ tự chạm/vuốt
        self.ime_ok = None
        threading.Thread(target=self.loop, daemon=True).start()

    def adb(self, *args, timeout=20, data=None):
        return subprocess.run([ADB, "-s", self.serial, *args], capture_output=True, timeout=timeout, input=data)

    def sh(self, cmd, timeout=20):
        r = self.adb("shell", cmd, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).decode("utf-8", "replace")

    def connect(self):
        try:
            subprocess.run([ADB, "connect", self.serial], capture_output=True, timeout=10)
        except Exception:
            pass

    def capture(self):
        r = self.adb("exec-out", "screencap", timeout=15)
        raw = r.stdout
        if r.returncode != 0 or len(raw) < 20:
            raise RuntimeError((r.stderr or "screencap lỗi".encode()).decode("utf-8", "replace")[:200])
        w, h = struct.unpack("<II", raw[:8])
        need = w * h * 4
        hdr = len(raw) - need
        if not (0 < w < 5000 and 0 < h < 5000) or hdr not in (12, 16):
            raise RuntimeError("định dạng screencap lạ (%dx%d, header %d)" % (w, h, hdr))
        return w, h, raw[hdr:]

    def loop(self):
        last_conn = 0
        while True:
            if time.time() - self.last_req > IDLE:
                time.sleep(0.25)
                continue
            if time.time() - last_conn > 25:
                self.connect()
                last_conn = time.time()
            t0 = time.time()
            try:
                w, h, data = self.capture()
                crc = zlib.crc32(data)
                with self.cond:
                    self.err = ""
                    if crc != self.crc or self.size != (w, h):
                        self.crc, self.size, self.rgba = crc, (w, h), data
                        self.seq += 1
                        self.cond.notify_all()
            except Exception as e:
                with self.cond:
                    self.err = str(e)[:200]
                    self.cond.notify_all()
                time.sleep(1.0)
            dt = time.time() - t0
            if dt < 0.08:
                time.sleep(0.08 - dt)

    def frame(self, since, scale, q):
        """Chờ khung hình mới hơn `since` (tối đa 1.5 s). Trả (seq, w, h, bytes, mime) hoặc (seq, w, h, None, None) nếu không đổi."""
        self.last_req = time.time()
        with self.cond:
            if (self.seq <= since or self.rgba is None) and not self.err:
                self.cond.wait(2.5)
            self.last_req = time.time()
            if self.err and self.rgba is None:
                raise RuntimeError(self.err)
            if self.seq <= since or self.rgba is None:
                return self.seq, self.size[0], self.size[1], None, None
            seq, (w, h), data = self.seq, self.size, self.rgba
        key = (seq, scale, q)
        if self.cache[0] == key:
            return seq, w, h, self.cache[1][0], self.cache[1][1]
        if Image is not None:
            im = Image.frombuffer("RGBA", (w, h), data, "raw", "RGBA", 0, 1).convert("RGB")
            if scale < 0.999:
                im = im.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.BILINEAR)
            b = io.BytesIO()
            im.save(b, "JPEG", quality=q, optimize=False)
            out = (b.getvalue(), "image/jpeg")
        else:
            out = (png_rgba(w, h, data), "image/png")
        self.cache = (key, out)
        return seq, w, h, out[0], out[1]

    def screenshot(self):
        w, h, data = self.capture()
        if Image is not None:
            b = io.BytesIO()
            Image.frombuffer("RGBA", (w, h), data, "raw", "RGBA", 0, 1).convert("RGB").save(b, "PNG")
            return b.getvalue()
        return png_rgba(w, h, data)

    def has_ime(self):
        rc, out = self.sh("ime list -s", 10)
        return IME in out


PHONES = [Phone(i, s) for i, s in enumerate(DEVICES)]
fails = {}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "drakob-phone"

    def log_message(self, *a):
        pass

    def ip(self):
        return (self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip()

    def cors(self):
        o = (self.headers.get("Origin") or "").rstrip("/")
        if o and ("*" in ORIGINS or o in ORIGINS):
            self.send_header("Access-Control-Allow-Origin", o)
            self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Name")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Expose-Headers", "X-Seq, X-W, X-H, X-Err")
        self.send_header("Access-Control-Max-Age", "86400")

    def send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, str(v))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def auth(self, q):
        t = ""
        a = self.headers.get("Authorization") or ""
        if a.lower().startswith("bearer "):
            t = a[7:].strip()
        elif q.get("t"):
            t = q["t"][0]
        ip = self.ip()
        now = time.time()
        f = [x for x in fails.get(ip, []) if now - x < 60]
        if len(f) >= 20:
            self.send(429, {"error": "too_many_failures"})
            return False
        if verify(t):
            return True
        f.append(now)
        fails[ip] = f
        time.sleep(0.2)
        self.send(401, {"error": "unauthorized"})
        return False

    def phone(self, q):
        try:
            i = int((q.get("d") or ["0"])[0])
        except ValueError:
            i = 0
        return PHONES[i] if 0 <= i < len(PHONES) else None

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 1_000_000:
            raise ValueError("body quá lớn")
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_OPTIONS(self):
        self.send(204)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/api/health":
            return self.send(200, {"ok": True, "phones": len(PHONES)})
        if not self.auth(q):
            return
        p = self.phone(q)
        if p is None:
            return self.send(404, {"error": "no_such_phone"})
        try:
            if u.path == "/api/info":
                p.last_req = time.time()
                rc, ver = p.sh("getprop ro.build.version.release; getprop ro.product.model", 10)
                v = ver.split()
                return self.send(200, {"ok": True, "phones": len(PHONES), "idx": p.idx, "w": p.size[0], "h": p.size[1], "android": v[0] if v else "", "model": " ".join(v[1:]), "pillow": Image is not None, "err": p.err, "ime": p.has_ime()})
            if u.path == "/api/frame":
                try:
                    since = int((q.get("since") or ["-1"])[0])
                    scale = min(1.0, max(0.25, float((q.get("scale") or ["1"])[0])))
                    qual = min(90, max(20, int((q.get("q") or ["60"])[0])))
                except ValueError:
                    return self.send(400, {"error": "bad_params"})
                seq, w, h, data, ctype = p.frame(since, scale, qual)
                ex = {"X-Seq": seq, "X-W": w, "X-H": h}
                if data is None:
                    return self.send(204, b"", "text/plain", ex)
                return self.send(200, data, ctype, ex)
            if u.path == "/api/screenshot":
                return self.send(200, p.screenshot(), "image/png", {"Content-Disposition": 'attachment; filename="man-hinh.png"'})
            if u.path == "/api/apps":
                rc, out = p.sh("pm list packages -3", 20)
                pk = sorted(x.split(":", 1)[1].strip() for x in out.splitlines() if x.startswith("package:"))
                return self.send(200, {"ok": True, "apps": pk})
            return self.send(404, {"error": "not_found"})
        except RuntimeError as e:
            return self.send(503, {"error": "phone_unavailable", "detail": str(e)}, extra={"X-Err": "1"})
        except subprocess.TimeoutExpired:
            return self.send(504, {"error": "timeout"})
        except Exception as e:
            return self.send(500, {"error": "server", "detail": str(e)[:200]})

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if not self.auth(q):
            return
        p = self.phone(q)
        if p is None:
            return self.send(404, {"error": "no_such_phone"})
        try:
            if u.path == "/api/install":
                return self.install(p, q)
            b = self.body_json()
            p.last_req = time.time()
            with p.io:
                if u.path == "/api/tap":
                    x, y = int(b["x"]), int(b["y"])
                    if not (0 <= x < 10000 and 0 <= y < 10000):
                        raise ValueError("toạ độ")
                    p.sh("input tap %d %d" % (x, y), 10)
                    return self.send(200, {"ok": True})
                if u.path == "/api/swipe":
                    x1, y1, x2, y2 = (int(b[k]) for k in ("x1", "y1", "x2", "y2"))
                    ms = min(5000, max(50, int(b.get("ms", 250))))
                    if not all(0 <= v < 10000 for v in (x1, y1, x2, y2)):
                        raise ValueError("toạ độ")
                    p.sh("input swipe %d %d %d %d %d" % (x1, y1, x2, y2, ms), 15)
                    return self.send(200, {"ok": True})
                if u.path == "/api/key":
                    k = int(b["code"])
                    if k not in KEYS:
                        return self.send(400, {"error": "key_not_allowed"})
                    p.sh("input keyevent %d" % k, 10)
                    return self.send(200, {"ok": True})
                if u.path == "/api/text":
                    t = str(b.get("text", ""))[:2000]
                    if not t:
                        return self.send(200, {"ok": True})
                    if all(32 <= ord(c) < 127 for c in t):
                        esc = t.replace(" ", "%s")
                        p.sh("input text " + sq(esc), 15)
                        return self.send(200, {"ok": True, "mode": "input"})
                    if p.ime_ok is None or not p.ime_ok:
                        p.ime_ok = p.has_ime()
                    if not p.ime_ok:
                        return self.send(409, {"error": "no_unicode_ime", "detail": "Chưa cài bàn phím ADBKeyboard nên chỉ gõ được chữ không dấu."})
                    enc = base64.b64encode(t.encode("utf-8")).decode()
                    p.sh("am broadcast -a ADB_INPUT_B64 --es msg " + sq(enc), 15)
                    return self.send(200, {"ok": True, "mode": "ime"})
                if u.path == "/api/launch":
                    pk = str(b.get("pkg", ""))
                    if not PKG_RE.match(pk) or len(pk) > 200:
                        return self.send(400, {"error": "bad_package"})
                    rc, out = p.sh("monkey -p %s -c android.intent.category.LAUNCHER 1" % pk, 20)
                    return self.send(200, {"ok": "No activities found" not in out, "out": out[-300:]})
                if u.path == "/api/uninstall":
                    pk = str(b.get("pkg", ""))
                    if not PKG_RE.match(pk):
                        return self.send(400, {"error": "bad_package"})
                    r = p.adb("uninstall", pk, timeout=60)
                    return self.send(200, {"ok": b"Success" in r.stdout, "out": (r.stdout + r.stderr).decode("utf-8", "replace")[-300:]})
                if u.path == "/api/open":
                    url = str(b.get("url", ""))
                    if not re.match(r"^https?://[^\s'\"`$\\]{3,1900}$", url):
                        return self.send(400, {"error": "bad_url"})
                    p.sh("am start -a android.intent.action.VIEW -d " + sq(url), 15)
                    return self.send(200, {"ok": True})
                if u.path == "/api/shell":
                    cmd = str(b.get("cmd", ""))[:4000]
                    if not cmd.strip():
                        return self.send(400, {"error": "empty"})
                    rc, out = p.sh(cmd, 30)
                    return self.send(200, {"ok": True, "code": rc, "out": out[-100000:]})
                if u.path == "/api/restart":
                    if not (0 <= p.idx < len(CONTAINERS)):
                        return self.send(501, {"error": "no_container_name"})
                    subprocess.run(["docker", "restart", CONTAINERS[p.idx]], capture_output=True, timeout=120)
                    p.connect()
                    return self.send(200, {"ok": True})
            return self.send(404, {"error": "not_found"})
        except (KeyError, ValueError, TypeError, json.JSONDecodeError) as e:
            return self.send(400, {"error": "bad_request", "detail": str(e)[:100]})
        except subprocess.TimeoutExpired:
            return self.send(504, {"error": "timeout"})
        except Exception as e:
            return self.send(500, {"error": "server", "detail": str(e)[:200]})

    def install(self, p, q):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_APK:
            self.rfile.read(min(n, 1 << 20))
            return self.send(413, {"error": "too_large", "detail": "Tệp APK quá lớn hoặc rỗng"})
        name = re.sub(r"[^A-Za-z0-9._-]", "_", (self.headers.get("X-Name") or "app.apk"))[:80] or "app.apk"
        if not name.lower().endswith(".apk"):
            self.rfile.read(n)
            return self.send(400, {"error": "not_apk", "detail": "Chỉ nhận tệp .apk (không nhận .xapk/.apks)"})
        d = tempfile.mkdtemp(prefix="dkapk")
        try:
            path = os.path.join(d, name)
            left = n
            with open(path, "wb") as f:
                while left > 0:
                    c = self.rfile.read(min(1 << 20, left))
                    if not c:
                        break
                    f.write(c)
                    left -= len(c)
            if left:
                return self.send(400, {"error": "short_body"})
            r = p.adb("install", "-r", "-g", path, timeout=300)
            out = (r.stdout + r.stderr).decode("utf-8", "replace")
            return self.send(200, {"ok": b"Success" in r.stdout, "out": out[-600:]})
        finally:
            shutil.rmtree(d, ignore_errors=True)


def main():
    if not SECRET or len(SECRET) < 16:
        print("Thiếu PHONE_SECRET (tối thiểu 16 ký tự)", file=sys.stderr)
        sys.exit(2)
    for p in PHONES:
        p.connect()
    srv = ThreadingHTTPServer((BIND, PORT), H)
    srv.daemon_threads = True
    print("DRAKOB Phone server chạy tại %s:%d, %d máy, Pillow=%s" % (BIND, PORT, len(PHONES), Image is not None), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
DKEOF
chmod 700 "$DIR/phone_server.py"
cat > /etc/systemd/system/drakob-phone.service <<EOF
[Unit]
Description=DRAKOB Phone server
After=network-online.target docker.service
Wants=network-online.target
[Service]
EnvironmentFile=$ENVF
ExecStart=/usr/bin/python3 $DIR/phone_server.py
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable drakob-phone >/dev/null 2>&1; systemctl restart drakob-phone

if [ "$TUNNEL" = caddy ]; then
if ! command -v caddy >/dev/null; then
  c "Cài Caddy (HTTPS tự động)"
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y >/dev/null; apt-get install -y caddy >/dev/null || die "Không cài được Caddy"
fi
touch /etc/caddy/Caddyfile
sed -i '/DRAKOB-PHONE-BEGIN/,/DRAKOB-PHONE-END/d' /etc/caddy/Caddyfile
cat >> /etc/caddy/Caddyfile <<EOF
# DRAKOB-PHONE-BEGIN
$DOMAIN {
	encode zstd gzip
	request_body {
		max_size 450MB
	}
	reverse_proxy 127.0.0.1:8787 {
		flush_interval -1
		transport http {
			response_header_timeout 5m
		}
	}
}
# DRAKOB-PHONE-END
EOF
systemctl enable caddy >/dev/null 2>&1; systemctl restart caddy
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi
fi

c "Chờ Android khởi động (30-90 giây)"
for i in $(seq 0 $((PHONES-1))); do
  S="127.0.0.1:$((5555+i))"
  for t in $(seq 1 45); do
    adb connect "$S" >/dev/null 2>&1 || true
    [ "$(adb -s "$S" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
    sleep 2
  done
  if [ "$(adb -s "$S" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
    echo "   máy $((i+1)): đã khởi động"
    if curl -fsSL --max-time 40 -o "$DIR/adbkeyboard.apk" https://github.com/senzhk/ADBKeyBoard/raw/master/ADBKeyboard.apk 2>/dev/null; then
      adb -s "$S" install -r "$DIR/adbkeyboard.apk" >/dev/null 2>&1 \
        && adb -s "$S" shell ime enable com.android.adbkeyboard/.AdbIME >/dev/null 2>&1 \
        && adb -s "$S" shell ime set com.android.adbkeyboard/.AdbIME >/dev/null 2>&1 \
        && echo "   máy $((i+1)): đã cài bàn phím gõ tiếng Việt có dấu" || true
    fi
  else
    w "Máy $((i+1)) chưa báo khởi động xong. Kiểm tra: docker logs drakob-phone-$i"
  fi
done

c "Kiểm tra địa chỉ công khai (có thể mất 1-2 phút để DNS/HTTPS sẵn sàng)"
OKURL=0; for t in $(seq 1 30); do curl -fsS --max-time 6 "https://$DOMAIN/api/health" >/dev/null 2>&1 && { OKURL=1; break; }; sleep 4; done
[ "$OKURL" = 1 ] && echo "   OK: https://$DOMAIN trả lời" || w "Chưa truy cập được https://$DOMAIN từ ngoài. Đợi 1-2 phút rồi thử mở https://$DOMAIN/api/health trên trình duyệt; nếu vẫn lỗi hãy xem hướng dẫn trong DRAKOB."

echo
printf '\033[1;32m================ XONG ================\033[0m\n'
echo "Địa chỉ máy chủ (URL):  https://$DOMAIN"
echo "Mật khẩu kết nối (SECRET): $PHONE_SECRET"
echo
echo "Việc tiếp theo trong DRAKOB (tài khoản admin):"
echo "  Cài đặt → Khoá API → dán URL vào ô 'phone_url' và SECRET vào ô 'phone_secret' → Lưu."
echo "  Rồi mở công cụ 'Điện thoại ảo'."
if [ "$TUNNEL" = caddy ]; then echo "Nhớ mở cổng 80 và 443 ở tường lửa của nhà cung cấp VPS (Oracle: Security List/NSG)."; else echo "Máy này phải luôn bật và có mạng thì điện thoại ảo mới chạy 24/7. Địa chỉ trên là của Tailscale Funnel, không đổi khi khởi động lại."; fi
echo "Không chia sẻ SECRET cho ai. Xem lại sau: sudo cat $ENVF"
