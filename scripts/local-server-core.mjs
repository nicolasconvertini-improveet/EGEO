export function crearServidor(handlers) {
  return async (req, res) => {
    const name = new URL(req.url, "http://localhost").pathname.replace(
      "/.netlify/functions/",
      "",
    );
    const handler = handlers[name];
    if (!handler) {
      res.writeHead(404);
      res.end();
      return;
    }
    let body = "";
    try {
      for await (const chunk of req) {
        body += chunk;
        if (Buffer.byteLength(body) > 32768) {
          res.writeHead(413);
          res.end();
          return;
        }
      }
      const result = await handler({
        httpMethod: req.method,
        headers: req.headers,
        body,
      });
      res.writeHead(result.statusCode, result.headers);
      res.end(result.body);
    } catch {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "No se pudo completar la operación" }));
    }
  };
}
