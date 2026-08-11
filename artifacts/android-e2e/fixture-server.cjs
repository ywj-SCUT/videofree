const http = require('http');
const fs = require('fs');

http.createServer((_request, response) => {
  response.writeHead(200, { 'content-type': 'audio/x-mpegurl' });
  response.end(fs.readFileSync('D:/videofree/artifacts/android-e2e/mobile-import-fixture.m3u'));
}).listen(3456, '127.0.0.1');
