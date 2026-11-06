import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = fileURLToPath(new URL('.', import.meta.url));
// Beacon remains the source of truth on every launch.
const registration = JSON.parse(execFileSync('beacon', ['register', 'beacon-site', '--json'], {cwd: root, encoding: 'utf8'}));
if (!registration.port || !registration.url) throw new Error('Beacon did not return a port and URL.');
const types = {'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.svg':'image/svg+xml','.webp':'image/webp','.png':'image/png','.jpg':'image/jpeg','.woff2':'font/woff2'};
createServer(async (req, res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url, registration.url).pathname);
    const path = resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
    if (!path.startsWith(root.endsWith(sep) ? root : root + sep) || !['.html','.css','.js','.svg','.webp','.png','.jpg','.woff2'].includes(extname(path))) {
      res.writeHead(404); return res.end('Not found');
    }
    const info = await stat(path);
    if (!info.isFile()) throw new Error('Not a file');
    res.writeHead(200, {'Content-Type':types[extname(path)], 'Cache-Control':'no-cache', 'X-Content-Type-Options':'nosniff'});
    res.end(await readFile(path));
  } catch { res.writeHead(404); res.end('Not found'); }
}).listen(registration.port, '127.0.0.1', () => console.log(`Beacon preview: ${registration.url}`));
