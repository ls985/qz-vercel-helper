const net = require('net');
const fs = require('fs');
let counter = 0;
const server = net.createServer((socket) => {
  const id = ++counter;
  const chunks = [];
  let idleTimer = null;
  const finish = () => {
    if (!chunks.length) return;
    fs.writeFileSync(`${__dirname}/dump-${id}.txt`, Buffer.concat(chunks));
    socket.end('HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok');
  };
  socket.on('data', (chunk) => {
    chunks.push(chunk);
    clearTimeout(idleTimer);
    idleTimer = setTimeout(finish, 800);
  });
  socket.on('error', () => {});
});
server.listen(8099, '127.0.0.1', () => console.log('echo on 8099'));
setTimeout(() => process.exit(0), 30000);
