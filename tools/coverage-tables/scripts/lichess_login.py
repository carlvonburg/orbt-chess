"""Lichess OAuth (PKCE, no scopes) for CLI tools: saves a token to ~/.config/opening-trainer/lichess_token."""
import base64, hashlib, http.server, json, os, secrets, subprocess, urllib.parse, urllib.request

PORT = 8765
REDIRECT = f"http://localhost:{PORT}/callback"
CLIENT_ID = "opening-trainer-cli"
TOKEN_PATH = os.path.expanduser("~/.config/opening-trainer/lichess_token")

verifier = secrets.token_urlsafe(64)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
state = secrets.token_urlsafe(16)
url = "https://lichess.org/oauth?" + urllib.parse.urlencode({
    "response_type": "code", "client_id": CLIENT_ID, "redirect_uri": REDIRECT,
    "code_challenge_method": "S256", "code_challenge": challenge, "state": state})
result = {}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if not self.path.startswith("/callback"):
            self.send_response(404); self.end_headers(); return
        ok = q.get("state") == [state] and "code" in q
        result["code"] = q["code"][0] if ok else None
        result["error"] = None if ok else (q.get("error", ["state mismatch"])[0])
        self.send_response(200); self.send_header("Content-Type", "text/plain; charset=utf-8"); self.end_headers()
        self.wfile.write(("Signed in, you can close this tab." if ok else f"Sign-in failed: {result['error']}").encode())
    def log_message(self, *a): pass

server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
print("Opening", url, flush=True)
subprocess.run(["open", url])
while "code" not in result:
    server.handle_request()
if not result["code"]:
    raise SystemExit(f"failed: {result['error']}")
body = urllib.parse.urlencode({"grant_type": "authorization_code", "code": result["code"], "code_verifier": verifier,
                               "redirect_uri": REDIRECT, "client_id": CLIENT_ID}).encode()
tok = json.load(urllib.request.urlopen(urllib.request.Request("https://lichess.org/api/token", data=body)))
os.makedirs(os.path.dirname(TOKEN_PATH), exist_ok=True)
fd = os.open(TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, tok["access_token"].encode()); os.close(fd)
print(f"token saved to {TOKEN_PATH} (expires in {tok.get('expires_in', 0) // 86400} days)")
