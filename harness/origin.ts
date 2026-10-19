// Shared origin for every arm. Run one instance per origin host and point
// each tunnel at it, so all arms hit the same process, port and bytes.
//   bun origin.ts [port=8080] [host=127.0.0.1]
const port = Number(process.argv[2] ?? 8080);
const hostname = process.argv[3] ?? "127.0.0.1";
const chunk = crypto.getRandomValues(new Uint8Array(4 * 1024 * 1024)); // incompressible

function blob(chunks: number): Response {
  let left = chunks;
  const body = new ReadableStream<Uint8Array>({
    pull(ctrl) {
      if (left > 0) {
        left--;
        ctrl.enqueue(chunk);
      } else {
        ctrl.close();
      }
    },
  });
  // 4 MB chunks, so size is whole multiples of 4 MB
  return new Response(body, {
    headers: {
      "content-type": "application/octet-stream",
      "content-length": String(chunks * chunk.length),
      "cache-control": "no-store",
    },
  });
}

Bun.serve({
  port,
  hostname,
  async fetch(req, server) {
    const url = new URL(req.url);
    if (url.pathname === "/ping") {
      return new Response("ok", { headers: { "cache-control": "no-store" } });
    }
    const m = url.pathname.match(/^\/blob\/(\d+)$/);
    if (m) {
      return blob(Number(m[1]) / 4);
    } // /blob/<MB>, MB must be a multiple of 4
    if (url.pathname === "/sink" && req.body) {
      let bytes = 0;
      for await (const part of req.body) {
        bytes += part.length;
      }
      return Response.json({ bytes });
    }
    if (url.pathname === "/ws" && server.upgrade(req)) {
      return undefined;
    }
    return new Response("not found", { status: 404 });
  },
  // Bun ignores the handler's return value; the cast keeps the one-line handler.
  websocket: { message: (ws, msg) => ws.send(msg) as unknown as void },
});
console.log(`origin listening on ${hostname}:${port}`);
