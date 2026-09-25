import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.endswith("/models"):
            b = json.dumps({"data":[{"id":"zeta"},{"id":"alpha"}]}).encode()
            self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
        else: self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length",0)); req = json.loads(self.rfile.read(n))
        user = req["messages"][1]["content"]
        text = user if isinstance(user,str) else user[0]["text"]
        think = req.get("think")
        if "LEAK" in text and not think: answer = "The user wants me to fix this. <think>x</think>"
        else: answer = "OK: " + text.upper() + (" (thinking)" if think else "")
        if req.get("stream"):
            self.send_response(200); self.send_header("Content-Type","text/event-stream"); self.end_headers()
            for w in answer.split(" "):
                self.wfile.write(("data: " + json.dumps({"choices":[{"delta":{"content": w + " "}}]}) + "\n\n").encode()); self.wfile.flush(); time.sleep(0.05)
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            b = json.dumps({"choices":[{"message":{"content":answer}}]}).encode()
            self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
